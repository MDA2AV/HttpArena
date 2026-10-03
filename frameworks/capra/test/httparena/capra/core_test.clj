(ns httparena.capra.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]
   [httparena.capra.core :as core]))

(def dataset
  [{:id       1
    :name     "Alpha"
    :category "tools"
    :price    2
    :quantity 4
    :active   true
    :tags     ["new"]
    :rating   {:score 5 :count 6}}])

(deftest serves-required-http-routes
  (with-redefs [core/dataset (delay dataset)]
    (is (= {:status  200
            :headers {"content-type" "text/plain"}
            :body    "75"}
           (core/app {:request-method :post
                      :uri            "/baseline11"
                      :params         {"a" "13" "b" "42"}
                      :body           (java.io.StringReader. "20")})))
    (is (= {:status  200
            :headers {"content-type" "text/plain"}
            :body    "ok"}
           (core/app {:request-method :get :uri "/pipeline"})))
    (is (= {:count 1
            :items [{:id       1
                     :name     "Alpha"
                     :category "tools"
                     :price    2
                     :quantity 4
                     :active   true
                     :tags     ["new"]
                     :rating   {:score 5 :count 6}
                     :total    24}]}
           (json/read-str (:body (core/app {:request-method :get
                                             :uri            "/json/1"
                                             :params         {"m" "3"}}))
                          :key-fn keyword)))))

(deftest gzip-wraps-dynamic-json
  (with-redefs [core/dataset (delay (vec (repeat 50 (first dataset))))]
    (is (= "gzip"
           (get-in (core/handler {:request-method :get
                                 :uri            "/json/50"
                                 :params         {"m" "3"}
                                 :headers        {"accept-encoding" "gzip"}})
                   [:headers "Content-Encoding"])))))
(deftest websocket-route-uses-native-listener
  (is (= 426
         (:status (core/app {:request-method :get
                             :uri            "/ws"
                             :headers        {"connection" "keep-alive"}}))))
  (is (= #{:ring.websocket/listener}
         (set (keys (core/app {:request-method :get
                               :uri            "/ws"
                               :headers        {"connection" "Upgrade"
                                                "upgrade"    "websocket"}}))))))
