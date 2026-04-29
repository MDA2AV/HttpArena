(ns aleph-bench.core
  (:require [aleph.http :as http]
            [aleph.netty :as netty]
            [clojure.core.cache :as cache]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [jj.sql.async-boa :as async-boa]
            [jj.sql.boa.query.vertx-pg :as vertx-adapter]
            [jj.tassu :refer [GET POST PUT route]]
            [jsonista.core :as json]
            [manifold.deferred :as d]
            [manifold.stream :as s])
  (:import (io.netty.buffer ByteBuf PooledByteBufAllocator)
           (io.netty.channel ChannelOption)
           (io.netty.handler.codec.http HttpContentCompressor)
           (io.netty.handler.ssl SslContextBuilder)
           (io.vertx.core Vertx)
           (io.vertx.pgclient PgBuilder PgConnectOptions)
           (io.vertx.sqlclient PoolOptions)
           (java.io ByteArrayOutputStream FileInputStream)
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
(def ^:private ^:const param-min "min")
(def ^:private ^:const param-max "max")
(def ^:private ^:const param-limit "limit")
(def ^:private ^:const param-m "m")
(def ^:private ^:const pg-prefix "postgres://")
(def ^:private ^:const pg-replace "postgresql://")
(def ^:private ^:const plain-port 8080)
(def ^:private ^:const tls-port 8081)
(def ^:private ^:const tls-cert-default "/certs/server.crt")
(def ^:private ^:const tls-key-default "/certs/server.key")

(def ^:private json-headers {hdr-ct ct-json hdr-server server-name})
(def ^:private text-headers {hdr-ct ct-text hdr-server server-name})
(def ^:private crud-hit-headers {hdr-ct ct-json hdr-server server-name "X-Cache" "HIT"})
(def ^:private crud-miss-headers {hdr-ct ct-json hdr-server server-name "X-Cache" "MISS"})
(def ^:private empty-db-response {:status 200 :headers json-headers :body empty-db-body})

(def ^:private ^:const extension-map
  {".css"   "text/css" ".js" "application/javascript" ".html" "text/html"
   ".woff2" "font/woff2" ".svg" "image/svg+xml" ".webp" "image/webp" ".json" ct-json})

(defn- load-json [path]
  (when (.exists (io/file path))
    (json/read-value (slurp path) json/keyword-keys-object-mapper)))

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
                        (recur (inc end) (+ sum (long (try (Long/parseLong (subs qs (inc eq) end)) (catch Exception _ 0)))))
                        (recur (inc end) sum)))))))

(defn- parse-long-param [params k default]
  (try (Long/parseLong (get params k)) (catch Exception _ default)))

(defn- parse-double-param [params k default]
  (try (Double/parseDouble (get params k)) (catch Exception _ default)))

(defn- process-item [item ^long m]
  (assoc item :total (* (:price item) (:quantity item) m)))

(defn- get-content-type [^String name]
  (let [dot-index (.lastIndexOf name ^String dot)
        ext (if (>= dot-index 0) (subs name dot-index) "")]
    (get extension-map ext ct-octet)))

(defn- json-response [data]
  {:status 200 :headers json-headers :body (json/write-value-as-string data)})

(defn- text-response [s]
  {:status 200 :headers text-headers :body (str s)})

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

(defn- transform-pg-row [row]
  {:id     (:id row) :name (:name row) :category (:category row)
   :price  (:price row) :quantity (:quantity row) :active (:active row)
   :tags   (json/read-value (str (:tags row)))
   :rating {:score (:rating_score row) :count (:rating_count row)}})

(defn- transform-crud-row [row]
  {:id     (:id row) :name (:name row) :category (:category row)
   :price  (long (:price row)) :quantity (long (:quantity row)) :active (:active row)
   :tags   (json/read-value (str (:tags row)))
   :rating {:score (long (:rating_score row)) :count (long (:rating_count row))}})

(def crud-cache (atom (cache/ttl-cache-factory {} :ttl 200)))

(defn- crud-cache-get [id]
  (let [c @crud-cache]
    (when (cache/has? c id)
      (swap! crud-cache cache/hit id)
      (cache/lookup @crud-cache id))))

