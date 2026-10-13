(ns httparena.enso.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [ring.middleware.gzip :as gzip]
   [ring.middleware.params :as params]
   [ring.util.mime-type :as mime]
   [ring.util.response :as response]
   [ring.websocket :as ws]
   [s-exp.enso :as enso])
  (:import
   [java.io ByteArrayOutputStream FileInputStream InputStream]
   [java.nio.charset StandardCharsets]
   [java.security KeyFactory KeyStore]
   [java.security.cert Certificate CertificateFactory]
   [java.security.spec PKCS8EncodedKeySpec]
   [java.util Base64]
   [java.util.zip GZIPOutputStream]
   [javax.net.ssl KeyManagerFactory SSLContext]))

(set! *warn-on-reflection* true)

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (or (some-> value str str/trim not-empty parse-long)
       default)))

(defn load-dataset [path]
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

(defn text-response [status body]
  {:status  status
   :headers {"content-type" "text/plain"}
   :body    body})

(defn echo-response [request]
  (let [^InputStream in (:body request)]
    {:status  200
     :headers {"content-type" "application/octet-stream"}
     :body    (if in
                (with-open [stream in]
                  (.readAllBytes stream))
                (byte-array 0))}))

(defn delay-response [request]
  (let [ms (parse-long-safe (subs (:uri request) 7))]
    ;; Enso invokes handlers on virtual threads, so sleep does not block an event loop.
    (when (pos? ms)
      (Thread/sleep (long ms)))
    (text-response 200 (str ms))))

(defn json-items-response [request]
  (if-let [source @dataset]
    (let [[_ path-count] (re-matches #"/json/([0-9]+)" (:uri request))
          item-count     (parse-long-safe path-count)
          multiplier     (parse-long-safe (get-in request [:params "m"]) 1)
          items          (compute-json-items (take item-count source) multiplier)]
      {:status  200
       :headers {"content-type" "application/json"}
       :body    (json/write-str {:items items :count (count items)})})
    (text-response 500 "dataset.json not available")))

(defn websocket-echo [request]
  (if (ws/upgrade-request? request)
    {::ws/listener {:on-message (fn [socket message]
                                  (ws/send socket message))}}
    (text-response 426 "websocket upgrade required")))

(def static-root "/data/static")

(defn static-response [uri]
  (if-let [file-response (response/file-response (subs uri (count "/static/"))
                                                {:root static-root :index-files? false})]
    (response/content-type file-response
                           (or (mime/ext-mime-type uri {"js" "application/javascript"})
                               "application/octet-stream"))
    (text-response 404 "not found")))

(defn app [request]
  (case (:uri request)
    ("/baseline11" "/baseline2") (text-response 200 (str (request-sum request)))
    "/pipeline" (text-response 200 "ok")
    "/echo" (if (= :post (:request-method request))
              (echo-response request)
              (text-response 405 "method not allowed"))
    "/ws" (websocket-echo request)
    (cond
      (re-matches #"/json/[0-9]+" (:uri request)) (json-items-response request)
      (re-matches #"/delay/[0-9]+" (:uri request)) (delay-response request)
      :else (text-response 404 "not found"))))

(def compressed-handler
  (let [handler (params/wrap-params app)]
    (fn [request]
      (let [response (handler request)]
        (if (and (gzip/supported-response? response) (gzip/accepts-gzip? request))
          ;; JSON is already materialized. Compress on Enso's virtual thread, not
          ;; wrap-gzip's piped stream backed by a platform-thread future per response.
          (let [out (ByteArrayOutputStream.)]
            (with-open [gzip-out (GZIPOutputStream. out)]
              (.write gzip-out (.getBytes ^String (:body response) StandardCharsets/UTF_8)))
            (-> response
                (update :headers gzip/set-response-headers)
                (assoc-in [:headers "Vary"] "Accept-Encoding")
                (assoc :body (.toByteArray out))))
          response)))))

(defn handler [request]
  (cond
    (= "/ws" (:uri request)) (app request)
    (and (#{:get :head} (:request-method request))
         (str/starts-with? (:uri request) "/static/")) (static-response (:uri request))
    :else (compressed-handler request)))

(defn pem->ssl-context ^SSLContext [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        chain (into-array Certificate certs)
        der   (->> (-> (slurp key-path)
                       (str/replace #"-----(BEGIN|END) PRIVATE KEY-----" "")
                       (str/replace #"\s" ""))
                   (.decode (Base64/getDecoder)))
        key   (.generatePrivate (KeyFactory/getInstance "RSA")
                                (PKCS8EncodedKeySpec. der))
        pw    (char-array 0)
        store (doto (KeyStore/getInstance "PKCS12")
                (.load nil pw)
                (.setKeyEntry "server" key pw chain))
        kmf   (doto (KeyManagerFactory/getInstance (KeyManagerFactory/getDefaultAlgorithm))
                (.init store pw))]
    (doto (SSLContext/getInstance "TLS")
      (.init (.getKeyManagers kmf) nil nil))))

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [cert    "/certs/server.crt"
        key     "/certs/server.key"
        ssl     (when (and (.exists (io/file cert)) (.exists (io/file key)))
                  (pem->ssl-context cert key))
        options (cond-> [{:port 8080} {:port 8082 :http2c true}]
                  ssl (into [{:port 8081 :ssl-context ssl}
                             {:port 8443 :ssl-context ssl :http2 true
                              :http3 true :http3-cert-path cert :http3-key-path key}]))
        ;; The async profile holds 32,000 connections; retain a finite cap with headroom.
        servers (mapv #(enso/run-server handler (assoc % :max-connections 40000)) options)]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable (fn []
                                          (doseq [server servers]
                                            (enso/stop server)))))
    @(promise)))
