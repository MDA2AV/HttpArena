(ns ring.core
  (:require [clojure.core.cache :as cache]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [jj.majavat :as majavat]
            [jj.sql.async-boa :as boa]
            [jj.sql.boa.query.vertx-pg :as vertx-adapter]
            [jj.tassu :refer [GET POST PUT route]]
            [jsonista.core :as json]
            [ring-http-exchange.core :as server]
            [ring-http-exchange.ssl :as ssl])
  (:import (clojure.lang IPersistentCollection IPersistentVector)
           (io.vertx.core Vertx)
           (io.vertx.pgclient PgBuilder PgConnectOptions)
           (io.vertx.sqlclient ClientBuilder PoolOptions SqlConnectOptions)
           (java.io ByteArrayOutputStream File FileInputStream InputStream)
           (java.net URI)
           (java.security KeyFactory KeyStore PrivateKey)
           (java.security.cert Certificate CertificateFactory)
           (java.security.spec PKCS8EncodedKeySpec)
           (java.util Base64)
           (java.util.concurrent CompletableFuture Executors)
           (java.util.zip GZIPOutputStream))
  (:gen-class))

(set! *warn-on-reflection* true)

(def default-executor (Executors/newCachedThreadPool))

(defn- completed ^CompletableFuture [x]
  (CompletableFuture/completedFuture x))

(defn- query-future
  ^CompletableFuture [start]
  (let [cf (CompletableFuture.)]
    (try
      (start (fn [rows] (.complete cf rows))
             (fn [err]
               (.completeExceptionally
                 cf
                 (if (instance? Throwable err)
                   err
                   (ex-info "query failed" {:error err})))))
      (catch Throwable t
        (.completeExceptionally cf t)))
    cf))

(defn- then-async
  ^CompletableFuture [^CompletableFuture cf f]
  (.thenApplyAsync cf f))

(defn- on-error
  "Recovers a failed future by applying f to the failure."
  ^CompletableFuture [^CompletableFuture cf f]
  (.exceptionally cf f))

(defn- sync->future
  "Adapts a plain (request -> response) handler to return a completed future."
  [handler]
  (fn [req]
    (completed (handler req))))

(defn- wrap-future
  "Guarantees the server always receives a future, including for responses the
  router produces itself (e.g. not found)."
  [handler]
  (fn [req]
    (let [res (handler req)]
      (if (instance? CompletableFuture res)
        res
        (completed res)))))

(def ^:private ^:const ct-json "application/json")
(def ^:private ^:const ct-text "text/plain")
(def ^:private ^:const ct-html "text/html; charset=utf-8")
(def ^:private ^:const ct-octet "application/octet-stream")
(def ^:private ^:const hdr-ct "Content-Type")
(def ^:private ^:const hdr-ce "Content-Encoding")
(def ^:private ^:const hdr-server "Server")
(def ^:private ^:const server-name "ring-http-exchange")
(def ^:private ^:const enc-gzip "gzip")
(def ^:private ^:const ae-header "accept-encoding")
(def ^:private ^:const not-found-body "Not found")
(def ^:private ^:const dataset-path "/data/dataset.json")
(def ^:private ^:const static-dir "/data/static")
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
(def ^:private json-gzip-headers {hdr-ct ct-json hdr-ce enc-gzip hdr-server server-name})
(def ^:private text-headers {hdr-ct ct-text hdr-server server-name})
(def ^:private html-headers {hdr-ct ct-html hdr-server server-name})

(def ^:private adapter (vertx-adapter/->VertxPgAdapter))
(def ^:private pg-query (boa/build-async-query adapter "sql/pg-query"))
(def ^:private crud-list-query (boa/build-async-query adapter "sql/crud-list"))
(def ^:private crud-read-query (boa/build-async-query adapter "sql/crud-read"))
(def ^:private crud-create-query (boa/build-async-query adapter "sql/crud-create"))
(def ^:private crud-update-query (boa/build-async-query adapter "sql/crud-update"))
(def ^:private fortunes-query (boa/build-async-query adapter "sql/fortunes"))
(def ^:private fortunes-render (majavat/build-html-renderer "fortunes.html"))

