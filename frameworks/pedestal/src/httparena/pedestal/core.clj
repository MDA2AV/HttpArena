(ns httparena.pedestal.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [hikari-cp.core :as hikari]
   [io.pedestal.connector :as conn]
   [io.pedestal.http.jetty :as jetty]
   [io.pedestal.http.route :as route]
   [io.pedestal.service.interceptors :as interceptors]
   [next.jdbc :as jdbc]
   [next.jdbc.result-set :as rs]
   [ring.util.response :as response])
  (:import
   [org.eclipse.jetty.ee10.servlet ServletContextHandler]
   [org.eclipse.jetty.server.handler.gzip GzipHandler]
   [org.eclipse.jetty.util VirtualThreads]
   [org.eclipse.jetty.util.thread QueuedThreadPool]
   [org.postgresql.util PGobject]
   (java.io InputStream OutputStream)
   (java.net URI)))

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
  (let [query-params (:query-params request)
        a (parse-long-safe (get query-params :a))
        b (parse-long-safe (get query-params :b))
        body (if (= :post (:request-method request))
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

(defn empty-response []
  (json-response 200 {:items []
                      :count 0}))

(defn baseline-handler [request]
  (text-response 200 (str (request-sum request))))

(defn pipeline-handler [_request]
  (text-response 200 "ok"))

(defn json-handler [request]
  (if-let [source @dataset]
    (let [requested-count (min (parse-long-safe (get-in request [:path-params :count]))
                               (count source))
          multiplier      (parse-long-safe (get-in request [:query-params :m]) 1)
          items           (compute-json-items (take requested-count source) multiplier)]
      (json-response 200 {:items items
                          :count (count items)}))
    (text-response 500 "dataset.json not available")))

(defn echo-handler [request]
  ;; Collected: the response needs a Content-Length, and a chunked request
  ;; carries none to forward until the body is in.
  (with-open [^InputStream stream (:body request)]
    {:status  200
     :headers {"Content-Type" "application/octet-stream"}
     :body    (.readAllBytes stream)}))

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
  (let [query-params (into {}
                           (map (fn [[key value]] [(name key) value])
                                (:query-params request)))
        min-price    (parse-int (get query-params "min") 10)
        max-price    (parse-int (get query-params "max") 50)
        limit        (-> (parse-int (get query-params "limit") 50)
                         (max 1)
                         (min 50))]
    (if-let [database (datasource!)]
      (try
        (let [rows (jdbc/execute! database
                                  [async-db-query min-price max-price limit]
                                  {:builder-fn rs/as-unqualified-lower-maps})
              items (rows->items rows)]
          (json-response 200 {:items items
                              :count (count items)}))
        (catch Exception _
          (empty-response)))
      (empty-response))))

(defn static-content-type [filename]
  (let [extension (some-> filename (str/split #"\.") last str/lower-case)]
    (get static-content-types extension "application/octet-stream")))

(defn static-response [filename]
  (when (and filename
             (not (str/blank? filename))
             (not (str/includes? filename "/"))
             (not (str/includes? filename "..")))
    (if-let [file-response (response/file-response filename {:root static-root
                                                             :index-files? false})]
      (response/content-type file-response (static-content-type filename))
      (text-response 404 "not found"))))

(defn static-handler [request]
  (or (static-response (get-in request [:path-params :filename]))
      (text-response 404 "not found")))

(def routes
  #{["/baseline11" :get baseline-handler :route-name ::baseline-get]
    ["/baseline11" :post baseline-handler :route-name ::baseline-post]
    ["/json/:count" :get json-handler :route-name ::json]
    ["/async-db" :get async-db-handler :route-name ::async-db]
    ["/echo" :post echo-handler :route-name ::echo]
    ["/static/:filename" :get static-handler :route-name ::static]
    ["/pipeline" :get pipeline-handler :route-name ::pipeline]})

(defn virtual-thread-pool []
  (doto (QueuedThreadPool.)
    (.setVirtualThreadsExecutor (VirtualThreads/getDefaultVirtualThreadsExecutor))))

(defn create-connector []
  (-> (conn/default-connector-map "0.0.0.0" 8080)
      (assoc :join? true)
      (conn/with-interceptor interceptors/not-found)
      (conn/with-interceptor route/query-params)
      (conn/with-routes routes)
      (jetty/create-connector
       {:container-options {:thread-pool (virtual-thread-pool)
                            :context-configurator (fn [^ServletContextHandler context]
                                                    (let [gzip-handler (doto (GzipHandler.)
                                                                         (.addExcludedPaths
                                                                          (into-array String ["/static/*"])))]
                                                      (.insertHandler context gzip-handler)
                                                      context))}})))

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (.addShutdownHook (Runtime/getRuntime) (Thread. ^Runnable close-datasource!))
  (conn/start! (create-connector)))
