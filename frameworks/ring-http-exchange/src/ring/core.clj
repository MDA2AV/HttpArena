(ns ring.core
  (:require [clojure.core.cache :as cache]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [jj.majavat :as majavat]
            [jj.majavat.renderer :as renderer]
            [jj.sql.async-boa :as boa]
            [jj.sql.boa.query.vertx-pg :as vertx-adapter]
            [jj.tassu :refer [GET POST PUT async-route]]
            [jsonista.core :as json]
            [ring-http-exchange.core :as server]
            [ring-http-exchange.ssl :as ssl])
  (:import (io.vertx.core Vertx)
           (io.vertx.pgclient PgBuilder PgConnectOptions)
           (io.vertx.sqlclient PoolOptions)
           (java.io ByteArrayOutputStream FileInputStream InputStream OutputStream)
           (java.net URI)
           (java.security KeyStore PEMDecoder PrivateKey)
           (java.security.cert Certificate CertificateFactory)
           (java.util.concurrent Executors)
           (java.util.zip GZIPOutputStream))
  (:gen-class))

(def default-executor (Executors/newVirtualThreadPerTaskExecutor))

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
(def ^:private ^:const dot ".")
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

(defn- safe-parse-long [^String s default]
  (try (Long/parseLong s) (catch Exception _ default)))

(defn- safe-parse-double [^String s default]
  (try (Double/parseDouble s) (catch Exception _ default)))

