(ns httparena.ring-jetty9-adapter.core
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [ring.adapter.jetty9 :as jetty]
   [ring.middleware.params :as params]
   [ring.util.response :as response]
   [ring.websocket :as websocket])
  (:import
   [java.io FileInputStream InputStream]
   [java.security KeyFactory KeyStore]
   [java.security.cert Certificate CertificateFactory]
   [java.security.spec PKCS8EncodedKeySpec]
   [java.util Base64]
   [org.eclipse.jetty.server Handler]
   [org.eclipse.jetty.server.handler.gzip GzipHandler])
  (:gen-class))

(set! *warn-on-reflection* true)

(def ^:private json-content-type "application/json")
(def ^:private static-root "/data/static")
(def ^:private tls-cert-path "/certs/server.crt")
(def ^:private tls-key-path "/certs/server.key")
(def ^:private static-content-types
  {"css"   "text/css"
   "js"    "application/javascript"
   "html"  "text/html"
   "woff2" "font/woff2"
   "svg"   "image/svg+xml"
   "webp"  "image/webp"
   "json"  json-content-type})

(defn- parse-long-value [value default]
  (try
    (if (some? value)
      (Long/parseLong (str value))
      default)
    (catch NumberFormatException _
      default)))

(defn- text-response [status body]
  {:status  status
   :headers {"Content-Type" "text/plain"}
   :body    (str body)})

(defn- json-response [body]
  {:status  200
   :headers {"Content-Type" json-content-type}
   :body    (json/write-str body)})

(defn- request-sum [request]
  (let [params (:params request)
        body   (if (= :post (:request-method request))
                 (some-> (:body request) slurp)
                 nil)]
    (+ (parse-long-value (get params "a") 0)
       (parse-long-value (get params "b") 0)
       (parse-long-value body 0))))

(defn- echo-response [request]
  (let [body (if-let [^InputStream input (:body request)]
               (with-open [stream input]
                 (.readAllBytes stream))
               (byte-array 0))]
    {:status  200
     :headers {"Content-Type" "application/octet-stream"}
     :body    body}))

(defn- static-content-type [uri]
  (let [extension (some-> uri (str/split #"\.") last str/lower-case)]
    (get static-content-types extension "application/octet-stream")))

(defn- static-response [uri]
  (if-let [file-response (response/file-response (subs uri (count "/static/"))
                                                 {:root static-root
                                                  :index-files? false})]
    (response/content-type file-response (static-content-type uri))
    (text-response 404 "not found")))

(defn- json-data-response [dataset request]
  (let [count-value (-> (subs (:uri request) (count "/json/"))
                        (parse-long-value 1)
                        (max 1)
                        (min 50))
        multiplier  (parse-long-value (get-in request [:params "m"]) 1)
        items       (mapv (fn [{:keys [price quantity] :as item}]
                            (assoc item :total (* price quantity multiplier)))
                          (take count-value dataset))]
    (json-response {:items items
                    :count (count items)})))

(defn- delay-response [uri]
  (let [milliseconds (max 0 (parse-long-value (subs uri (count "/delay/")) 0))]
    (when (pos? milliseconds)
      (Thread/sleep (long milliseconds)))
    (text-response 200 milliseconds)))

(def ^:private websocket-listener
  {:on-open    (fn [_])
   :on-message (fn [socket message]
                 (websocket/send socket message))
   :on-close   (fn [_ _ _])
   :on-error   (fn [_ _])})

(defn- websocket-response [request]
  (if (jetty/ws-upgrade-request? request)
    {:ring.websocket/listener websocket-listener}
    (text-response 426 "websocket upgrade required")))

(defn handler [dataset]
  (params/wrap-params
   (fn [request]
     (let [uri    (:uri request)
           method (:request-method request)]
       (cond
         (= uri "/ws")
         (websocket-response request)

         (and (= method :get) (= uri "/pipeline"))
         (text-response 200 "ok")

         (and (= method :get) (#{"/baseline11" "/baseline2"} uri))
         (text-response 200 (request-sum request))

         (and (= method :post) (= uri "/baseline11"))
         (text-response 200 (request-sum request))

         (and (= method :post) (= uri "/echo"))
         (echo-response request)

         (and (= method :get) (re-matches #"/json/[0-9]+" uri))
         (json-data-response dataset request)

         (and (= method :get) (re-matches #"/delay/[0-9]+" uri))
         (delay-response uri)

         (and (= method :get) (str/starts-with? uri "/static/"))
         (static-response uri)

         :else
         (text-response 404 "not found"))))))

(defn- pem->keystore [^String cert-path ^String key-path]
  (let [certificates (with-open [input (FileInputStream. cert-path)]
                       (.generateCertificates (CertificateFactory/getInstance "X.509") input))
        chain        (into-array Certificate certificates)
        der          (->> (-> (slurp key-path)
                              (str/replace #"-----(BEGIN|END) PRIVATE KEY-----" "")
                              (str/replace #"\s" ""))
                          (.decode (Base64/getDecoder)))
        private-key  (.generatePrivate (KeyFactory/getInstance "RSA")
                                       (PKCS8EncodedKeySpec. der))
        password     (char-array 0)]
    (doto (KeyStore/getInstance "PKCS12")
      (.load nil password)
      (.setKeyEntry "server" private-key password chain))))

(defn- tls-options [port]
  (when (and (.exists (io/file tls-cert-path))
             (.exists (io/file tls-key-path)))
    {:ssl?            true
     :ssl-port        port
     :keystore        (pem->keystore tls-cert-path tls-key-path)
     :key-password    ""
     :sni-host-check? false}))

(defn- gzip-handler [^Handler ring-handler]
  (doto (GzipHandler.)
    (.setExcludedPaths (into-array String ["/static/*"]))
    (.setHandler ring-handler)))

(defn- server-options [port]
  {:host                "0.0.0.0"
   :join?               false
   :port                port
   :wrap-jetty-handler  gzip-handler})

(defn -main [& _]
  (let [dataset         (json/read-str (slurp "/data/dataset.json") :key-fn keyword)
        request-handler (handler dataset)
        h1-options      (server-options 8080)]
    (if-let [tls (tls-options 8081)]
      (do
        (jetty/run-jetty request-handler (merge h1-options tls))
        (jetty/run-jetty
         request-handler
         (merge (server-options 8082)
                (assoc tls
                       :ssl-port 8443
                       :h2?      true
                       :h2c?     true))))
      (jetty/run-jetty request-handler h1-options))
    @(promise)))