(def ^:private ^:const extension-map
  {".css"   "text/css"
   ".js"    "application/javascript"
   ".html"  "text/html"
   ".woff2" "font/woff2"
   ".svg"   "image/svg+xml"
   ".webp"  "image/webp"
   ".json"  ct-json})

(def ^:private root-response
  {:status 200 :headers text-headers :body server-name})

(def ^:private zero-text-response
  {:status 200 :headers text-headers :body "0"})

(def ^:private text-response-base {:status 200 :headers text-headers})

(defn- parse-long-or-zero ^long [^String s]
  (if (nil? s) 0 (try (Long/parseLong s) (catch Exception _ 0))))

(defn- parse-long-or-neg1 ^long [^String s]
  (if (nil? s) -1 (try (Long/parseLong s) (catch Exception _ -1))))

(defn- parse-long-or-1 ^long [^String s]
  (if (nil? s) 1 (try (Long/parseLong s) (catch Exception _ 1))))

(defn- parse-long-or-10 ^long [^String s]
  (if (nil? s) 10 (try (Long/parseLong s) (catch Exception _ 10))))

(defn- parse-long-or-50 ^long [^String s]
  (if (nil? s) 50 (try (Long/parseLong s) (catch Exception _ 50))))

(defn- parse-long-or-256 ^long [^String s]
  (if (nil? s) 256 (try (Long/parseLong s) (catch Exception _ 256))))

(defn- parse-double-or-10 ^double [^String s]
  (if (nil? s) 10.0 (try (Double/parseDouble s) (catch Exception _ 10.0))))

(defn- parse-double-or-50 ^double [^String s]
  (if (nil? s) 50.0 (try (Double/parseDouble s) (catch Exception _ 50.0))))

(defn- load-json [^String path]
  (let [f (io/file path)]
    (when (.exists f)
      (json/read-value (slurp f) json/keyword-keys-object-mapper))))

(defn- process-item [item ^long m]
  (assoc item :total (* (long (:price item)) (long (:quantity item)) m)))

(defn- parse-qs [^String qs]
  (when qs
    (let [len (.length qs)]
      (loop [i (long 0) m (transient {})]
        (if (>= i len)
          (persistent! m)
          (let [amp (.indexOf qs (int \&) (int i))
                end (long (if (neg? amp) len amp))
                eq (.indexOf qs (int \=) (int i))]
            (if (and (>= eq 0) (< (long eq) end))
              (recur (unchecked-inc end) (assoc! m (subs qs (int i) (int eq)) (subs qs (int (unchecked-inc (long eq))) (int end))))
              (recur (unchecked-inc end) m))))))))

(defn- parse-long-range ^long [^String s ^long from ^long to]
  (if (>= from to)
    0
    (let [first-ch (.charAt s (int from))
          negative (== (int first-ch) (int \-))
          start (long (if negative (unchecked-inc from) from))]
      (if (>= start to)
        0
        (loop [i start acc (long 0)]
          (if (>= i to)
            (if negative (unchecked-negate acc) acc)
            (let [c (int (.charAt s (int i)))
                  d (unchecked-subtract c (int \0))]
              (if (or (< d 0) (> d 9))
                0
                (recur (unchecked-inc i)
                       (unchecked-add (unchecked-multiply acc 10) (long d)))))))))))

(defn- sum-params ^long [^String qs]
  (if (nil? qs)
    0
    (let [len (long (.length qs))]
      (loop [i (long 0) total-sum (long 0)]
        (if (>= i len)
          total-sum
          (let [amp (.indexOf qs (int \&) (int i))
                end (long (if (neg? amp) len amp))
                eq (.indexOf qs (int \=) (int i))]
            (if (and (>= eq 0) (< (long eq) end))
              (recur (unchecked-inc end)
                     (unchecked-add total-sum
                                    (parse-long-range qs (unchecked-inc (long eq)) end)))
              (recur (unchecked-inc end) total-sum))))))))

(defn- gzip-bytes ^bytes [^bytes data]
  (let [baos (ByteArrayOutputStream. (alength data))
        gos (GZIPOutputStream. baos)]
    (.write gos data)
    (.close gos)
    (.toByteArray baos)))

