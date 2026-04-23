(ns ring.core
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [jj.sql.boa :as boa]
            [jj.sql.boa.query.next-jdbc :refer [->NextJdbcAdapter]]
            [jj.tassu :refer [GET POST route]]
            [jsonista.core :as json]
            [next.jdbc :as jdbc]
            [ring-http-exchange.core :as server])
  (:import (com.zaxxer.hikari HikariConfig HikariDataSource)
           (java.io BufferedInputStream ByteArrayOutputStream InputStream)
           (java.net URI)
           (java.util.concurrent Executors)
           (java.util.zip GZIPOutputStream))
  (:gen-class))

(def default-executor (Executors/newVirtualThreadPerTaskExecutor))

(def ^:private ^:const ct-json "application/json")
(def ^:private ^:const ct-text "text/plain")
(def ^:private ^:const ct-octet "application/octet-stream")
(def ^:private ^:const hdr-ct "Content-Type")
(def ^:private ^:const hdr-ce "Content-Encoding")
(def ^:private ^:const hdr-server "Server")
(def ^:private ^:const server-name "ring-http-exchange")
(def ^:private ^:const enc-gzip "gzip")
(def ^:private ^:const ae-header "accept-encoding")
(def ^:private ^:const dot ".")
(def ^:private ^:const not-found-body "Not found")
(def ^:private ^:const empty-db-body "{\"items\":[],\"count\":0}")
(def ^:private ^:const dataset-path "/data/dataset.json")
(def ^:private ^:const db-path "/data/benchmark.db")
(def ^:private ^:const static-dir "/data/static")
(def ^:private ^:const param-min "min")
(def ^:private ^:const param-max "max")
(def ^:private ^:const param-limit "limit")
(def ^:private ^:const param-m "m")
(def ^:private ^:const pg-prefix "postgres://")
(def ^:private ^:const pg-replace "postgresql://")

(def ^:private json-headers {hdr-ct ct-json hdr-server server-name})
(def ^:private json-gzip-headers {hdr-ct ct-json hdr-ce enc-gzip hdr-server server-name})
(def ^:private text-headers {hdr-ct ct-text hdr-server server-name})
(def ^:private empty-db-response {:status 200 :headers json-headers :body empty-db-body})

(defn- load-json [path]
  (when (.exists (io/file path))
    (json/read-value (slurp path) json/keyword-keys-object-mapper)))

(defn- process-item [item ^long m]
  (assoc item :total (* (:price item) (:quantity item) m)))

(defn- parse-qs [^String qs]
  (when qs
    (loop [i 0 m (transient {})]
      (if (>= i (.length qs))
        (persistent! m)
        (let [amp (.indexOf qs (int \&) i)
              end (if (neg? amp) (.length qs) amp)
              eq (.indexOf qs (int \=) i)]
          (if (and (>= eq 0) (< eq end))
            (recur (inc end) (assoc! m (subs qs i eq) (subs qs (inc eq) end)))
            (recur (inc end) m)))))))

(defn- sum-params [^String qs]
  (if (nil? qs) 0
                (loop [i 0 total-sum 0]
                  (if (>= i (.length qs))
                    total-sum
                    (let [amp (.indexOf qs (int \&) i)
                          end (if (neg? amp) (.length qs) amp)
                          eq (.indexOf qs (int \=) i)]
                      (if (and (>= eq 0) (< eq end))
                        (recur (inc end)
                               (+ total-sum
                                  (long (try (Long/parseLong (subs qs (inc eq) end))
                                             (catch Exception _ 0)))))
                        (recur (inc end) total-sum)))))))

(defn- gzip-bytes [^bytes data]
  (let [baos (ByteArrayOutputStream. (alength data))
        gos (GZIPOutputStream. baos)]
    (.write gos data)
    (.close gos)
    (.toByteArray baos)))

(defn- json-response [data]
  {:status 200 :headers json-headers :body (json/write-value-as-string data)})

(defn- text-response [s]
  {:status 200 :headers text-headers :body (str s)})

(defn- parse-long-param [params k default]
  (try (Long/parseLong (get params k)) (catch Exception _ default)))

(defn- parse-double-param [params k default]
  (try (Double/parseDouble (get params k)) (catch Exception _ default)))

(def ^:private ^:const extension-map
  {".css"   "text/css"
   ".js"    "application/javascript"
   ".html"  "text/html"
   ".woff2" "font/woff2"
   ".svg"   "image/svg+xml"
   ".webp"  "image/webp"
   ".json"  ct-json})

(defn- get-content-type [^String name]
  (let [dot-index (.lastIndexOf name ^String dot)
        ext (if (>= dot-index 0) (subs name dot-index) "")]
    (get extension-map ext ct-octet)))

(defn- transform-row [row parse-tags parse-active]
  {:id     (:id row) :name (:name row) :category (:category row)
   :price  (:price row) :quantity (:quantity row) :active (parse-active (:active row))
   :tags   (parse-tags (:tags row))
   :rating {:score (:rating_score row) :count (:rating_count row)}})

