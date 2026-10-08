(ns httparena.busker.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [ol.busker :as busker])
  (:import
   [java.io InputStream]
   [java.net URLDecoder]
   [java.nio.file Files Path Paths]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")
(def ^Path static-root (Paths/get "/data/static" (make-array String 0)))

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

(defn json-response [body]
  {:status 200
   :headers {"content-type" json-content-type}
   :body (json/write-str body)})

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
      (json-response {:items (compute-json-items items multiplier)
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

(defn config []
  {:tls {:certificates {:load [{:type :pem
                                :cert-file "/certs/server.crt"
                                :key-file "/certs/server.key"}]}}
   :entrypoints {:http {:bind "0.0.0.0:8080"
                        :http1? true
                        :http2? false
                        :http3? false
                        :tls false}
                 :h2c {:bind "0.0.0.0:8082"
                       :http1? false
                       :http2? true
                       :http3? false
                       :tls false}
                 :https {:bind "0.0.0.0:8081"
                         :http1? true
                         :http2? false
                         :http3? false
                         :tls {:tls-compatibility-mode :modern}}
                 :h2-h3 {:bind "0.0.0.0:8443"
                         :http1? false
                         :http2? true
                         :http3? true
                         :tls {:tls-compatibility-mode :modern}}}
   :dispatch [{:handler app}]})

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [server (busker/start! (config))]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable #(busker/stop! server)))
    @(promise)))