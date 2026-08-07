(ns httparena.http-kit.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [hikari-cp.core :as hikari]
   [next.jdbc :as jdbc]
   [next.jdbc.result-set :as rs]
   [org.httpkit.server :as http-kit]
   [ring.middleware.gzip :as gzip]
   [ring.middleware.params :as params]
   [ring.util.response :as response])
  (:import
   [org.postgresql.util PGobject]
   (java.io InputStream OutputStream)))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")
(def max-request-body-bytes (* 32 1024 1024))
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
   (or (some-> value str str/trim not-empty parse-long)
       default)))

(defn load-dataset [path]
  (when (.exists (io/file path))
    (json/read-str (slurp path) :key-fn keyword)))

(defonce dataset
  (delay (load-dataset "/data/dataset.json")))

(defonce async-db (atom nil))

(defn compute-json-items [items multiplier]
  (mapv (fn [{:keys [price quantity] :as item}]
          (assoc item :total (* price quantity multiplier)))
        items))

(defn request-sum [request]
  (let [params (:params request)
        a (parse-long-safe (get params "a"))
        b (parse-long-safe (get params "b"))
        body (if (= :post (:request-method request))
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
   :headers {"content-type" json-content-type}
   :body (json/write-str body)})

(defn json-items-response [request]
  (if-let [source @dataset]
    (let [uri            (:uri request)
          [_ path-count] (re-matches #"/json/([0-9]+)" uri)
          item-count     (if path-count (parse-long-safe path-count) (count source))
          multiplier     (parse-long-safe (get-in request [:params "m"]) 1)
          items          (take item-count source)]
      (json-response 200 {:items (compute-json-items items multiplier)
                          :count (count items)}))
    (text-response 500 "dataset.json not available")))

(defn tags->vector [tags]
  (cond
    (instance? PGobject tags) (json/read-str (.getValue ^PGobject tags))
    (string? tags) (json/read-str tags)
    (sequential? tags) (vec tags)
    :else (throw (ex-info "unexpected tags value" {:type (type tags)}))))

(defn jdbc-row->item [{:keys [id name category price quantity active tags rating_score rating_count]}]
  {:id       id
   :name     name
   :category category
   :price    price
   :quantity quantity
   :active   active
   :tags     (tags->vector tags)
   :rating   {:score rating_score
              :count rating_count}})

(defn database-max-conn []
  (try
    (max 1 (Integer/parseInt (or (System/getenv "DATABASE_MAX_CONN") "256")))
    (catch NumberFormatException _
      256)))

(defn database-url->hikari-options [database-url]
  (let [uri                 (java.net.URI. database-url)
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

(defn init-async-db! []
  (or @async-db
      (locking async-db
        (or @async-db
            (try
              (let [datasource (hikari/make-datasource
                                (database-url->hikari-options
                                 (System/getenv "DATABASE_URL")))]
                (reset! async-db datasource))
              (catch Exception _
                nil))))))

(defn close-async-db! []
  (when-let [datasource @async-db]
    (hikari/close-datasource datasource)
    (reset! async-db nil)))

(defn async-db-statement [params]
  (let [min-price (parse-long-safe (get params "min") 10)
        max-price (parse-long-safe (get params "max") 50)
        limit     (min 50 (max 1 (parse-long-safe (get params "limit") 50)))]
    [async-db-query min-price max-price limit]))

(defn async-db-response [request]
  (if-let [datasource (init-async-db!)]
    (try
      (let [rows  (jdbc/execute! datasource
                                 (async-db-statement (:params request))
                                 {:builder-fn rs/as-unqualified-lower-maps})
            items (mapv jdbc-row->item rows)]
        (json-response 200 {:items items
                            :count (count items)}))
      (catch Exception _
        (json-response 200 {:items [] :count 0})))
    (json-response 200 {:items [] :count 0})))

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

(defn app [request]
  (case (:uri request)
    "/baseline11" (text-response 200 (str (request-sum request)))
    "/async-db" (async-db-response request)
    "/upload" (text-response 200 (str (count-stream-bytes (:body request))))
    "/pipeline" (text-response 200 "ok")
    (if (re-matches #"/json/[0-9]+" (:uri request))
      (json-items-response request)
      (text-response 404 "not found"))))

(def handler
  (let [compressed-handler (-> app
                               params/wrap-params
                               gzip/wrap-gzip)]
    (fn [request]
      (if (str/starts-with? (:uri request) "/static/")
        (or (static-response (:uri request))
            (text-response 404 "not found"))
        (compressed-handler request)))))

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [stop-server (http-kit/run-server handler {:ip "0.0.0.0"
                                                  :max-body max-request-body-bytes
                                                  :port 8080})]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable (fn []
                                          (stop-server)
                                          (close-async-db!))))
    @(promise)))
