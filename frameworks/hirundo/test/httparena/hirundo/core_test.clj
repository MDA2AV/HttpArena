(ns httparena.hirundo.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]
   [httparena.hirundo.core :as core])
  (:import
   [java.io ByteArrayInputStream ByteArrayOutputStream]
   [java.util.zip GZIPInputStream]))

(defn gunzip-string [bytes]
  (with-open [input (GZIPInputStream. (ByteArrayInputStream. bytes))
              output (ByteArrayOutputStream.)]
    (.transferTo input output)
    (.toString output "UTF-8")))

(deftest baseline-sums-query-and-body
  (is (= {:status 200
          :headers {"content-type" "text/plain"}
          :body "75"}
         (core/app {:request-method :post
                    :uri "/baseline11"
                    :query-string "a=13&b=42"
                    :body (java.io.StringReader. "20")}))))

(deftest echo-preserves-request-bytes
  (let [payload (byte-array [-1 0 1])
        response (core/app {:request-method :post
                            :uri "/echo"
                            :body (ByteArrayInputStream. payload)})]
    (is (= {:status 200
            :headers {"content-type" "application/octet-stream"}}
           (dissoc response :body)))
    (is (= (seq payload) (seq (:body response))))))

(deftest json-items-encode-dynamically-and-compress-per-request
  (let [source [{:id 1 :name "one" :price 5 :quantity 2}]]
    (with-redefs [core/dataset (delay source)]
      (let [response (core/app {:request-method :get
                                :uri "/json/1"
                                :query-string "m=3"
                                :headers {"accept-encoding" "gzip"}})]
        (is (= {"content-type" "application/json"
                "content-encoding" "gzip"}
               (:headers response)))
        (is (= {:items [{:id 1 :name "one" :price 5 :quantity 2 :total 30}]
                :count 1}
               (json/read-str (gunzip-string (:body response)) :key-fn keyword)))))))

(deftest listener-options-use-public-server-configuration
  (is (= {:host "0.0.0.0"
          :port 8082
          :http-handler core/app
          :websocket-endpoints core/websocket-endpoints}
         (core/listener-options 8082 false))))
