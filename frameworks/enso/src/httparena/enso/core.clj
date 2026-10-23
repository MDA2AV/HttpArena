(ns httparena.enso.core
  (:gen-class)
  (:require
   [s-exp.oda :as oda]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [ring.util.mime-type :as mime]
   [ring.websocket :as ws]
   [s-exp.enso :as enso])
  (:import
   [java.io ByteArrayOutputStream File FileInputStream InputStream]
   [java.nio.charset StandardCharsets]
   [java.security KeyFactory KeyStore]
   [java.security.cert Certificate CertificateFactory]
   [java.security.spec PKCS8EncodedKeySpec]
   [java.util Base64]
   [java.util.concurrent CompletableFuture Executors ScheduledExecutorService ThreadLocalRandom TimeUnit]
   [java.util.zip GZIPOutputStream]
   [javax.net.ssl KeyManagerFactory SSLContext]))

(set! *warn-on-reflection* true)

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([^String value default]
   (or (when value
         (let [trimmed (.trim value)]
           (when-not (.isEmpty trimmed)
             (parse-long trimmed))))
       default)))

(defn query-param
  "Raw value of parameter `k` in `query-string`, nil when absent. Not
  URL-decoded: the benchmark only sends plain integers."
  [^String query-string ^String k]
  (when query-string
    (let [n (.length query-string)
          k-end (.length k)]
      (loop [start 0]
        (when (< start n)
          (let [amp (.indexOf query-string (int \&) start)
                end (if (neg? amp) n amp)]
            (if (and (.startsWith query-string k start)
                     (< (+ start k-end) end)
                     (= \= (.charAt query-string (+ start k-end))))
              (subs query-string (+ start k-end 1) end)
              (recur (inc end)))))))))

(defn path-number
  "The unsigned integer following `prefix` in `uri`, nil when `uri` doesn't
  start with `prefix` or the rest isn't digits."
  [^String uri ^String prefix]
  (let [start (.length prefix)]
    (when (and (.startsWith uri prefix)
               (< start (.length uri))
               (Character/isDigit (.charAt uri start)))
      (parse-long (subs uri start)))))

(defn- quality
  "q-value of coding parameters `params` (after the `;`), 1 when absent or
  unreadable."
  ^double [^String params]
  (let [p (.trim params)]
    (or (when (.regionMatches p true 0 "q=" 0 2)
          (parse-double (.trim (subs p 2))))
        1.0)))

(defn encoding-quality
  "q-value an Accept-Encoding value gives `coding`, 0 when refused. An
  explicit entry for `coding` decides, else `*` does."
  [^String accept-encoding ^String coding]
  (if (nil? accept-encoding)
    0.0
    (let [n (.length accept-encoding)]
      (loop [start 0
             star 0.0]
        (if (> start n)
          star
          (let [comma (.indexOf accept-encoding (int \,) start)
                end (if (neg? comma) n comma)
                semi (.indexOf accept-encoding (int \;) start)
                coding-end (if (and (>= semi 0) (< semi end)) semi end)
                entry (.trim (subs accept-encoding start coding-end))
                q (if (= coding-end end)
                    1.0
                    (quality (subs accept-encoding (inc coding-end) end)))]
            (cond
              (.equalsIgnoreCase coding entry) q
              (= "*" entry) (recur (inc end) q)
              :else (recur (inc end) star))))))))

(defn accepts-gzip? [accept-encoding]
  (pos? (encoding-quality accept-encoding "gzip")))

(defn accepted-encodings
  "The precompressed codings an Accept-Encoding value allows, most preferred
  first; br wins ties."
  [accept-encoding]
  (let [br (encoding-quality accept-encoding "br")
        gzip (encoding-quality accept-encoding "gzip")]
    (cond
      (and (pos? br) (>= br gzip)) (if (pos? gzip) ["br" "gzip"] ["br"])
      (pos? gzip) (if (pos? br) ["gzip" "br"] ["gzip"])
      :else [])))

