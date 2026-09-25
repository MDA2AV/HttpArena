(ns httparena.http-kit.core
  (:gen-class)
  (:require
   [clojure.data.json :as json]
   [clojure.string :as str]
   [org.httpkit.server :as http-kit]
   [org.httpkit.timer :as timer]
   [ring.middleware.gzip :as gzip]
   [ring.middleware.params :as params]))

(set! *warn-on-reflection* true)

(def json-content-type "application/json")

(defn parse-long-safe
  ([value]
   (parse-long-safe value 0))
  ([value default]
   (or (some-> value str str/trim not-empty parse-long)
       default)))

(defn load-dataset [^String path]
  (when (.exists (java.io.File. path))
    (json/read-str (slurp path) :key-fn keyword)))

(defonce dataset
  (delay (load-dataset "/data/dataset.json")))

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

(defn text-response [status body]
  {:status  status
   :headers {"content-type" "text/plain"}
   :body    body})

(defn json-response [status body]
  {:status  status
   :headers {"content-type" json-content-type}
   :body    (json/write-str body)})

(defn delay-response [request]
  (let [ms (parse-long-safe (subs (:uri request) 7))]
    (if (pos? ms)
      (http-kit/as-channel request
        {:on-open (fn [channel]
                    (timer/schedule-task ms
                      (http-kit/send! channel (text-response 200 (str ms)))))})
      (text-response 200 (str ms)))))

(defn json-items-response [request]
  (if-let [source @dataset]
    (let [[_ path-count] (re-matches #"/json/([0-9]+)" (:uri request))
          item-count     (if path-count (parse-long-safe path-count) (count source))
          multiplier     (parse-long-safe (get-in request [:params "m"]) 1)
          items          (take item-count source)]
      (json-response 200 {:items (compute-json-items items multiplier)
                          :count (count items)}))
    (text-response 500 "dataset.json not available")))

(defn websocket-echo [request]
  (if (:websocket? request)
    (http-kit/as-channel request
      {:on-receive (fn [channel message]
                     (http-kit/send! channel message false))})
    (text-response 426 "websocket upgrade required")))

(defn app [request]
  (case (:uri request)
    "/baseline11" (text-response 200 (str (request-sum request)))
    "/pipeline" (text-response 200 "ok")
    "/ws" (websocket-echo request)
    (cond
      (re-matches #"/json/[0-9]+" (:uri request)) (json-items-response request)
      (re-matches #"/delay/[0-9]+" (:uri request)) (delay-response request)
      :else (text-response 404 "not found"))))

(def compressed-handler
  (-> app
      params/wrap-params
      gzip/wrap-gzip))

(defn handler [request]
  (if (:websocket? request)
    (app request)
    (compressed-handler request)))

(defn -main [& _args]
  (when-not (vector? @dataset)
    (throw (ex-info "dataset.json must contain a JSON array"
                    {:path "/data/dataset.json"})))
  (let [stop-server (http-kit/run-server handler {:ip   "0.0.0.0"
                                                  :port 8080})]
    (.addShutdownHook (Runtime/getRuntime)
                      (Thread. ^Runnable (fn []
                                          (stop-server))))
    @(promise)))