(defn- json-response [data]
  {:status 200 :headers json-headers :body (json/write-value-as-string data)})

(defn- text-response-long [^long n]
  (assoc text-response-base :body (Long/toString n)))

(defn- accepts-gzip? [headers]
  (boolean
    (some (fn [[k v]]
            (and (.equalsIgnoreCase ^String k ^String ae-header)
                 (.contains ^String v ^String enc-gzip)))
          headers)))

(defn- get-content-type ^String [^String name]
  (let [dot-index (.lastIndexOf name ".")]
    (if (>= dot-index 0)
      (let [ext (subs name dot-index)]
        (or (get extension-map ext) ct-octet))
      ct-octet)))

(defn- transform-pg-row [row]
  {:id       (:id row)
   :name     (:name row)
   :category (:category row)
   :price    (:price row)
   :quantity (:quantity row)
   :active   (:active row)
   :tags     (json/read-value (str (:tags row)))
   :rating   {:score (:rating_score row) :count (:rating_count row)}})

(defn- pem->der ^bytes [^String pem]
  (let [body (-> pem
                 (str/replace #"-----BEGIN [^-]+-----" "")
                 (str/replace #"-----END [^-]+-----" "")
                 (str/replace #"\s" ""))]
    (.decode (Base64/getDecoder) body)))

(defn- der->private-key ^PrivateKey [^bytes der]
  (let [spec (PKCS8EncodedKeySpec. der)]
    (loop [algos ["RSA" "EC" "DSA" "EdDSA"]]
      (if-let [algo (first algos)]
        (or (try
              (.generatePrivate (KeyFactory/getInstance ^String algo) spec)
              (catch Exception _ nil))
            (recur (rest algos)))
        (throw (ex-info "Unsupported private key algorithm" {}))))))

(defn- pem->keystore [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        cert-array (into-array Certificate certs)
        private-key (der->private-key (pem->der (slurp key-path)))
        password (char-array 0)]
    (doto (KeyStore/getInstance "PKCS12")
      (.load nil password)
      (.setKeyEntry "server" private-key password cert-array))))

(defn- load-ssl-context []
  (let [cert-path (or (System/getenv "TLS_CERT") tls-cert-default)
        key-path (or (System/getenv "TLS_KEY") tls-key-default)]
    (if (and (.exists (io/file cert-path)) (.exists (io/file key-path)))
      (try
        (ssl/keystore->ssl-context (pem->keystore cert-path key-path) "")
        (catch Exception e
          (println (str "Failed to load TLS context: " (.getMessage e)))
          nil))
      (do
        (println (str "TLS certs not found at " cert-path " / " key-path
                      " - skipping TLS server"))
        nil))))

(defn- start-server!
  ([handler port]
   (start-server! handler port nil))
  ([handler ^long port ssl-context]
   (let [opts (cond-> {:port         port
                       :executor     default-executor
                       :handler-mode :future}
                      ssl-context (assoc :ssl-context ssl-context))]
     (try
       (server/run-http-server handler opts)
       (println (str "Server running on port " port (when ssl-context " (TLS)")))
       (catch Exception e
         (println (str "Failed to start server on port " port
                       ": " (.getMessage e))))))))

(defn- init-pg-pool []
  (when-let [url (System/getenv "DATABASE_URL")]
    (try
      (let [uri (URI. (str/replace url pg-prefix pg-replace))
            host (.getHost uri)
            port (let [p (.getPort uri)] (if (pos? p) p 5432))
            db (subs (.getPath uri) 1)
            [user pass] (str/split (.getUserInfo uri) #":" 2)
            max-conn (parse-long-or-256 (System/getenv "DATABASE_MAX_CONN"))
            connect-opts (doto (PgConnectOptions.)
                           (.setHost ^String host)
                           (.setPort (int port))
                           (.setDatabase ^String db)
                           (.setUser ^String user)
                           (.setPassword (str (or pass "")))
                           ;; avoid a parse/prepare round trip per query
                           (.setCachePreparedStatements true)
                           ;; let many in-flight queries share a connection
                           (.setPipeliningLimit (int 256)))
            pool-opts (-> (PoolOptions.) (.setMaxSize (int max-conn)))
            vertx (Vertx/vertx)
            ^ClientBuilder builder (PgBuilder/pool)]
        (-> builder
            (.with pool-opts)
            (.connectingTo ^SqlConnectOptions connect-opts)
            (.using vertx)
            (.build)))
      (catch Throwable t
        (println (str "PG init failed: " (.getMessage t)))
        nil))))

;; ---------------------------------------------------------------------------
;; Handlers: (request) -> CompletableFuture<ring response map>
;; ---------------------------------------------------------------------------

(defn- handle-baseline-get [req]
  (let [qs (:query-string req)]
    (if (nil? qs)
      zero-text-response
      (text-response-long (sum-params qs)))))

(defn- handle-baseline-post [req]
  (let [s (sum-params (:query-string req))
        b (slurp (:body req))
        n (parse-long-or-zero (str/trim b))]
    (text-response-long (unchecked-add s n))))

(defn- handle-json [^IPersistentVector dataset req]
  (let [requested (parse-long-or-50 (get-in req [:params :count]))
        ds-count (long (.count dataset))
        n (long (min requested ds-count))
        params (parse-qs (:query-string req))
        m (parse-long-or-1 (get params param-m))
        items (mapv #(process-item % m) (subvec dataset 0 (int n)))
        body-bytes (json/write-value-as-bytes
                     {:items items :count (long (.count ^IPersistentCollection items))})]
    (if (accepts-gzip? (:headers req))
      {:status 200 :headers json-gzip-headers :body (gzip-bytes body-bytes)}
      {:status 200 :headers json-headers :body (String. ^bytes body-bytes)})))

(defn- handle-echo [req]
  ;; The bytes that arrived go back unchanged.
  (with-open [^InputStream in (:body req)]
    {:status  200
     :headers {"content-type" "application/octet-stream"}
     :body    (.readAllBytes in)}))

(defn- handle-pg [pg-pool req]
  (let [params (parse-qs (:query-string req))
        min-p (parse-double-or-10 (get params param-min))
        max-p (parse-double-or-50 (get params param-max))
        limit (parse-long-or-50 (get params param-limit))]
    (-> (query-future #(pg-query pg-pool {:min min-p :max max-p :limit limit} %1 %2))
        (then-async (fn [rows]
                      (let [items (mapv transform-pg-row rows)]
                        (json-response {:items items :count (count items)}))))
        (on-error (fn [_]
                    (json-response {:items [] :count 0}))))))

(defn- handle-fortunes [pg-pool _req]
  (then-async
    (query-future #(fortunes-query pg-pool %1 %2))
    (fn [rows]
      (let [fortunes (sort-by :message (conj rows {:id 0 :message "Additional fortune added at request time."}))
            body (fortunes-render {:fortunes fortunes})]
        {:status 200 :headers html-headers :body body}))))

(def ^:private crud-hit-headers {hdr-ct ct-json hdr-server server-name "X-Cache" "HIT"})
(def ^:private crud-miss-headers {hdr-ct ct-json hdr-server server-name "X-Cache" "MISS"})

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

(defn- transform-crud-row [row]
  {:id       (:id row)
   :name     (:name row)
   :category (:category row)
   :price    (long (:price row))
   :quantity (long (:quantity row))
   :active   (:active row)
   :tags     (json/read-value (str (:tags row)))
   :rating   {:score (long (:rating_score row)) :count (long (:rating_count row))}})

(defn- handle-crud-list [pg-pool req]
  (let [params (parse-qs (:query-string req))
        category (or (get params "category") "electronics")
        page (max 1 (parse-long-or-1 (get params "page")))
        limit (max 1 (min 50 (parse-long-or-10 (get params "limit"))))
        offset (unchecked-multiply (unchecked-dec page) limit)]
    (then-async
      (query-future #(crud-list-query pg-pool {:category category :limit limit :offset offset} %1 %2))
      (fn [rows]
        (let [items (mapv transform-crud-row rows)]
          (json-response {:items items
                          :total (count items)
                          :page  page
                          :limit limit}))))))

(defn- handle-crud-read [pg-pool req]
  (let [id (parse-long-or-neg1 (get-in req [:params :id]))]
    (if (neg? id)
      (completed {:status 404 :headers json-headers :body not-found-body})
      (if-let [cached (crud-cache-get id)]
        (completed {:status 200 :headers crud-hit-headers :body cached})
        (then-async
          (query-future #(crud-read-query pg-pool {:id id} %1 %2))
          (fn [rows]
            (if-let [row (first rows)]
              (let [json-str (json/write-value-as-string (transform-crud-row row))]
                (crud-cache-set id json-str)
                {:status 200 :headers crud-miss-headers :body json-str})
              {:status 404 :headers json-headers :body not-found-body})))))))

(defn- handle-crud-create [pg-pool req]
  (let [body (json/read-value (:body req) json/keyword-keys-object-mapper)
        id (:id body)
        nm (or (:name body) "New Product")
        category (or (:category body) "test")
        price (or (:price body) 0)
        quantity (or (:quantity body) 0)]
    (then-async
      (query-future #(crud-create-query pg-pool {:id id :name nm :category category :price price :quantity quantity} %1 %2))
      (fn [rows]
        {:status  201
         :headers json-headers
         :body    (json/write-value-as-string
                    {:id       (:id (first rows))
                     :name     nm
                     :category category
                     :price    price
                     :quantity quantity})}))))

(defn- handle-crud-update [pg-pool req]
  (let [id (parse-long-or-neg1 (get-in req [:params :id]))]
    (if (neg? id)
      (completed {:status 404 :headers json-headers :body not-found-body})
      (let [body (json/read-value (:body req) json/keyword-keys-object-mapper)
            nm (or (:name body) "Updated")
            price (or (:price body) 0)
            quantity (or (:quantity body) 0)]
        (then-async
          (query-future #(crud-update-query pg-pool {:name nm :price price :quantity quantity :id id} %1 %2))
          (fn [rows]
            (if (seq rows)
              (do
                (crud-cache-evict id)
                {:status  200
                 :headers json-headers
                 :body    (json/write-value-as-string
                            {:id       id
                             :name     nm
                             :price    price
                             :quantity quantity})})
              {:status 404 :headers json-headers :body not-found-body})))))))

(defn- handle-delay [req]
  (let [ms (parse-long-or-zero (get-in req [:params :ms]))]
    (when (pos? ms)
      (Thread/sleep ms))
    (text-response-long ms)))

(defn- handle-static [req]
  (let [name (get-in req [:params :filename])
        ^File f (io/file static-dir name)]
    (if (.exists f)
      {:status  200
       :headers {hdr-ct (get-content-type ^String name) hdr-server server-name}
       :body    f}
      {:status 404 :body not-found-body})))

(defn- build-handler [{:keys [dataset pg-pool]}]
  (let [dataset (vec dataset)]
    (wrap-future
      (route
        {"/baseline11"       [(GET (sync->future handle-baseline-get))
                              (POST (sync->future handle-baseline-post))]
         "/json/:count"      [(GET (sync->future (fn [req] (handle-json dataset req))))]
         "/echo"             [(POST (sync->future handle-echo))]
         "/async-db"         [(GET (fn [req] (handle-pg pg-pool req)))]
         "/fortunes"         [(GET (fn [req] (handle-fortunes pg-pool req)))]
         "/crud/items"       [(GET (fn [req] (handle-crud-list pg-pool req)))
                              (POST (fn [req] (handle-crud-create pg-pool req)))]
         "/crud/items/:id"   [(GET (fn [req] (handle-crud-read pg-pool req)))
                              (PUT (fn [req] (handle-crud-update pg-pool req)))]
         "/delay/:ms"        [(GET (sync->future handle-delay))]
         "/static/:filename" [(GET (sync->future handle-static))]
         "/"                 [(GET (fn [_] (completed root-response)))]}))))

(defn -main [& _]
  (let [dataset (load-json (or (System/getenv "DATASET_PATH") dataset-path))
        handler (build-handler {:dataset dataset
                                :pg-pool (init-pg-pool)})]
    (start-server! handler plain-port)
    (start-server! handler tls-port (load-ssl-context))))