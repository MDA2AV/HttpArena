(ns httparena.busker.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]
   [httparena.busker.core :as core])
  (:import
   [java.io ByteArrayInputStream]))

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

(deftest config-separates-protocol-listeners
  (is (= {:http {:http1? true :http2? false :http3? false :tls false}
          :h2c {:http1? false :http2? true :http3? false :tls false}
          :https {:http1? true
                  :http2? false
                  :http3? false
                  :tls {:tls-compatibility-mode :modern}}
          :h2-h3 {:http1? false
                  :http2? true
                  :http3? true
                  :tls {:tls-compatibility-mode :modern}}}
         (update-vals (:entrypoints (core/config))
                      #(select-keys % [:http1? :http2? :http3? :tls])))))

(deftest json-items-follow-request-count-and-multiplier
  (let [source [{:id 1 :name "one" :price 5 :quantity 2}
                {:id 2 :name "two" :price 7 :quantity 3}]]
    (with-redefs [core/dataset (delay source)]
      (is (= {:items [{:id 1 :name "one" :price 5 :quantity 2 :total 30}
                      {:id 2 :name "two" :price 7 :quantity 3 :total 63}]
              :count 2}
             (json/read-str (:body (core/app {:request-method :get
                                               :uri "/json/2"
                                               :query-string "m=3"}))
                            :key-fn keyword)))
      (is (= {:items [{:id 1 :name "one" :price 5 :quantity 2 :total 20}]
              :count 1}
             (json/read-str (:body (core/app {:request-method :get
                                               :uri "/json/1"
                                               :query-string "m=2"}))
                            :key-fn keyword))))))
