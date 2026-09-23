(ns httparena.pedestal.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [io.pedestal.connector :as conn]
   [io.pedestal.http.jetty :as jetty]
   [io.pedestal.http.route :as route]
   [io.pedestal.interceptor :as interceptor]
   [io.pedestal.service.interceptors :as interceptors]
   [io.pedestal.service.websocket :as websocket])
  (:import
   [java.io InputStream]
   [org.eclipse.jetty.ee10.servlet ServletContextHandler]
   [org.eclipse.jetty.server.handler.gzip GzipHandler]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (or (some-> value str str/trim parse-long) default)))

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
  (let [query-params (:query-params request)
        a            (parse-long-safe (get query-params :a))
        b            (parse-long-safe (get query-params :b))
        body         (if (= :post (:request-method request))
                       (parse-long-safe (slurp (:body request)))
                       0)]
    (+ a b body)))

(defn text-response [status body]
  {:status status
   :headers {"content-type" "text/plain"}
   :body body})

(defn json-response [status body]
  {:status status
   :headers {"Content-Type" json-content-type}
   :body (json/write-str body)})

(defn baseline-handler [request]
  (text-response 200 (str (request-sum request))))

(defn pipeline-handler [_request]
  (text-response 200 "ok"))

(defn echo-handler [request]
  (with-open [^InputStream stream (:body request)]
    {:status 200
     :headers {"Content-Type" "application/octet-stream"}
     :body (.readAllBytes stream)}))

(defn delay-handler [request]
  (let [^long ms (parse-long-safe (get-in request [:path-params :ms]))]
    (when (pos? ms)
      (Thread/sleep ms))
    (text-response 200 (str ms))))

(defn json-handler [request]
  (if-let [source @dataset]
    (let [requested-count (min (parse-long-safe (get-in request [:path-params :count]))
                               (count source))
          multiplier      (parse-long-safe (get-in request [:query-params :m]) 1)
          items           (compute-json-items (take requested-count source) multiplier)]
      (json-response 200 {:items items
                          :count (count items)}))
    (text-response 500 "dataset.json not available")))

(def static-root "/data/static")

(def static-content-types
  {"css" "text/css"
   "js" "application/javascript"
   "html" "text/html"
   "woff2" "font/woff2"
   "svg" "image/svg+xml"
   "webp" "image/webp"
   "json" "application/json"})

(defn static-content-type [filename]
  (let [extension (some-> filename (str/split #"\.") last str/lower-case)]
    (get static-content-types extension "application/octet-stream")))

(defn static-handler [request]
  (let [filename (get-in request [:path-params :filename])]
    (if (and (seq filename)
             (not (str/includes? filename "/"))
             (not (str/includes? filename "..")))
      (let [file (io/file static-root filename)]
        (if (.isFile file)
          {:status 200
           :headers {"Content-Type" (static-content-type filename)}
           :body file}
          (text-response 404 "not found")))
      (text-response 404 "not found"))))

(def websocket-echo
  (interceptor/interceptor
   {:name ::websocket-echo
    :enter (fn [{:keys [request] :as context}]
             (if (= "websocket" (some-> (get-in request [:headers "upgrade"])
                                         str/lower-case))
               (websocket/upgrade-request-to-websocket
                context
                {:on-text (fn [channel _ text]
                            (websocket/send-text! channel text))
                 :on-binary (fn [channel _ data]
                              (websocket/send-binary! channel data))})
               (assoc context :response (text-response 426 "WebSocket upgrade required"))))}))

(def routes
  #{["/baseline11" :get baseline-handler :route-name ::baseline-get]
    ["/baseline11" :post baseline-handler :route-name ::baseline-post]
    ["/baseline2" :get baseline-handler :route-name ::baseline-h2]
    ["/echo" :post echo-handler :route-name ::echo]
    ["/json/:count" :get json-handler :route-name ::json]
    ["/static/:filename" :get static-handler :route-name ::static]
    ["/ws" :get websocket-echo :route-name ::websocket]
    ["/pipeline" :get pipeline-handler :route-name ::pipeline]
    ["/delay/:ms" :get delay-handler :route-name ::delay]})

(defn create-connector [port container-options]
  (-> (conn/default-connector-map "0.0.0.0" port)
      (assoc :join? false)
      (conn/with-interceptor interceptors/not-found)
      (conn/with-interceptor route/query-params)
      (conn/with-routes routes)
      (jetty/create-connector
       {:container-options (merge {:h2c? false
                                   :context-configurator
                                   (fn [^ServletContextHandler context]
                                     (let [gzip-handler (doto (GzipHandler.)
                                                          (.addExcludedPaths (into-array String ["/static/*"])))]
                                       (.insertHandler context gzip-handler)
                                       context))}
                                  container-options)})))

(def tls-options
  {:keystore "/tmp/server.p12"
   :key-password "httparena"})

(defn create-connectors []
  [(create-connector 8080 {})
   (create-connector nil (assoc tls-options :ssl? true :ssl-port 8081))
   (create-connector 8082 {:h2c? true})
   (create-connector nil (assoc tls-options :h2? true :ssl-port 8443))])

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [connectors (create-connectors)]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable #(doseq [connector connectors]
                                          (conn/stop! connector))))
    (doseq [connector connectors]
      (conn/start! connector))
    @(promise)))
