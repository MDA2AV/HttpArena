(ns httparena.ring.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [hikari-cp.core :as hikari]
   [next.jdbc :as jdbc]
   [next.jdbc.result-set :as rs]
   [ring.adapter.jetty :as jetty]
   [ring.middleware.params :as params]
   [ring.util.response :as response]
   [selmer.parser :as selmer])
  (:import
   [java.io InputStream OutputStream]
   [java.net URI]
   [org.eclipse.jetty.server Server]
   [org.eclipse.jetty.server.handler.gzip GzipHandler]
   [org.eclipse.jetty.util VirtualThreads]
   [org.eclipse.jetty.util.thread QueuedThreadPool]
   [org.postgresql.util PGobject]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")
(def html-content-type "text/html; charset=utf-8")
(def static-root "/data/static")
(def async-db-query
  "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
   FROM items
   WHERE price BETWEEN ? AND ?
   LIMIT ?")
(def fortunes-query "SELECT id, message FROM fortune")
(def runtime-fortune
  {:id 0 :message "Additional fortune added at request time."})
(def static-content-types
  {"css" "text/css"
   "js" "application/javascript"
   "html" "text/html"
   "woff2" "font/woff2"
   "svg" "image/svg+xml"
   "webp" "image/webp"
   "json" "application/json"})

(defn parse-long-safe [value]
  (or (some-> value str str/trim not-empty parse-long)
      0))

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

(defn html-response [status body]
  {:status status
   :headers {"Content-Type" html-content-type}
   :body body})

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

(defonce fortunes-template
  (delay (selmer/parse selmer/parse-file "fortunes.html" {})))

(defn render-fortunes [fortunes]
  (selmer/render-template @fortunes-template {:fortunes fortunes}))

(defn fortunes-handler [_request]
  (if-let [database (datasource!)]
    (try
      (let [rows     (jdbc/execute! database
                                    [fortunes-query]
                                    {:builder-fn rs/as-unqualified-lower-maps})
            fortunes (sort-by :message (conj rows runtime-fortune))]
        (html-response 200 (render-fortunes fortunes)))
      (catch Exception _
        (text-response 500 "fortunes unavailable")))
    (text-response 500 "fortunes unavailable")))

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

(defn json-endpoint-response [request item-count]
  (if-let [source @dataset]
    (let [items      (take (min 50 (parse-long-safe item-count)) source)
          multiplier (parse-long-safe (get (:params request) "m" 1))]
      (json-response 200 {:items (compute-json-items items multiplier)
                          :count (count items)}))
    (text-response 500 "dataset.json not available")))

(defn method-not-allowed-response []
  (text-response 405 "method not allowed"))

(defn app [request]
  (let [uri    (:uri request)
        method (:request-method request)]
    (cond
      (str/starts-with? uri "/static/")
      (if (= :get method)
        (or (static-response uri)
            (text-response 404 "not found"))
        (method-not-allowed-response))

      :else
      (if-let [[_ item-count] (re-matches #"/json/(\d+)" uri)]
        (if (= :get method)
          (json-endpoint-response request item-count)
          (method-not-allowed-response))
        (case uri
          "/baseline11" (case method
                          (:get :post) (text-response 200 (str (request-sum request)))
                          (method-not-allowed-response))
          "/async-db" (if (= :get method)
                                    (async-db-handler request)
                                    (method-not-allowed-response))
          "/fortunes" (if (= :get method)
                        (fortunes-handler request)
                        (method-not-allowed-response))
          "/upload" (if (= :post method)
                      (text-response 200 (str (count-stream-bytes (:body request))))
                      (method-not-allowed-response))
          "/pipeline" (if (= :get method)
                        (text-response 200 "ok")
                        (method-not-allowed-response))
          (text-response 404 "not found"))))))

(def handler
  (params/wrap-params app))

(defn virtual-thread-pool []
  (doto (QueuedThreadPool.)
    (.setVirtualThreadsExecutor (VirtualThreads/getDefaultVirtualThreadsExecutor))))

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (.addShutdownHook (Runtime/getRuntime) (Thread. ^Runnable close-datasource!))
  (jetty/run-jetty handler
                   {:host         "0.0.0.0"
                    :configurator (fn [^Server server]
                                    (let [gzip-handler (doto (GzipHandler.)
                                                         (.setExcludedPaths
                                                          (into-array String ["/static/*"]))
                                                         (.setHandler (.getHandler server)))]
                                      (.setHandler server gzip-handler)))
                    :join?        true
                    :port         8080
                    :thread-pool  (virtual-thread-pool)}))