(defn- safe-parse-int [^String s default]
  (try (Integer/parseInt s) (catch Exception _ default)))

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
  (if (nil? qs)
    0
    (loop [i 0 total-sum 0]
      (if (>= i (.length qs))
        total-sum
        (let [amp (.indexOf qs (int \&) i)
              end (if (neg? amp) (.length qs) amp)
              eq (.indexOf qs (int \=) i)]
          (if (and (>= eq 0) (< eq end))
            (recur (inc end)
                   (+ total-sum
                      (safe-parse-long (subs qs (inc eq) end) 0)))
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

(defn- accepts-gzip? [headers]
  (boolean
    (some (fn [[k v]]
            (and (.equalsIgnoreCase ^String k ae-header)
                 (.contains ^String v enc-gzip)))
          headers)))

(defn- get-content-type [^String name]
  (let [dot-index (.lastIndexOf name ^String dot)
        ext (if (>= dot-index 0) (subs name dot-index) "")]
    (get extension-map ext ct-octet)))

(defn- transform-pg-row [row]
  {:id       (:id row)
   :name     (:name row)
   :category (:category row)
   :price    (:price row)
   :quantity (:quantity row)
   :active   (:active row)
   :tags     (json/read-value (str (:tags row)))
   :rating   {:score (:rating_score row) :count (:rating_count row)}})

(defn- pem->keystore [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        cert-array (into-array Certificate certs)
        private-key ^PrivateKey (.decode (PEMDecoder/of) ^String (slurp key-path) PrivateKey)
        password (char-array 0)]
    (doto (KeyStore/getInstance "PKCS12")
      (.load nil password)
      (.setKeyEntry "server" private-key password cert-array))))

(defn- load-ssl-context
  []
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
  ([handler port ssl-context]
   (let [opts (cond-> {:port              port
                       :lazy-request-map? true
                       :async?            true
                       :executor          default-executor}
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
            port (if (pos? (.getPort uri)) (.getPort uri) 5432)
            db (subs (.getPath uri) 1)
            [user pass] (str/split (.getUserInfo uri) #":" 2)
            max-conn (safe-parse-int (System/getenv "DATABASE_MAX_CONN") 256)
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
        (println (str "PG init failed: " (.getMessage t)))
        nil))))

(defn- handle-baseline-get [req respond _raise]
  (respond (text-response (sum-params (:query-string req)))))

(defn- handle-baseline-post [req respond _raise]
  (let [s (sum-params (:query-string req))
        b (slurp (:body req))
        n (safe-parse-long (str/trim b) 0)]
    (respond (text-response (+ s n)))))

(defn- handle-json [dataset req respond _raise]
  (let [requested (safe-parse-long (get-in req [:params :count]) 50)
        n (min requested (long (clojure.core/count dataset)))
        params (parse-qs (:query-string req))
        m (safe-parse-long (get params param-m) 1)
        items (map #(process-item % m) (subvec dataset 0 n))
        body-bytes (json/write-value-as-bytes
                     {:items items :count (clojure.core/count items)})]
    (respond
      (if (accepts-gzip? (:headers req))
        {:status 200 :headers json-gzip-headers :body (gzip-bytes body-bytes)}
        {:status 200 :headers json-headers :body (String. ^bytes body-bytes)}))))

(defn- handle-upload [req respond _raise]
  (with-open [^InputStream in (:body req)]
    (respond (text-response (.transferTo in (OutputStream/nullOutputStream))))))

(defn- handle-pg [pg-pool req respond _raise]
  (let [params (parse-qs (:query-string req))
        min-p (safe-parse-double (get params param-min) 10.0)
        max-p (safe-parse-double (get params param-max) 50.0)
        limit (safe-parse-long (get params param-limit) 50)]
    (pg-query pg-pool {:min min-p :max max-p :limit limit}
              (fn [rows]
                (let [items (map transform-pg-row rows)]
                  (respond (json-response {:items items :count (count items)}))))
              (fn [_]
                (respond (json-response {:items [] :count 0}))))))

(defn- handle-fortunes [pg-pool respond raise]
  (fortunes-query
    pg-pool
    (fn [rows]
      (let [fortunes (sort-by :message (conj rows {:id 0 :message "Additional fortune added at request time."}))
            body (fortunes-render {:fortunes fortunes})]
        (respond {:status 200 :headers html-headers :body body})))
    raise))

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

(defn- handle-crud-list [pg-pool req respond raise]
  (let [params (parse-qs (:query-string req))
        category (or (get params "category") "electronics")
        page (max 1 (safe-parse-long (get params "page") 1))
        limit (max 1 (min 50 (safe-parse-long (get params "limit") 10)))
        offset (* (dec page) limit)]
    (crud-list-query pg-pool {:category category :limit limit :offset offset}
                     (fn [rows]
                       (let [items (map transform-crud-row rows)]
                         (respond (json-response {:items items
                                                  :total (count items)
                                                  :page  page
                                                  :limit limit}))))
                     raise)))

(defn- handle-crud-read [pg-pool req respond raise]
  (let [id (safe-parse-long (get-in req [:params :id]) nil)]
    (if (nil? id)
      (respond {:status 404 :headers json-headers :body not-found-body})
      (if-let [cached (crud-cache-get id)]
        (respond {:status 200 :headers crud-hit-headers :body cached})
        (crud-read-query pg-pool {:id id}
                         (fn [rows]
                           (if-let [row (first rows)]
                             (let [json-str (json/write-value-as-string (transform-crud-row row))]
                               (crud-cache-set id json-str)
                               (respond {:status 200 :headers crud-miss-headers :body json-str}))
                             (respond {:status 404 :headers json-headers :body not-found-body})))
                         raise)))))

(defn- handle-crud-create [pg-pool req respond raise]
  (let [body (json/read-value (:body req) json/keyword-keys-object-mapper)
        id (:id body)
        nm (or (:name body) "New Product")
        category (or (:category body) "test")
        price (or (:price body) 0)
        quantity (or (:quantity body) 0)]
    (crud-create-query pg-pool {:id id :name nm :category category :price price :quantity quantity}
                       (fn [rows]
                         (respond {:status  201
                                   :headers json-headers
                                   :body    (json/write-value-as-string
                                              {:id       (:id (first rows))
                                               :name     nm
                                               :category category
                                               :price    price
                                               :quantity quantity})}))
                       raise)))

(defn- handle-crud-update [pg-pool req respond raise]
  (let [id (safe-parse-long (get-in req [:params :id]) nil)]
    (if (nil? id)
      (respond {:status 404 :headers json-headers :body not-found-body})
      (let [body (json/read-value (:body req) json/keyword-keys-object-mapper)
            nm (or (:name body) "Updated")
            price (or (:price body) 0)
            quantity (or (:quantity body) 0)]
        (crud-update-query pg-pool {:name nm :price price :quantity quantity :id id}
                           (fn [rows]
                             (if (seq rows)
                               (do
                                 (crud-cache-evict id)
                                 (respond {:status  200
                                           :headers json-headers
                                           :body    (json/write-value-as-string
                                                      {:id       id
                                                       :name     nm
                                                       :price    price
                                                       :quantity quantity})}))
                               (respond {:status 404 :headers json-headers :body not-found-body})))
                           raise)))))

(defn- handle-static [req respond _raise]
  (let [name (get-in req [:params :filename])
        f (io/file static-dir name)]
    (if (.exists f)
      (respond {:status  200
                :headers {hdr-ct (get-content-type name) hdr-server server-name}
                :body    f})
      (respond {:status 404 :body not-found-body}))))

(defn- build-handler [{:keys [dataset pg-pool]}]
  (async-route
    {"/baseline11"       [(GET handle-baseline-get)
                          (POST handle-baseline-post)]
     "/json/:count"      [(GET (fn [req res rej] (handle-json dataset req res rej)))]
     "/upload"           [(POST handle-upload)]
     "/async-db"         [(GET (fn [req res rej] (handle-pg pg-pool req res rej)))]
     "/fortunes"         [(GET (fn [_ res rej] (handle-fortunes pg-pool res rej)))]
     "/crud/items"       [(GET (fn [req res rej] (handle-crud-list pg-pool req res rej)))
                          (POST (fn [req res rej] (handle-crud-create pg-pool req res rej)))]
     "/crud/items/:id"   [(GET (fn [req res rej] (handle-crud-read pg-pool req res rej)))
                          (PUT (fn [req res rej] (handle-crud-update pg-pool req res rej)))]
     "/static/:filename" [(GET handle-static)]
     "/"                 [(GET (fn [_ res _] (res (text-response server-name))))]}))

(defn -main [& _]
  (let [dataset (load-json (or (System/getenv "DATASET_PATH") dataset-path))
        handler (build-handler {:dataset dataset
                                :pg-pool (init-pg-pool)})]
    (start-server! handler plain-port)
    (start-server! handler tls-port (load-ssl-context))))