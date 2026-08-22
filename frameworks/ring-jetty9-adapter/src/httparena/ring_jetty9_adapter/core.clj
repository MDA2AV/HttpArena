(ns httparena.ring-jetty9-adapter.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [hikari-cp.core :as hikari]
   [next.jdbc :as jdbc]
   [next.jdbc.result-set :as rs]
   [ring.adapter.jetty9 :as jetty]
   [ring.middleware.params :as params]
   [ring.util.response :as response])
  (:import
   [java.io FileInputStream InputStream OutputStream]
   [java.security KeyFactory KeyStore]
   [java.security.cert Certificate CertificateFactory]
   [java.security.spec PKCS8EncodedKeySpec]
   [java.util Base64]
   [java.net URI]
   [org.eclipse.jetty.server.handler.gzip GzipHandler]
   [org.postgresql.util PGobject]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")
(def static-root "/data/static")
(def async-db-query
  "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
   FROM items
   WHERE price BETWEEN ? AND ?
   LIMIT ?")
(def static-content-types
  {"css" "text/css"
   "js" "application/javascript"
   "html" "text/html"
   "woff2" "font/woff2"
   "svg" "image/svg+xml"
   "webp" "image/webp"
   "json" "application/json"})

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (or (some-> value str str/trim parse-long) default)))

(defn parse-int [value default]
  (try
    (if (some? value)
      (Integer/parseInt (str value))
      default)
    (catch NumberFormatException _
      default)))

(defn database-max-conn []
  (max 1 (parse-int (System/getenv "DATABASE_MAX_CONN") 256)))

