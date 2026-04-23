(ns aleph-bench.core
  (:require [aleph.http :as http]
            [aleph.netty :as netty]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [jj.sql.async-boa :as async-boa]
            [jj.sql.boa :as boa]
            [jj.sql.boa.query.next-jdbc :refer [->NextJdbcAdapter]]
            [jj.sql.boa.query.vertx-pg :as vertx-adapter]
            [jj.tassu :refer [GET POST route]]
            [jsonista.core :as json]
            [manifold.deferred :as d]
            [manifold.stream :as s]
            [next.jdbc :as jdbc])
  (:import (io.netty.buffer ByteBuf PooledByteBufAllocator)
           (io.netty.channel ChannelOption)
           (io.netty.handler.codec.http HttpContentCompressor)
           (io.vertx.core Vertx)
           (io.vertx.pgclient PgBuilder PgConnectOptions)
           (io.vertx.sqlclient PoolOptions)
           (java.io ByteArrayOutputStream )
           (java.net URI))
  (:gen-class))

(def ^:private ^:const ct-json "application/json")
(def ^:private ^:const ct-text "text/plain")
(def ^:private ^:const ct-octet "application/octet-stream")
(def ^:private ^:const hdr-ct "Content-Type")
(def ^:private ^:const hdr-server "Server")
(def ^:private ^:const server-name "aleph")
(def ^:private ^:const dot ".")
(def ^:private ^:const not-found-body "Not found")
(def ^:private ^:const empty-db-body "{\"items\":[],\"count\":0}")
(def ^:private ^:const dataset-path "/data/dataset.json")
(def ^:private ^:const dataset-large-path "/data/dataset-large.json")
(def ^:private ^:const db-path "/data/benchmark.db")
(def ^:private ^:const param-min "min")
(def ^:private ^:const param-max "max")
(def ^:private ^:const param-limit "limit")
(def ^:private ^:const param-m "m")
(def ^:private ^:const pg-prefix "postgres://")
(def ^:private ^:const pg-replace "postgresql://")

(def ^:private json-headers {hdr-ct ct-json hdr-server server-name})
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
                (loop [i 0 sum 0]
                  (if (>= i (.length qs))
                    sum
                    (let [amp (.indexOf qs (int \&) i)
                          end (if (neg? amp) (.length qs) amp)
                          eq (.indexOf qs (int \=) i)]
                      (if (and (>= eq 0) (< eq end))
                        (recur (inc end)
                               (+ sum (long (try (Long/parseLong (subs qs (inc eq) end))
                                                 (catch Exception _ 0)))))
                        (recur (inc end) sum)))))))

(defn- json-response [data]
  {:status 200 :headers json-headers :body (json/write-value-as-string data)})

(defn- text-response [s]
  {:status 200 :headers text-headers :body (str s)})

(defn- parse-long-param [params k default]
  (try (Long/parseLong (get params k)) (catch Exception _ default)))

(defn- parse-double-param [params k default]
  (try (Double/parseDouble (get params k)) (catch Exception _ default)))