(defn -main [& _]
  (let [dataset (load-json (or (System/getenv "DATASET_PATH") dataset-path))
        adapter (->NextJdbcAdapter)
        sqlite-tag-parser #(json/read-value % json/keyword-keys-object-mapper)
        sqlite-active #(== 1 (long %))
        pg-tag-parser #(json/read-value (str %))
        db-file-exists? (.exists (io/file db-path))
        db-query-fn (when db-file-exists?
                      (boa/build-query adapter "sql/db-query"))
        sqlite-ds (when db-file-exists?
                    (jdbc/get-datasource {:dbtype "sqlite" :dbname db-path :read-only true}))
        pg-state (when-let [url (System/getenv "DATABASE_URL")]
                   (try
                     (let [uri (URI. (str/replace url pg-prefix pg-replace))
                           host (.getHost uri)
                           port (if (pos? (.getPort uri)) (.getPort uri) 5432)
                           db (subs (.getPath uri) 1)
                           [user pass] (str/split (.getUserInfo uri) #":" 2)
                           ds (let [cfg (doto (HikariConfig.)
                                          (.setJdbcUrl (str "jdbc:postgresql://" host ":" port "/" db))
                                          (.setUsername user)
                                          (.setPassword (or pass ""))
                                          (.setMaximumPoolSize (try (Integer/parseInt (System/getenv "DATABASE_MAX_CONN"))
                                                                    (catch Exception _ 256)))
                                          (.setReadOnly true))]
                                (HikariDataSource. cfg))]
                       {:ds    ds
                        :query (boa/build-query adapter "sql/pg-query")})
                     (catch Exception _ nil)))
        pg-ds (:ds pg-state)
        pg-query (:query pg-state)

        handler
        (route
          {"/baseline11"       [(GET (fn [req] (text-response (sum-params (:query-string req)))))
                                (POST (fn [req]
                                        (let [s (sum-params (:query-string req))
                                              b (slurp (:body req))
                                              n (try (Long/parseLong (str/trim b)) (catch Exception _ 0))]
                                          (text-response (+ s n)))))]
           "/json/:count"      [(GET (fn [req]
                                       (let [count (try (Long/parseLong (get-in req [:params :count])) (catch Exception _ 50))
                                             count (min count (long (clojure.core/count dataset)))
                                             params (parse-qs (:query-string req))
                                             m (parse-long-param params param-m 1)
                                             items (map #(process-item % m) (subvec dataset 0 count))
                                             body-bytes (json/write-value-as-bytes {:items items :count (clojure.core/count items)})
                                             ae (some (fn [[k v]] (when (.equalsIgnoreCase ^String k ae-header) v)) (:headers req))]
                                         (if (and ae (.contains ^String ae enc-gzip))
                                           {:status 200 :headers json-gzip-headers :body (gzip-bytes body-bytes)}
                                           {:status 200 :headers json-headers :body (String. body-bytes)}))))]
           "/upload"           [(POST (fn [req]
                                        (with-open [^InputStream in (:body req)]
                                          (text-response (alength (.readAllBytes in))))))]
           "/db"               [(GET (fn [req]
                                       (if db-query-fn
                                         (let [params (parse-qs (:query-string req))
                                               min-p (parse-double-param params param-min 10.0)
                                               max-p (parse-double-param params param-max 50.0)
                                               limit (parse-long-param params param-limit 50)
                                               items (try (map #(transform-row % sqlite-tag-parser sqlite-active)
                                                               (db-query-fn sqlite-ds {:min min-p :max max-p :limit limit}))
                                                          (catch Exception _ []))]
                                           (json-response {:items items :count (clojure.core/count items)}))
                                         empty-db-response)))]
           "/async-db"         [(GET (fn [req]
                                       (if pg-query
                                         (let [params (parse-qs (:query-string req))
                                               min-p (parse-double-param params param-min 10.0)
                                               max-p (parse-double-param params param-max 50.0)
                                               limit (parse-long-param params param-limit 50)
                                               items (try (map #(transform-row % pg-tag-parser identity)
                                                               (pg-query pg-ds {:min min-p :max max-p :limit limit}))
                                                          (catch Exception _ []))]
                                           (json-response {:items items :count (clojure.core/count items)}))
                                         empty-db-response)))]
           "/static/:filename" [(GET (fn [req]
                                       (let [name (get-in req [:params :filename])
                                             f (io/file static-dir name)]
                                         (if (.exists f)
                                           {:status 200 :headers {hdr-ct (get-content-type name) hdr-server server-name} :body f}
                                           {:status 404 :body not-found-body}))))]
           "/"                 [(GET (fn [_] (text-response server-name)))]})]

    (server/run-http-server handler {:port              8080
                                     :lazy-request-map? true
                                     :executor          default-executor})
    (println "Server running on port 8080")))
