(ns httparena.ring-jetty-adapter.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [ring.adapter.jetty :as jetty]
   [ring.middleware.params :as params]
   [ring.websocket :as ws])
  (:import
   [java.io FileInputStream InputStream]
   [java.security KeyFactory KeyStore]
   [java.security.cert Certificate CertificateFactory]
   [java.security.spec PKCS8EncodedKeySpec]
   [java.util Base64]
   [org.eclipse.jetty.server Server]
   [org.eclipse.jetty.server.handler.gzip GzipHandler]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (or (some-> value str str/trim not-empty parse-long)
       default)))

(defn load-dataset [^String path]
  (when (.exists (io/file path))
    (json/read-str (slurp path) :key-fn keyword)))

(defonce dataset
  (delay (load-dataset "/data/dataset.json")))

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

(defn echo-response [request]
  (let [^InputStream in (:body request)]
    {:status  200
     :headers {"content-type" "application/octet-stream"}
     :body    (if in
                (with-open [^InputStream stream in]
                  (.readAllBytes stream))
                (byte-array 0))}))

(defn text-response [status body]
  {:status  status
   :headers {"content-type" "text/plain"}
   :body    body})

(defn json-response [status body]
  {:status  status
   :headers {"content-type" json-content-type}
   :body    (json/write-str body)})

(defn delay-response [request]
  (let [ms (parse-long-safe (subs (:uri request) 7))]
    (when (pos? ms)
      (Thread/sleep (long ms)))
    (text-response 200 (str ms))))

(defn json-items-response [request]
  (if-let [source @dataset]
    (let [[_ path-count] (re-matches #"/json/([0-9]+)" (:uri request))
          item-count     (if path-count (parse-long-safe path-count) (count source))
          multiplier     (parse-long-safe (get-in request [:params "m"]) 1)
          items          (take item-count source)]
      (json-response 200 {:items (compute-json-items items multiplier)
                          :count (count items)}))
    (text-response 500 "dataset.json not available")))

(defn websocket-echo [request]
  (if (ws/upgrade-request? request)
    {::ws/listener {:on-message (fn [socket message]
                                  (ws/send socket message))}}
    (text-response 426 "websocket upgrade required")))

(defn app [request]
  (case (:uri request)
    "/baseline11" (text-response 200 (str (request-sum request)))
    "/echo" (if (= :post (:request-method request))
              (echo-response request)
              (text-response 405 "method not allowed"))
    "/pipeline" (text-response 200 "ok")
    "/ws" (websocket-echo request)
    (cond
      (re-matches #"/json/[0-9]+" (:uri request)) (json-items-response request)
      (re-matches #"/delay/[0-9]+" (:uri request)) (delay-response request)
      :else (text-response 404 "not found"))))

(def handler
  (params/wrap-params app))

(def ^:private ^:const tls-cert-path "/certs/server.crt")
(def ^:private ^:const tls-key-path "/certs/server.key")

(defn pem->keystore ^KeyStore [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        chain (into-array Certificate certs)
        der   (->> (-> (slurp key-path)
                       (str/replace #"-----(BEGIN|END) PRIVATE KEY-----" "")
                       (str/replace #"\s" ""))
                   (.decode (Base64/getDecoder)))
        key   (.generatePrivate (KeyFactory/getInstance "RSA")
                                (PKCS8EncodedKeySpec. der))
        pw    (char-array 0)]
    (doto (KeyStore/getInstance "PKCS12")
      (.load nil pw)
      (.setKeyEntry "server" key pw chain))))

(defn tls-opts []
  (if (and (.exists (io/file tls-cert-path))
           (.exists (io/file tls-key-path)))
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
  (jetty/run-jetty
   handler
   (merge
    {:host         "0.0.0.0"
     :configurator (fn [^Server server]
                     (let [gzip-handler (doto (GzipHandler.)
                                          (.setHandler (.getHandler server)))]
                       (.setHandler server gzip-handler)))
     :join?        true
     :port         8080}
    (tls-opts))))