(defn- read-body-bytes [body]
  (if (nil? body)
    (d/success-deferred (byte-array 0))
    (d/chain
      (s/reduce
        (fn [^ByteArrayOutputStream baos ^ByteBuf buf]
          (try
            (let [n (.readableBytes buf)
                  arr (byte-array n)]
              (.readBytes buf arr)
              (.write baos arr 0 n)
              baos)
            (finally (.release buf))))
        (ByteArrayOutputStream.)
        body)
      (fn [^ByteArrayOutputStream baos] (.toByteArray baos)))))

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
  (netty/leak-detector-level! :disabled)
  (let [dataset (load-json (or (System/getenv "DATASET_PATH") dataset-path))
        json-body (let [items (mapv #(process-item % 1) dataset)]
                    (json/write-value-as-string {:items items :count (clojure.core/count items)}))
        large-dataset (load-json dataset-large-path)
        compression-body (when large-dataset
                           (let [items (mapv #(process-item % 1) large-dataset)]
                             (json/write-value-as-string {:items items :count (clojure.core/count items)})))
        adapter (->NextJdbcAdapter)
        sqlite-tag-parser #(json/read-value % json/keyword-keys-object-mapper)
        sqlite-active #(== 1 (long %))
        pg-tag-parser #(json/read-value (str %))
        db-query-fn (when (.exists (io/file db-path))
                      (boa/build-query adapter "sql/db-query"))
        tl-ds (ThreadLocal.)
        get-sqlite-ds (fn []
                        (or (.get tl-ds)
                            (let [ds (jdbc/get-datasource {:dbtype "sqlite" :dbname db-path :read-only true})]
                              (.set tl-ds ds)
                              ds)))
        pg-pool (when-let [url (System/getenv "DATABASE_URL")]
                  (try
                    (let [uri (URI. (str/replace url pg-prefix pg-replace))
                          host (.getHost uri)
                          port (if (pos? (.getPort uri)) (.getPort uri) 5432)
                          db (subs (.getPath uri) 1)
                          [user pass] (str/split (.getUserInfo uri) #":" 2)
                          max-conn (try (Integer/parseInt (System/getenv "DATABASE_MAX_CONN"))
                                        (catch Exception _ 256))
                          connect-opts (-> (PgConnectOptions.)
                                           (.setHost host)
                                           (.setPort port)
                                           (.setDatabase db)
                                           (.setUser user)
                                           (.setPassword (or pass "")))
                          pool-opts (-> (PoolOptions.) (.setMaxSize max-conn))
                          vertx (Vertx/vertx)]
                      (-> (PgBuilder/pool)
                          (.with pool-opts)
                          (.connectingTo connect-opts)
                          (.using vertx)
                          (.build)))
                    (catch Throwable t
                      (println "PG init failed:" (.getMessage t))
                      nil)))
        pg-query (when pg-pool
                   (async-boa/build-async-query (vertx-adapter/->VertxPgAdapter) "sql/pg-query"))

        handler
        (route
          {"/baseline11"       [(GET (fn [req] (text-response (sum-params (:query-string req)))))
                                (POST (fn [req]
                                        (let [s (sum-params (:query-string req))]
                                          (d/chain (read-body-bytes (:body req))
                                                   (fn [^bytes bs]
                                                     (let [n (try (Long/parseLong (str/trim (String. bs))) (catch Exception _ 0))]
                                                       (text-response (+ s n))))))))]
           "/json/:count"      [(GET (fn [req]
                                       (let [count (try (Long/parseLong (get-in req [:params :count])) (catch Exception _ 50))
                                             count (min count (long (clojure.core/count dataset)))
                                             params (parse-qs (:query-string req))
                                             m (parse-long-param params param-m 1)
                                             items (mapv #(process-item % m) (subvec dataset 0 count))]
                                         {:status 200 :headers json-headers :body (json/write-value-as-string {:items items :count (clojure.core/count items)})})))]
           "/json"             [(GET (fn [_] {:status 200 :headers json-headers :body json-body}))]
           "/compression"      [(GET (fn [_] {:status 200 :headers json-headers :body compression-body}))]
           "/upload"           [(POST (fn [req]
                                        (d/chain (read-body-bytes (:body req))
                                                 (fn [^bytes bs] (text-response (alength bs))))))]
           "/db"               [(GET (fn [req]
                                       (if db-query-fn
                                         (let [params (parse-qs (:query-string req))
                                               min-p (parse-double-param params param-min 10.0)
                                               max-p (parse-double-param params param-max 50.0)
                                               limit (parse-long-param params param-limit 50)
                                               items (try (mapv #(transform-row % sqlite-tag-parser sqlite-active) (db-query-fn (get-sqlite-ds) {:min min-p :max max-p :limit limit}))
                                                          (catch Exception _ []))]
                                           (json-response {:items items :count (clojure.core/count items)}))
                                         empty-db-response)))]
           "/async-db"         [(GET (fn [req]
                                       (if pg-query
                                         (let [params (parse-qs (:query-string req))
                                               min-p (parse-double-param params param-min 10.0)
                                               max-p (parse-double-param params param-max 50.0)
                                               limit (parse-long-param params param-limit 50)
                                               dfd (d/deferred)]
                                           (pg-query pg-pool {:min min-p :max max-p :limit limit}
                                                     (fn [rows]
                                                       (let [items (mapv #(transform-row % pg-tag-parser identity) rows)]
                                                         (d/success! dfd (json-response {:items items :count (clojure.core/count items)}))))
                                                     (fn [_] (d/success! dfd empty-db-response)))
                                           dfd)
                                         empty-db-response)))]
           "/static/:filename" [(GET (fn [req]
                                       (let [name (get-in req [:params :filename])
                                             path (str "/data" (:uri req))
                                             f (io/file path)]
                                         (if (.isFile f)
                                           {:status 200 :headers {hdr-ct (get-content-type name) hdr-server server-name} :body (java.io.FileInputStream. path)}
                                           {:status 404 :body not-found-body}))))]
           "/"                 [(GET (fn [_] (text-response server-name)))]})]

    (http/start-server handler {:port                8080
                                :raw-stream?         true
                                :executor            :none
                                :bootstrap-transform (fn [bootstrap]
                                                       (.option bootstrap ChannelOption/ALLOCATOR PooledByteBufAllocator/DEFAULT)
                                                       (.childOption bootstrap ChannelOption/ALLOCATOR PooledByteBufAllocator/DEFAULT))
                                :pipeline-transform  (fn [pipeline]
                                                       (.remove pipeline "continue-handler")
                                                       (.addBefore pipeline "request-handler" "compressor" (HttpContentCompressor.)))})
    (println "Server running on port 8080")
    @(promise)))
