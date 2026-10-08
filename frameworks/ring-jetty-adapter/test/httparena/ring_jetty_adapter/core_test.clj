(ns httparena.ring-jetty-adapter.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :as test :refer [deftest is]]
   [httparena.ring-jetty-adapter.core :as core]
   [ring.websocket :as ws]))

(def dataset
  [{:id       1
    :name     "Alpha"
    :category "tools"
    :price    2
    :quantity 4
    :active   true
    :tags     ["new"]
    :rating   {:score 5 :count 6}}
   {:id       2
    :name     "Beta"
    :category "tools"
    :price    3
    :quantity 5
    :active   false
    :tags     ["sale"]
    :rating   {:score 7 :count 8}}])

(deftest json-route-computes-request-specific-totals
  (with-redefs [core/dataset (delay dataset)]
    (is (= {:items [{:id       1
                     :name     "Alpha"
                     :category "tools"
                     :price    2
                     :quantity 4
                     :active   true
                     :tags     ["new"]
                     :rating   {:score 5 :count 6}
                     :total    24}]
            :count 1}
           (json/read-str (:body (core/app {:request-method :get
                                            :uri            "/json/1"
                                            :params         {"m" "3"}}))
                          :key-fn keyword)))))

(deftest websocket-route-requires-upgrade
  (is (= 426
         (:status (core/app {:request-method :get
                             :uri            "/ws"
                             :headers        {"connection" "keep-alive"}})))))

(deftest websocket-route-returns-native-listener
  (is (= #{::ws/listener}
         (set (keys (core/app {:request-method :get
                               :uri            "/ws"
                               :headers        {"connection" "Upgrade"
                                                "upgrade"    "websocket"}}))))))

(deftest echo-route-preserves-request-bytes
  (let [response (core/handler {:request-method :post
                                :uri            "/echo"
                                :body           (java.io.ByteArrayInputStream.
                                                 (.getBytes "payload" java.nio.charset.StandardCharsets/UTF_8))})]
    (is (= {:status  200
            :headers {"content-type" "application/octet-stream"}
            :body    "payload"}
           (update response :body #(if (string? %)
                                    %
                                    (String. ^bytes % java.nio.charset.StandardCharsets/UTF_8))))))

(deftest baseline-and-delay-routes-retain-engine-semantics
  (is (= {:status  200
          :headers {"content-type" "text/plain"}
          :body    "6"}
         (core/app {:request-method :post
                    :uri            "/baseline11"
                    :params         {"a" "1" "b" "2"}
                    :body           (java.io.StringReader. "3")})))
  (is (= "0"
         (:body (core/app {:request-method :get
                           :uri            "/delay/0"})))))

(defn -main [& _args]
  (let [results (test/run-tests 'httparena.ring-jetty-adapter.core-test)]
    (when (pos? (+ (:fail results) (:error results)))
      (throw (ex-info "tests failed" results))))))