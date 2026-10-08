(ns httparena.hirundo.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [s-exp.hirundo :as hirundo]
   [s-exp.hirundo.websocket :as ws])
  (:import
   [io.helidon.common.configurable Resource]
   [io.helidon.common.pki Keys Keys$Builder PemKeys PemKeys$Builder]
   [io.helidon.common.tls TlsConfig TlsConfig$Builder]
   [java.io ByteArrayOutputStream InputStream]
   [java.net URLDecoder]
   [java.nio.charset StandardCharsets]
   [java.nio.file Files Path Paths]
   [java.util.zip GZIPOutputStream]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")
(def ^Path static-root (Paths/get "/data/static" (make-array String 0)))
(def certs-dir (or (System/getenv "HIRUNDO_CERTS_DIR") "/certs"))

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (or (some-> value str str/trim not-empty parse-long)
       default)))

(defn query-params [request]
  (into {}
        (keep (fn [part]
                (let [[key value] (str/split part #"=" 2)]
                  (when key
                    [(URLDecoder/decode (str key) "UTF-8")
                     (URLDecoder/decode (str (or value "")) "UTF-8")]))))
        (str/split (or (:query-string request) "") #"&")))

(defn load-dataset [path]
  (when (.exists (io/file path))
    (json/read-str (slurp path) :key-fn keyword)))

(defonce dataset
  (delay (load-dataset "/data/dataset.json")))

(defn compute-json-items [items multiplier]
  (mapv (fn [{:keys [price quantity] :as item}]
          (assoc item :total (* price quantity multiplier)))
        items))

(defn text-response [status body]
  {:status status
   :headers {"content-type" "text/plain"}
   :body body})

(defn gzip-bytes [^String body]
  (let [^ByteArrayOutputStream output (ByteArrayOutputStream.)
        ^bytes bytes (.getBytes body StandardCharsets/UTF_8)]
    (with-open [^GZIPOutputStream gzip (GZIPOutputStream. output)]
      (.write gzip bytes))
    (.toByteArray output)))

(defn json-response [request body]
  (let [body (json/write-str body)]
    (cond-> {:status 200
             :headers {"content-type" json-content-type}
             :body body}
      (str/includes? (get-in request [:headers "accept-encoding"] "") "gzip")
      (assoc :headers {"content-type" json-content-type
                       "content-encoding" "gzip"}
             :body (gzip-bytes body)))))

(defn request-sum [request]
  (let [params (query-params request)
        body   (if (= :post (:request-method request))
                 (parse-long-safe (slurp (:body request)))
                 0)]
    (+ (parse-long-safe (get params "a"))
       (parse-long-safe (get params "b"))
       body)))

(defn json-items-response [request]
  (if-let [source @dataset]
    (let [[_ path-count] (re-matches #"/json/([0-9]+)" (:uri request))
          params     (query-params request)
          item-count (parse-long-safe path-count)
          multiplier (parse-long-safe (get params "m") 1)
          items      (take item-count source)]
      (json-response request
                     {:items (compute-json-items items multiplier)
                      :count (count items)}))
    (text-response 500 "dataset.json not available")))

(defn delay-response [request]
  (let [ms (parse-long-safe (subs (:uri request) 7))]
    (when (pos? ms)
      (Thread/sleep (long ms)))
    (text-response 200 (str ms))))

(defn content-type [filename]
  (cond
    (str/ends-with? filename ".css") "text/css"
    (str/ends-with? filename ".js") "application/javascript"
    (str/ends-with? filename ".json") json-content-type
    (str/ends-with? filename ".html") "text/html"
    (str/ends-with? filename ".svg") "image/svg+xml"
    (str/ends-with? filename ".woff2") "font/woff2"
    (str/ends-with? filename ".webp") "image/webp"
    :else "application/octet-stream"))

(defn static-response [uri]
  (let [filename (subs uri (count "/static/"))
        ^Path path (.normalize (.resolve static-root ^String filename))]
    (if (and (.startsWith path static-root)
             (Files/isRegularFile path (make-array java.nio.file.LinkOption 0)))
      {:status 200
       :headers {"content-type" (content-type filename)}
       :body (Files/readAllBytes path)}
      (text-response 404 "not found"))))

(defn echo-response [request]
  (let [^InputStream body (:body request)]
    {:status 200
     :headers {"content-type" "application/octet-stream"}
     :body (if body (.readAllBytes body) (byte-array 0))}))

(defn app [request]
  (let [uri (:uri request)]
    (cond
      (or (= uri "/baseline11") (= uri "/baseline2"))
      (text-response 200 (str (request-sum request)))

      (= uri "/pipeline")
      (text-response 200 "ok")

      (= uri "/echo")
      (if (= :post (:request-method request))
        (echo-response request)
        (text-response 405 "method not allowed"))

      (re-matches #"/delay/[0-9]+" uri)
      (delay-response request)

      (re-matches #"/json/[0-9]+" uri)
      (json-items-response request)

      (str/starts-with? uri "/static/")
      (static-response uri)

      :else
      (text-response 404 "not found"))))

(defn tls-config []
  (let [^PemKeys$Builder pem-builder
        (doto (PemKeys/builder)
          (.key (Resource/create (Paths/get (str certs-dir "/server.key") (make-array String 0))))
          (.certChain (Resource/create (Paths/get (str certs-dir "/server.crt") (make-array String 0)))))
        ^PemKeys pem (.build pem-builder)
        ^Keys$Builder keys-builder (doto (Keys/builder) (.pem pem))
        ^Keys keys (.build keys-builder)
        ^TlsConfig$Builder tls-builder
        (doto (TlsConfig/builder)
          (.privateKey keys)
          (.privateKeyCertChain keys))]
    (.build tls-builder)))

(def websocket-endpoints
  {"/ws" {:message (fn [session data last]
                      (ws/send! session data last))}})

(defn listener-options [port tls?]
  (cond-> {:host "0.0.0.0"
           :port port
           :http-handler app
           :websocket-endpoints websocket-endpoints}
    tls? (assoc :tls (tls-config))))

(defn start-servers []
  [(hirundo/start! (listener-options 8080 false))
   (hirundo/start! (listener-options 8081 true))
   (hirundo/start! (listener-options 8082 false))
   (hirundo/start! (listener-options 8443 true))])

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [servers (start-servers)]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable #(run! hirundo/stop! servers)))
    @(promise)))
