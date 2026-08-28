(ns httparena.capra.core
  (:gen-class)
  (:require
   [capra.server :as capra]
   [clojure.data.json :as json]
   [clojure.java.io :as io]
   [clojure.string :as str]
   [ring.middleware.content-type :as content-type]
   [ring.middleware.gzip :as gzip]
   [ring.middleware.params :as params]
   [ring.util.response :as response]))

(set! *warn-on-reflection* true)

(def text-headers {"Content-Type" "text/plain"})
(def json-headers {"Content-Type" "application/json"})

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (try
     (if (nil? value)
       default
       (Long/parseLong (str/trim (str value))))
     (catch NumberFormatException _
       default))))

(defn text-response [body]
  {:status 200
   :headers text-headers
   :body (str body)})

(defn request-sum [request]
  (let [params (:params request)
        query-sum (+ (parse-long-safe (get params "a"))
                     (parse-long-safe (get params "b")))
        body-sum (if (= :post (:request-method request))
                   (parse-long-safe (slurp (:body request)))
                   0)]
    (+ query-sum body-sum)))

(defn json-response [body]
  {:status 200
   :headers json-headers
   :body (json/write-str body)})

(defn json-body [dataset n multiplier]
  (let [n (-> n (max 0) (min (count dataset)))
        items (mapv #(assoc % :total (* (:price %) (:quantity %) multiplier))
                    (subvec dataset 0 n))]
    {:items items
     :count (count items)}))

(defn static-response [uri]
  (let [path (subs uri (count "/static/"))]
    (or (response/file-response path {:root "/data/static"
                                      :index-files? false})
        (response/not-found "not found"))))

(defn app [dataset request]
  (let [uri (:uri request)]
    (cond
      (= uri "/baseline11")
      (text-response (request-sum request))

      (= uri "/pipeline")
      (text-response "ok")

      (str/starts-with? uri "/json/")
      (if-let [[_ raw-n] (re-matches #"/json/(\d+)" uri)]
        (json-response
         (json-body dataset
                    (parse-long-safe raw-n)
                    (parse-long-safe (get-in request [:params "m"]) 1)))
        (response/not-found "not found"))

      (str/starts-with? uri "/static/")
      (static-response uri)

      (= uri "/")
      (text-response "capra")

      :else
      (response/not-found "not found"))))

(defn handler [dataset]
  (-> (partial app dataset)
      (params/wrap-params)
      (content-type/wrap-content-type)
      (gzip/wrap-gzip)))

(defn load-dataset [path]
  (with-open [reader (io/reader path)]
    (json/read reader :key-fn keyword)))

(defn -main [& _args]
  (let [dataset (load-dataset "/data/dataset.json")
        _server (capra/run-server (handler dataset)
                                  {:host "0.0.0.0"
                                   :port 8080})]
    (println "Capra server listening on port 8080")
    @(promise)))
