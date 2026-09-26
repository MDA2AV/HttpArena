(ns aleph-bench.core
  (:require [aleph.http :as http]
            [aleph.netty :as netty]
            [clojure.data.json :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [manifold.deferred :as d]
            [manifold.stream :as stream]
            [manifold.time :as time])
  (:import (io.netty.buffer ByteBuf)
           (java.io ByteArrayOutputStream)
           (java.net URLDecoder)
           (java.nio.charset StandardCharsets)
           (java.nio.file Files LinkOption Path))
  (:gen-class))

(def ^:private json-headers {"Content-Type" "application/json"
                             "Server"       "aleph"})
(def ^:private text-headers {"Content-Type" "text/plain"
                             "Server"       "aleph"})
(def ^:private dataset-path "/data/dataset.json")
(def ^:private static-root (.toPath (io/file "/data/static")))

(defn- load-json [path]
  (json/read-str (slurp path) :key-fn keyword))

(defn- parse-long-value [value default]
  (try
    (Long/parseLong value)
    (catch Exception _
      default)))

(defn- sum-params [query-string]
  (let [params (if (str/blank? query-string)
                 {}
                 (into {}
                       (keep (fn [part]
                               (let [[key value] (str/split part #"=" 2)]
                                 (when value [key value]))))
                       (str/split query-string #"&")))]
    (+ (parse-long-value (get params "a") 0)
       (parse-long-value (get params "b") 0))))

(defn- text-response [value]
  {:status  200
   :headers text-headers
   :body    (str value)})

(defn- read-body-bytes [body]
  (if (nil? body)
    (d/success-deferred (byte-array 0))
    (d/chain
     (stream/reduce
      (fn [^ByteArrayOutputStream output ^ByteBuf buffer]
        (try
          (let [bytes (byte-array (.readableBytes buffer))]
            (.readBytes buffer bytes)
            (.write output bytes)
            output)
          (finally
            (.release buffer))))
      (ByteArrayOutputStream.)
      body)
     #(.toByteArray ^ByteArrayOutputStream %))))

(defn- item-with-total [item multiplier]
  (assoc item :total (* (:price item) (:quantity item) multiplier)))

(defn- json-response [dataset requested-count multiplier]
  (let [items (mapv #(item-with-total % multiplier)
                    (take requested-count dataset))]
    {:status  200
     :headers json-headers
     :body    (json/write-str {:items items :count (count items)})}))

(defn- content-type [^Path path]
  (or (Files/probeContentType path) "application/octet-stream"))

(defn- static-response [uri]
  (let [^Path root static-root
        relative   (URLDecoder/decode (subs uri (count "/static/")) StandardCharsets/UTF_8)
        ^Path path (.normalize (.resolve root relative))]
    (if (and (.startsWith path root)
             (Files/isRegularFile path (make-array LinkOption 0)))
      {:status  200
       :headers {"Content-Type" (content-type path)}
       :body    (io/input-stream (.toFile path))}
      {:status  404
       :headers text-headers
       :body    "Not found"})))

(defn- websocket-echo [request]
  (-> (http/websocket-connection request)
      (d/chain (fn [socket]
                 (stream/connect socket socket)))
      (d/catch (fn [_]
                 {:status  426
                  :headers text-headers
                  :body    "Upgrade Required"}))))

(defn- handler [dataset]
  (fn [request]
    (let [uri          (:uri request)
          query-string (:query-string request)
          method       (:request-method request)]
      (cond
        (and (= method :get) (= uri "/pipeline"))
        (text-response "ok")

        (and (= method :get) (#{"/baseline11" "/baseline2"} uri))
        (text-response (sum-params query-string))

        (and (= method :post) (= uri "/baseline11"))
        (d/chain (read-body-bytes (:body request))
                 #(text-response (+ (sum-params query-string)
                                    (parse-long-value (String. ^bytes % StandardCharsets/UTF_8) 0))))

        (and (= method :get) (re-matches #"/json/\d+" uri))
        (json-response dataset
                       (parse-long-value (subs uri (count "/json/")) 50)
                       (parse-long-value (second (re-find #"(?:^|&)m=(\d+)" (or query-string ""))) 1))

        (and (= method :get) (= uri "/json"))
        (json-response dataset (count dataset) 1)

        (and (= method :get) (re-matches #"/delay/\d+" uri))
        (let [milliseconds (parse-long-value (subs uri (count "/delay/")) 0)]
          (if (pos? milliseconds)
            (time/in milliseconds #(text-response milliseconds))
            (text-response milliseconds)))

        (and (= method :post) (= uri "/echo"))
        (d/chain (read-body-bytes (:body request))
                 #(hash-map :status 200
                            :headers {"Content-Type" "application/octet-stream"}
                            :body %))

        (and (= method :get) (str/starts-with? uri "/static/"))
        (static-response uri)

        (and (= method :get) (= uri "/ws"))
        (websocket-echo request)

        :else
        {:status  404
         :headers text-headers
         :body    "Not found"}))))

(defn- start-server! [handler options]
  (http/start-server handler (assoc options :raw-stream? true)))

(defn- ssl-context [http-versions]
  (netty/ssl-server-context
   {:private-key                 (io/file "/certs/server.key")
    :certificate-chain           (io/file "/certs/server.crt")
    :application-protocol-config (netty/application-protocol-config http-versions)}))

(defn -main [& _]
  (let [handler (handler (load-json dataset-path))]
    (start-server! handler {:port 8080 :compression? true})
    (start-server! handler {:port 8082 :http-versions [:http2] :use-h2c? true})
    (start-server! handler {:port          8081
                            :ssl-context   (ssl-context [:http1])
                            :http-versions [:http1]
                            :compression?  true})
    (start-server! handler {:port          8443
                            :ssl-context   (ssl-context [:http2])
                            :http-versions [:http2]
                            :compression?  true})
    @(promise)))