(defn- crud-cache-set [id v]
  (swap! crud-cache #(cache/miss % id v)))

(defn- crud-cache-evict [id]
  (swap! crud-cache cache/evict id))

(def ^:private adapter (vertx-adapter/->VertxPgAdapter))
(def ^:private pg-query-fn (async-boa/build-async-query adapter "sql/pg-query"))
(def ^:private crud-list-q (async-boa/build-async-query adapter "sql/crud-list"))
(def ^:private crud-read-q (async-boa/build-async-query adapter "sql/crud-read"))
(def ^:private crud-create-q (async-boa/build-async-query adapter "sql/crud-create"))
(def ^:private crud-update-q (async-boa/build-async-query adapter "sql/crud-update"))

(defn- build-ssl-context []
  (let [cert-path (or (System/getenv "TLS_CERT") tls-cert-default)
        key-path (or (System/getenv "TLS_KEY") tls-key-default)
        cert-file (io/file cert-path)
        key-file (io/file key-path)]
    (when (and (.exists cert-file) (.exists key-file))
      (try
        (-> (SslContextBuilder/forServer cert-file key-file)
            (.build))
        (catch Exception e
          (println "TLS init failed:" (.getMessage e))
          nil)))))

(defn- init-pg-pool []
  (when-let [url (System/getenv "DATABASE_URL")]
    (try
      (let [uri (URI. (str/replace url pg-prefix pg-replace))
            host (.getHost uri)
            port (if (pos? (.getPort uri)) (.getPort uri) 5432)
            db (subs (.getPath uri) 1)
            [user pass] (str/split (.getUserInfo uri) #":" 2)
            max-conn (try (Integer/parseInt (System/getenv "DATABASE_MAX_CONN"))
                          (catch Exception _ 256))
            connect-opts (-> (PgConnectOptions.)
                             (.setHost host) (.setPort port) (.setDatabase db)
                             (.setUser user) (.setPassword (or pass "")))
            pool-opts (-> (PoolOptions.) (.setMaxSize max-conn))
            vertx (Vertx/vertx)]
        (-> (PgBuilder/pool)
            (.with pool-opts)
            (.connectingTo connect-opts)
            (.using vertx)
            (.build)))
      (catch Throwable t
        (println "PG init failed:" (.getMessage t))
        nil))))

(defn- handle-baseline-get [req]
  (text-response (sum-params (:query-string req))))

(defn- handle-baseline-post [req]
  (let [s (sum-params (:query-string req))]
    (d/chain (read-body-bytes (:body req))
             (fn [^bytes bs]
               (let [n (try (Long/parseLong (str/trim (String. bs))) (catch Exception _ 0))]
                 (text-response (+ s n)))))))

(defn- handle-json [dataset req]
  (let [count (try (Long/parseLong (get-in req [:params :count])) (catch Exception _ 50))
        count (min count (long (clojure.core/count dataset)))
        params (parse-qs (:query-string req))
        m (parse-long-param params param-m 1)
        items (mapv #(process-item % m) (subvec dataset 0 count))]
    {:status 200 :headers json-headers
     :body   (json/write-value-as-string {:items items :count (clojure.core/count items)})}))

(defn- handle-upload [req]
  (d/chain (read-body-bytes (:body req))
           (fn [^bytes bs] (text-response (alength bs)))))

(defn- handle-async-db [pg-pool req]
  (let [params (parse-qs (:query-string req))
        min-p (parse-double-param params param-min 10.0)
        max-p (parse-double-param params param-max 50.0)
        limit (parse-long-param params param-limit 50)
        dfd (d/deferred)]
    (pg-query-fn pg-pool {:min min-p :max max-p :limit limit}
                 (fn [rows]
                   (let [items (mapv transform-pg-row rows)]
                     (d/success! dfd (json-response {:items items :count (clojure.core/count items)}))))
                 (fn [_] (d/success! dfd empty-db-response)))
    dfd))

(defn- handle-crud-list [pg-pool req]
  (let [params (parse-qs (:query-string req))
        category (or (get params "category") "electronics")
        page (max 1 (parse-long-param params "page" 1))
        limit (max 1 (min 50 (parse-long-param params "limit" 10)))
        offset (* (dec page) limit)
        dfd (d/deferred)]
    (crud-list-q pg-pool {:category category :limit limit :offset offset}
                 (fn [rows]
                   (let [items (mapv transform-crud-row rows)]
                     (d/success! dfd (json-response {:items items :total (clojure.core/count items) :page page :limit limit}))))
                 (fn [_] (d/success! dfd (json-response {:items [] :total 0 :page page :limit limit}))))
    dfd))

(defn- handle-crud-read [pg-pool req]
  (let [id (try (Long/parseLong (get-in req [:params :id])) (catch Exception _ nil))]
    (if (nil? id)
      {:status 404 :headers json-headers :body not-found-body}
      (if-let [cached (crud-cache-get id)]
        {:status 200 :headers crud-hit-headers :body cached}
        (let [dfd (d/deferred)]
          (crud-read-q pg-pool {:id id}
                       (fn [rows]
                         (if-let [row (first rows)]
                           (let [json-str (json/write-value-as-string (transform-crud-row row))]
                             (crud-cache-set id json-str)
                             (d/success! dfd {:status 200 :headers crud-miss-headers :body json-str}))
                           (d/success! dfd {:status 404 :headers json-headers :body not-found-body})))
                       (fn [_] (d/success! dfd {:status 404 :headers json-headers :body not-found-body})))
          dfd)))))

(defn- handle-crud-create [pg-pool req]
  (d/chain (read-body-bytes (:body req))
           (fn [^bytes bs]
             (let [body (json/read-value (String. bs) json/keyword-keys-object-mapper)
                   id (:id body)
                   nm (or (:name body) "New Product")
                   category (or (:category body) "test")
                   price (or (:price body) 0)
                   quantity (or (:quantity body) 0)
                   dfd (d/deferred)]
               (crud-create-q pg-pool {:id id :name nm :category category :price price :quantity quantity}
                              (fn [rows]
                                (d/success! dfd {:status 201 :headers json-headers
                                                 :body   (json/write-value-as-string
                                                           {:id (:id (first rows)) :name nm :category category :price price :quantity quantity})}))
                              (fn [_] (d/success! dfd {:status 500 :headers json-headers :body "{\"error\":\"insert failed\"}"})))
               dfd))))

(defn- handle-crud-update [pg-pool req]
  (let [id (try (Long/parseLong (get-in req [:params :id])) (catch Exception _ nil))]
    (if (nil? id)
      {:status 404 :headers json-headers :body not-found-body}
      (d/chain (read-body-bytes (:body req))
               (fn [^bytes bs]
                 (let [body (json/read-value (String. bs) json/keyword-keys-object-mapper)
                       nm (or (:name body) "Updated")
                       price (or (:price body) 0)
                       quantity (or (:quantity body) 0)
                       dfd (d/deferred)]
                   (crud-update-q pg-pool {:name nm :price price :quantity quantity :id id}
                                  (fn [rows]
                                    (if (seq rows)
                                      (do (crud-cache-evict id)
                                          (d/success! dfd {:status 200 :headers json-headers
                                                           :body   (json/write-value-as-string {:id id :name nm :price price :quantity quantity})}))
                                      (d/success! dfd {:status 404 :headers json-headers :body not-found-body})))
                                  (fn [_] (d/success! dfd {:status 404 :headers json-headers :body not-found-body})))
                   dfd))))))

(defn- handle-static [req]
  (let [name (get-in req [:params :filename])
        path (str "/data" (:uri req))
        f (io/file path)]
    (if (.isFile f)
      {:status 200 :headers {hdr-ct (get-content-type name) hdr-server server-name} :body (FileInputStream. path)}
      {:status 404 :body not-found-body})))

(defn- build-handler [{:keys [dataset json-body compression-body pg-pool]}]
  (route
    {"/baseline11"       [(GET handle-baseline-get)
                          (POST handle-baseline-post)]
     "/json/:count"      [(GET (fn [req] (handle-json dataset req)))]
     "/json"             [(GET (fn [_] {:status 200 :headers json-headers :body json-body}))]
     "/compression"      [(GET (fn [_] {:status 200 :headers json-headers :body compression-body}))]
     "/upload"           [(POST handle-upload)]
     "/async-db"         [(GET (fn [req] (handle-async-db pg-pool req)))]
     "/crud/items"       [(GET (fn [req] (handle-crud-list pg-pool req)))
                          (POST (fn [req] (handle-crud-create pg-pool req)))]
     "/crud/items/:id"   [(GET (fn [req] (handle-crud-read pg-pool req)))
                          (PUT (fn [req] (handle-crud-update pg-pool req)))]
     "/static/:filename" [(GET handle-static)]
     "/"                 [(GET (fn [_] (text-response server-name)))]}))

(defn- start-server! [handler port opts]
  (try
    (http/start-server handler (merge {:port                port
                                       :raw-stream?         true
                                       :executor            :none
                                       :bootstrap-transform (fn [bootstrap]
                                                              (.option bootstrap ChannelOption/ALLOCATOR PooledByteBufAllocator/DEFAULT)
                                                              (.childOption bootstrap ChannelOption/ALLOCATOR PooledByteBufAllocator/DEFAULT))}
                                      opts))
    (println (str "Server running on port " port))
    (catch Exception e
      (println (str "Failed to start on port " port ": " (.getMessage e))))))

(defn -main [& _]
  (netty/leak-detector-level! :disabled)
  (let [dataset (load-json (or (System/getenv "DATASET_PATH") dataset-path))
        json-body (let [items (mapv #(process-item % 1) dataset)]
                    (json/write-value-as-string {:items items :count (clojure.core/count items)}))
        large-dataset (load-json dataset-large-path)
        compression-body (when large-dataset
                           (let [items (mapv #(process-item % 1) large-dataset)]
                             (json/write-value-as-string {:items items :count (clojure.core/count items)})))
        pg-pool (init-pg-pool)
        handler (build-handler {:dataset          dataset
                                :json-body        json-body
                                :compression-body compression-body
                                :pg-pool          pg-pool})]
    (start-server! handler plain-port
                   {:pipeline-transform (fn [pipeline]
                                          (.remove pipeline "continue-handler")
                                          (.addBefore pipeline "request-handler" "compressor" (HttpContentCompressor.)))})
    (when-let [ssl-ctx (build-ssl-context)]
      (start-server! handler tls-port
                     {:ssl-context        ssl-ctx
                      :http-versions      [:http1]
                      :pipeline-transform (fn [pipeline]
                                            (.remove pipeline "continue-handler"))}))
    @(promise)))
