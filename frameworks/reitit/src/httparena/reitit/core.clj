(ns httparena.reitit.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [reitit.ring :as ring]
   [ring.adapter.jetty :as jetty]
   [ring.middleware.params :as params])
  (:import
   [java.io ByteArrayOutputStream InputStream]
   [java.security KeyFactory KeyStore]
   [java.security.cert Certificate CertificateFactory]
   [java.security.spec PKCS8EncodedKeySpec]
   [java.io FileInputStream]
   [java.util Base64]
   [org.eclipse.jetty.server Server]
   [org.eclipse.jetty.server.handler.gzip GzipHandler]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")
(def text-content-type "text/plain")
(def tls-cert-path "/certs/server.crt")
(def tls-key-path "/certs/server.key")

;; Read once at startup and then only read from handlers, so every thread
;; shares the one copy. A missing or broken file is not fatal: /json then
;; answers with an empty list.
(def dataset
  (delay
    (try
      (let [path (or (System/getenv "DATASET_PATH") "/data/dataset.json")]
        (vec (json/read-str (slurp path) :key-fn keyword)))
      (catch Exception _ []))))

(defn- parse-long-or-nil [s]
  (try (Long/parseLong (str/trim (str s))) (catch Exception _ nil)))

;; Sum of every query parameter whose value parses as an integer; a
;; non-numeric one is skipped rather than failing the request.
(defn- sum-params [params]
  (reduce (fn [acc [_ v]]
            (if-let [n (parse-long-or-nil (if (vector? v) (first v) v))]
              (+ acc n)
              acc))
          0
          params))

(defn- read-body-string ^String [^InputStream body]
  (if (nil? body)
    ""
    (with-open [in body]
      (let [out (ByteArrayOutputStream.)]
        (io/copy in out)
        (.toString out "UTF-8")))))

(defn baseline11 [request]
  (let [total (+ (sum-params (:query-params request))
                 (or (parse-long-or-nil (read-body-string (:body request))) 0))]
    {:status  200
     :headers {"Content-Type" text-content-type}
     :body    (str total)}))

;; Field order is the wire order: id..rating then the computed total.
(defn- out-item [item m]
  (array-map
   :id       (:id item)
   :name     (:name item)
   :category (:category item)
   :price    (:price item)
   :quantity (:quantity item)
   :active   (:active item)
   :tags     (:tags item)
   :rating   (array-map :score (get-in item [:rating :score])
                        :count (get-in item [:rating :count]))
   :total    (* (:price item) (:quantity item) m)))

(defn json-items [request]
  (let [all   @dataset
        count' (min (max (or (parse-long-or-nil (get-in request [:path-params :count])) 0) 0)
                    (clojure.core/count all))
        m     (or (parse-long-or-nil (get (:query-params request) "m")) 1)
        items (mapv #(out-item % m) (subvec all 0 count'))]
    {:status  200
     :headers {"Content-Type" json-content-type}
     :body    (json/write-str (array-map :items items :count count'))}))

;; Echo: the bytes that arrived go back unchanged. Collected because the
;; response needs a Content-Length, and a chunked request carries none.
(defn echo [request]
  (let [^InputStream body (:body request)]
    {:status  200
     :headers {"Content-Type" "application/octet-stream"}
     :body    (if body (.readAllBytes body) (byte-array 0))}))

(def app
  (ring/ring-handler
   (ring/router
    [["/baseline11" {:get baseline11 :post baseline11}]
     ["/json/:count" {:get json-items}]
     ["/echo" {:post echo}]]
    ;; params middleware on the router, so query parsing is reitit's own
    ;; middleware chain rather than a hand-rolled decode in the handler.
    {:data {:middleware [params/wrap-params]}})
   (ring/create-default-handler)))

;; The harness mounts PEMs; Jetty wants a KeyStore. Built with the plain JDK
;; classes so the entry does not pull a crypto library in just for this.
(defn- pem->keystore ^KeyStore [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        chain (into-array Certificate certs)
        der   (->> (-> (slurp key-path)
                       (str/replace #"-----(BEGIN|END) PRIVATE KEY-----" "")
                       (str/replace #"\s" ""))
                   (.decode (Base64/getDecoder)))
        pk    (.generatePrivate (KeyFactory/getInstance "RSA")
                                (PKCS8EncodedKeySpec. der))
        pw    (char-array 0)]
    (doto (KeyStore/getInstance "PKCS12")
      (.load nil pw)
      (.setKeyEntry "server" pk pw chain))))

;; json-tls on 8081, same handler as 8080. Only opened when the certs are
;; mounted, which the harness does just for the TLS profiles.
(defn- tls-opts []
  (if (and (.exists (io/file tls-cert-path)) (.exists (io/file tls-key-path)))
    {:ssl?            true
     :ssl-port        8081
     :keystore        (pem->keystore tls-cert-path tls-key-path)
     :key-password    ""
     :sni-host-check? false}
    {}))

(defn -main [& _args]
  (jetty/run-jetty
   app
   (merge
    {:host  "0.0.0.0"
     :port  8080
     :join? true
     ;; json-comp: Jetty's own gzip handler at the level the profile asks for.
     :configurator (fn [^Server server]
                     (let [gzip (doto (GzipHandler.)
                                  (.setMinGzipSize 1)
                                  (.setInflateBufferSize 8192))]
                       (.setHandler gzip (.getHandler server))
                       (.setHandler server gzip)))}
    (tls-opts))))
