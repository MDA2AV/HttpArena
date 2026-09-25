(ns ring.core
  (:require [clojure.data.json :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [ring-http-exchange.core :as server]
            [ring-http-exchange.ssl :as ssl])
  (:import (java.io ByteArrayOutputStream FileInputStream InputStream)
           (java.nio.charset StandardCharsets)
           (java.security KeyStore PEMDecoder PrivateKey)
           (java.security.cert Certificate CertificateFactory)
           (java.util.zip GZIPOutputStream))
  (:gen-class))

(set! *warn-on-reflection* true)

(def ^:private ^:const ct-json "application/json")
(def ^:private ^:const ct-text "text/plain")
(def ^:private ^:const ct-octet "application/octet-stream")
(def ^:private ^:const hdr-ct "Content-Type")
(def ^:private ^:const hdr-ce "Content-Encoding")
(def ^:private ^:const hdr-server "Server")
(def ^:private ^:const server-name "ring-http-exchange")
(def ^:private ^:const enc-gzip "gzip")
(def ^:private ^:const dataset-path "/data/dataset.json")
(def ^:private ^:const static-dir "/data/static")
(def ^:private ^:const plain-port 8080)
(def ^:private ^:const tls-port 8081)
(def ^:private ^:const tls-cert-default "/certs/server.crt")
(def ^:private ^:const tls-key-default "/certs/server.key")

(def ^:private text-headers {hdr-ct ct-text hdr-server server-name})
(def ^:private json-headers {hdr-ct ct-json hdr-server server-name})
(def ^:private json-gzip-headers {hdr-ct ct-json hdr-ce enc-gzip hdr-server server-name})

(def ^:private extension-map
  {".css"   "text/css"
   ".js"    "application/javascript"
   ".html"  "text/html"
   ".woff2" "font/woff2"
   ".svg"   "image/svg+xml"
   ".webp"  "image/webp"
   ".json"  ct-json})

(defn- parse-long-safe [value default]
  (try
    (if (some? value)
      (Long/parseLong (str value))
      default)
    (catch Exception _
      default)))

(defn- query-params [query-string]
  (if (str/blank? query-string)
    {}
    (into {}
          (keep (fn [part]
                  (let [[key value] (str/split part #"=" 2)]
                    (when value [key value]))))
          (str/split query-string #"&"))))

(defn- request-sum [request]
  (let [parameters (query-params (:query-string request))
        body       (if (= :post (:request-method request))
                     (slurp (:body request))
                     nil)]
    (+ (parse-long-safe (get parameters "a") 0)
       (parse-long-safe (get parameters "b") 0)
       (parse-long-safe body 0))))

(defn- gzip-bytes [^bytes bytes]
  (let [output (ByteArrayOutputStream.)]
    (with-open [gzip (GZIPOutputStream. output)]
      (.write gzip bytes))
    (.toByteArray output)))

(defn- accepts-gzip? [headers]
  (boolean
   (some (fn [[key value]]
           (and (.equalsIgnoreCase ^String key "accept-encoding")
                (.contains ^String value enc-gzip)))
         headers)))

(defn- load-dataset [path]
  (when (.exists (io/file path))
    (json/read-str (slurp path) :key-fn keyword)))

(defn- json-response [data gzip?]
  (let [body (json/write-str data)]
    {:status  200
     :headers (if gzip? json-gzip-headers json-headers)
     :body    (if gzip?
                (gzip-bytes (.getBytes body StandardCharsets/UTF_8))
                body)}))

(defn- json-items [dataset request]
  (let [requested-count (parse-long-safe (subs (:uri request) (count "/json/")) 0)
        multiplier      (parse-long-safe (get (query-params (:query-string request)) "m") 1)
        items (mapv #(assoc % :total (* (:price %) (:quantity %) multiplier))
                    (take requested-count dataset))]
    (json-response {:items items :count (clojure.core/count items)}
                   (accepts-gzip? (:headers request)))))

(defn- echo-response [request]
  (let [body (if-let [^InputStream input (:body request)]
               (with-open [stream input]
                 (.readAllBytes stream))
               (byte-array 0))]
    {:status 200
     :headers {hdr-ct ct-octet hdr-server server-name}
     :body body}))

(defn- static-content-type [filename]
  (let [dot (.lastIndexOf ^String filename ".")]
    (get extension-map (if (neg? dot) "" (subs filename dot)) ct-octet)))

(defn- static-file [uri]
  (when (str/starts-with? uri "/static/")
    (let [filename (subs uri (count "/static/"))
          root (.toPath (io/file static-dir))
          candidate (.normalize (.toPath (io/file static-dir filename)))]
      (when (and (not (str/blank? filename))
                 (.startsWith candidate root)
                 (.isFile (.toFile candidate)))
        (.toFile candidate)))))

(defn- static-response [uri]
  (if-let [^java.io.File file (static-file uri)]
    {:status 200
     :headers {hdr-ct (static-content-type (.getName file)) hdr-server server-name}
     :body file}
    {:status 404 :headers text-headers :body "Not found"}))

(defn- pem->keystore [^String cert-path ^String key-path]
  (let [certificates (with-open [input (FileInputStream. cert-path)]
                       (.generateCertificates (CertificateFactory/getInstance "X.509") input))
        certificate-array (into-array Certificate certificates)
        private-key (.decode (PEMDecoder/of) (slurp key-path) PrivateKey)
        password (char-array 0)]
    (doto (KeyStore/getInstance "PKCS12")
      (.load nil password)
      (.setKeyEntry "server" private-key password certificate-array))))

(defn- load-ssl-context []
  (let [cert-path (or (System/getenv "TLS_CERT") tls-cert-default)
        key-path (or (System/getenv "TLS_KEY") tls-key-default)]
    (when (and (.exists (io/file cert-path)) (.exists (io/file key-path)))
      (ssl/keystore->ssl-context (pem->keystore cert-path key-path) ""))))

(defn- handler [dataset request respond _raise]
  (let [uri (:uri request)]
    (cond
      (= uri "/baseline11")
      (respond {:status 200 :headers text-headers :body (str (request-sum request))})

      (= uri "/pipeline")
      (respond {:status 200 :headers text-headers :body "ok"})

      (str/starts-with? uri "/json/")
      (respond (json-items dataset request))

      (= uri "/echo")
      (respond (echo-response request))

      (str/starts-with? uri "/delay/")
      (let [milliseconds (parse-long-safe (subs uri (count "/delay/")) 0)]
        (when (pos? milliseconds)
          (Thread/sleep (long milliseconds)))
        (respond {:status 200 :headers text-headers :body (str milliseconds)}))

      (str/starts-with? uri "/static/")
      (respond (static-response uri))

      :else
      (respond {:status 404 :headers text-headers :body "Not found"}))))

(defn- start-server! [request-handler port ssl-context]
  (server/run-http-server request-handler
                          (cond-> {:port port
                                   :async? true}
                            ssl-context (assoc :ssl-context ssl-context))))

(defn -main [& _]
  (let [dataset (load-dataset (or (System/getenv "DATASET_PATH") dataset-path))
        request-handler (partial handler (vec dataset))]
    (start-server! request-handler plain-port nil)
    (when-let [ssl-context (load-ssl-context)]
      (start-server! request-handler tls-port ssl-context))))