(defn load-dataset [path]
  (when (.exists (io/file path))
    (with-open [in (io/input-stream path)]
      (oda/parse in {:key-fn keyword}))))

(defonce dataset
  (delay (load-dataset "/data/dataset.json")))

(defn compute-json-items [items item-count multiplier]
  (mapv (fn [{:keys [price quantity] :as item}]
          (assoc item :total (* price quantity multiplier)))
        (subvec items 0 (min item-count (count items)))))

(defn request-sum [request]
  (let [query  (:query-string request)
        a      (parse-long-safe (query-param query "a"))
        b      (parse-long-safe (query-param query "b"))
        body   (if (= :post (:request-method request))
                 (with-open [^InputStream in (:body request)]
                   (parse-long-safe (String. (.readAllBytes in) StandardCharsets/UTF_8)))
                 0)]
    (+ a b body)))

(defn text-response [status body]
  {:status  status
   :headers {"content-type" "text/plain"}
   :body    body})

(defn echo-response [request]
  (let [^InputStream in (:body request)]
    {:status  200
     :headers {"content-type" "application/octet-stream"}
     :body    (if in
                (with-open [stream in]
                  (.readAllBytes stream))
                (byte-array 0))}))

(def delay-schedulers
  ;; A timed park of a virtual thread (Thread/sleep) goes through the JDK's
  ;; virtual thread scheduler, whose single DelayScheduler thread holds every
  ;; timer of the process and saturates at high request rates. Delays run on
  ;; their own schedulers instead, one per four cores.
  (let [factory (-> (Thread/ofPlatform) (.daemon true) (.name "delay-scheduler-" 0) (.factory))]
    (vec (repeatedly (max 1 (quot (.availableProcessors (Runtime/getRuntime)) 4))
                     #(Executors/newSingleThreadScheduledExecutor factory)))))

(defn delay-response
  "Responds once `ms` elapsed. The request's virtual thread waits untimed on a
  future that a delay scheduler completes."
  [ms]
  (when (pos? ms)
    (let [done (CompletableFuture.)
          ^ScheduledExecutorService scheduler
          (delay-schedulers (.nextInt (ThreadLocalRandom/current) (count delay-schedulers)))]
      (.schedule scheduler ^Runnable (fn [] (.complete done nil)) (long ms) TimeUnit/MILLISECONDS)
      (.join done)))
  (text-response 200 (str ms)))

(defn gzip-bytes ^bytes [^bytes data]
  ;; Compress on Enso's virtual thread, not wrap-gzip's piped stream backed by
  ;; a platform-thread future per response.
  (let [out (ByteArrayOutputStream. (alength data))]
    (with-open [gzip-out (GZIPOutputStream. out)]
      (.write gzip-out data))
    (.toByteArray out)))

(defn json-items-response [request item-count]
  (if-let [source @dataset]
    (let [multiplier (parse-long-safe (query-param (:query-string request) "m") 1)
          items      (compute-json-items source item-count multiplier)
          body       (oda/write-bytes {:items items :count (count items)})]
      (if (accepts-gzip? (get-in request [:headers "accept-encoding"]))
        {:status  200
         :headers {"content-type" "application/json"
                   "Content-Encoding" "gzip"
                   "Vary" "Accept-Encoding"}
         :body    (gzip-bytes body)}
        {:status  200
         :headers {"content-type" "application/json"}
         :body    body}))
    (text-response 500 "dataset.json not available")))

(defn websocket-echo [request]
  (if (ws/upgrade-request? request)
    {::ws/listener {:on-message (fn [socket message]
                                  (ws/send socket message))}}
    (text-response 426 "websocket upgrade required")))

(def static-root "/data/static")

(def mime-types
  (assoc mime/default-mime-types "js" "application/javascript"))

(def encoding-suffixes {"br" ".br" "gzip" ".gz"})

(defn content-type [^String file-name]
  (let [dot (.lastIndexOf file-name (int \.))]
    (or (when (pos? dot)
          (get mime-types (.toLowerCase (subs file-name (inc dot)))))
        "application/octet-stream")))

(defn static-response
  "Serves `/static/<name>` from `static-root`, or its precompressed twin
  (`<name>.br`, `<name>.gz`) when the request accepts that coding. Files are
  read from disk per request, so replacing them takes effect at once. Names
  with a `/` are refused: the directory is flat."
  [request ^String uri]
  (let [file-name (subs uri (count "/static/"))
        file (File. ^String static-root file-name)]
    (if (and (neg? (.indexOf file-name (int \/))) (.isFile file))
      (let [content-type (content-type file-name)
            twin (some (fn [coding]
                         (let [twin-file (File. ^String static-root
                                                (str file-name (encoding-suffixes coding)))]
                           (when (.isFile twin-file)
                             [coding twin-file])))
                       (accepted-encodings (get-in request [:headers "accept-encoding"])))]
        (if-let [[coding twin-file] twin]
          {:status  200
           :headers {"content-type" content-type
                     "content-encoding" coding
                     "vary" "Accept-Encoding"}
           :body    twin-file}
          {:status  200
           :headers {"content-type" content-type
                     "vary" "Accept-Encoding"}
           :body    file}))
      (text-response 404 "not found"))))

(defn handler [request]
  (case (:uri request)
    ("/baseline11" "/baseline2") (text-response 200 (str (request-sum request)))
    "/pipeline" (text-response 200 "ok")
    "/echo" (if (= :post (:request-method request))
              (echo-response request)
              (text-response 405 "method not allowed"))
    "/ws" (websocket-echo request)
    (if-let [item-count (path-number (:uri request) "/json/")]
      (json-items-response request item-count)
      (if-let [ms (path-number (:uri request) "/delay/")]
        (delay-response ms)
        (if (and (#{:get :head} (:request-method request))
                 (str/starts-with? (:uri request) "/static/"))
          (static-response request (:uri request))
          (text-response 404 "not found"))))))

(defn pem->ssl-context ^SSLContext [^String cert-path ^String key-path]
  (let [certs (with-open [in (FileInputStream. cert-path)]
                (.generateCertificates (CertificateFactory/getInstance "X.509") in))
        chain (into-array Certificate certs)
        der   (->> (-> (slurp key-path)
                       (str/replace #"-----(BEGIN|END) PRIVATE KEY-----" "")
                       (str/replace #"\s" ""))
                   (.decode (Base64/getDecoder)))
        key   (.generatePrivate (KeyFactory/getInstance "RSA")
                                (PKCS8EncodedKeySpec. der))
        pw    (char-array 0)
        store (doto (KeyStore/getInstance "PKCS12")
                (.load nil pw)
                (.setKeyEntry "server" key pw chain))
        kmf   (doto (KeyManagerFactory/getInstance (KeyManagerFactory/getDefaultAlgorithm))
                (.init store pw))]
    (doto (SSLContext/getInstance "TLS")
      (.init (.getKeyManagers kmf) nil nil))))

(def listener-defaults
  ;; The async profile holds 32,000 connections; retain a finite cap with headroom.
  ;; Load generators keep connections open for the whole run: a per-connection
  ;; request cap only forces reconnect waves (and TLS handshakes) mid-run.
  {:max-connections 40000
   :max-keep-alive-requests 0})

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [cert    "/certs/server.crt"
        key     "/certs/server.key"
        ssl     (when (and (.exists (io/file cert)) (.exists (io/file key)))
                  (pem->ssl-context cert key))
        options (cond-> [{:port 8080} {:port 8082 :http2c true}]
                  ssl (into [{:port 8081 :ssl-context ssl}
                             {:port 8443 :ssl-context ssl :http2 true
                              :http3 true :http3-cert-path cert :http3-key-path key}]))
        servers (mapv #(enso/run-server handler (merge listener-defaults %)) options)]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable (fn []
                                          (doseq [server servers]
                                            (enso/stop server)))))
    @(promise)))