(defn database-url->hikari-options [database-url]
  (let [uri                 (URI. database-url)
        scheme              (.getScheme uri)
        host                (.getHost uri)
        port                (.getPort uri)
        path                (.getRawPath uri)
        query-string        (.getRawQuery uri)
        [username password] (str/split (or (.getUserInfo uri) "") #":" 2)]
    (when-not (and (#{"postgres" "postgresql"} scheme)
                   (seq host)
                   (seq path)
                   (seq username)
                   (some? password))
      (throw (ex-info "invalid DATABASE_URL" {:scheme scheme})))
    {:jdbc-url          (str "jdbc:postgresql://" host
                            (when-not (= -1 port) (str ":" port))
                            path
                            (when query-string (str "?" query-string)))
     :username          username
     :password          password
     :maximum-pool-size (database-max-conn)}))

(defn load-dataset [path]
  (when (.exists (io/file path))
    (json/read-str (slurp path) :key-fn keyword)))

(defonce dataset
  (delay (load-dataset "/data/dataset.json")))

(defonce datasource (atom nil))

(defn compute-json-items [items multiplier]
  (mapv (fn [{:keys [price quantity] :as item}]
          (assoc item :total (* price quantity multiplier)))
        items))

(defn request-sum [request]
  (let [params (:params request)
        a      (parse-long-safe (get params "a"))
        b      (parse-long-safe (get params "b"))
        body   (if (= :post (:request-method request))
                 (parse-long-safe (slurp (:body request)))
                 0)]
    (+ a b body)))

(defn count-stream-bytes [^InputStream in]
  (with-open [^InputStream stream in]
    (.transferTo stream (OutputStream/nullOutputStream))))

(defn text-response [status body]
  {:status status
   :headers {"content-type" "text/plain"}
   :body body})

(defn json-response [status body]
  {:status status
   :headers {"Content-Type" json-content-type}
   :body (json/write-str body)})

(defn empty-response []
  (json-response 200 {:items []
                      :count 0}))

(defn tags->vector [tags]
  (cond
    (instance? PGobject tags) (json/read-str (.getValue ^PGobject tags))
    (string? tags) (json/read-str tags)
    (sequential? tags) (vec tags)
    :else (throw (ex-info "unexpected tags value" {:type (type tags)}))))

(defn rows->items [rows]
  (mapv (fn [{:keys [id name category price quantity active tags rating_score rating_count]}]
          {:id       id
           :name     name
           :category category
           :price    price
           :quantity quantity
           :active   active
           :tags     (tags->vector tags)
           :rating   {:score rating_score
                      :count rating_count}})
        rows))

(defn datasource! []
  (or @datasource
      (locking datasource
        (or @datasource
            (try
              (let [database (hikari/make-datasource
                              (database-url->hikari-options
                               (System/getenv "DATABASE_URL")))]
                (reset! datasource database))
              (catch Exception _
                nil))))))

(defn close-datasource! []
  (when-let [database @datasource]
    (hikari/close-datasource database)
    (reset! datasource nil)))

(defn async-db-handler [request]
  (let [params    (:params request)
        min-price (parse-int (get params "min") 10)
        max-price (parse-int (get params "max") 50)
        limit     (-> (parse-int (get params "limit") 50)
                      (max 1)
                      (min 50))]
    (if-let [database (datasource!)]
      (try
        (let [rows  (jdbc/execute! database
                                   [async-db-query min-price max-price limit]
                                   {:builder-fn rs/as-unqualified-lower-maps})
              items (rows->items rows)]
          (json-response 200 {:items items
                              :count (count items)}))
        (catch Exception _
          (empty-response)))
      (empty-response))))

(defn static-filename [uri]
  (when (str/starts-with? uri "/static/")
    (let [filename (subs uri 8)]
      (when (and (not (str/blank? filename))
                 (not (str/includes? filename "/"))
                 (not (str/includes? filename "..")))
        filename))))

(defn static-content-type [filename]
  (let [extension (some-> filename (str/split #"\.") last str/lower-case)]
    (get static-content-types extension "application/octet-stream")))

(defn static-response [uri]
  (when-let [filename (static-filename uri)]
    (if-let [file-response (response/file-response filename {:root static-root
                                                             :index-files? false})]
      (response/content-type file-response (static-content-type filename))
      (text-response 404 "not found"))))

(defn json-data-response [request]
  (let [uri        (:uri request)
        item-count (-> (subs uri (count "/json/"))
                       parse-long-safe
                       (max 1)
                       (min 50))
        multiplier (if-let [value (get-in request [:params "m"])]
                     (parse-long-safe value)
                     1)]
    (if-let [source @dataset]
      (let [items (compute-json-items (take item-count source) multiplier)]
        (json-response 200 {:items items
                            :count (count items)}))
      (text-response 500 "dataset.json not available"))))

(defn method-not-allowed-response []
  (text-response 405 "method not allowed"))

(defn sync-app [request]
  (let [uri    (:uri request)
        method (:request-method request)]
    (cond
      (str/starts-with? uri "/static/")
      (if (= :get method)
        (or (static-response uri)
            (text-response 404 "not found"))
        (method-not-allowed-response))

      (re-matches #"/json/[0-9]+" uri)
      (if (= :get method)
        (json-data-response request)
        (method-not-allowed-response))

      :else
      (case uri
        "/baseline11" (case method
                        (:get :post) (text-response 200 (str (request-sum request)))
                        (method-not-allowed-response))
        "/upload" (if (= :post method)
                    (text-response 200 (str (count-stream-bytes (:body request))))
                    (method-not-allowed-response))
        "/pipeline" (if (= :get method)
                      (text-response 200 "ok")
                      (method-not-allowed-response))
        (text-response 404 "not found")))))
(defn app [request]
  (if (= "/async-db" (:uri request))
    (if (= :get (:request-method request))
      (async-db-handler request)
      (method-not-allowed-response))
    (sync-app request)))

(defn handler [request]
  (app (params/params-request request)))

(def ^:private ^:const tls-cert-path "/certs/server.crt")
(def ^:private ^:const tls-key-path "/certs/server.key")

;; The harness mounts PEMs; Jetty wants a KeyStore. Built with the plain JDK
;; crypto APIs rather than java.security.PEMDecoder, which is still a preview
;; API on the JDK in this image.
(defn- pem->keystore ^KeyStore [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        chain (into-array Certificate certs)
        der (->> (-> (slurp key-path)
                     (str/replace #"-----(BEGIN|END) PRIVATE KEY-----" "")
                     (str/replace #"\s" ""))
                 (.decode (Base64/getDecoder)))
        pk (.generatePrivate (KeyFactory/getInstance "RSA")
                             (PKCS8EncodedKeySpec. der))
        pw (char-array 0)]
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
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (.addShutdownHook (Runtime/getRuntime) (Thread. ^Runnable close-datasource!))
  (jetty/run-jetty handler
                   (merge
                    {:host "0.0.0.0"
                     :join? true
                     :port 8080
                     :virtual-threads? true
                     :wrap-jetty-handler (fn [^org.eclipse.jetty.server.Handler ring-handler]
                                           (doto (GzipHandler.)
                                             (.setExcludedPaths (into-array String ["/static/*"]))
                                             (.setHandler ring-handler)))}
                    (tls-opts))))
