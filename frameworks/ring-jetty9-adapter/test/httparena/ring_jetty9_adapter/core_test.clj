(ns httparena.ring-jetty9-adapter.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :as test :refer [deftest is]]
   [httparena.ring-jetty9-adapter.core :as core])
  (:import [java.io ByteArrayInputStream]))

(def sample-dataset
  [{:id       1
    :name     "widget"
    :category "tools"
    :price    10
    :quantity 2
    :active   true
    :tags     ["sale"]
    :rating   {:score 4 :count 9}}])

(def app (core/handler sample-dataset))

(deftest calculates-baseline-sums
  (is (= {:status  200
          :headers {"Content-Type" "text/plain"}
          :body    "75"}
         (app {:request-method :post
               :uri            "/baseline11"
               :query-string   "a=13&b=42"
               :body           (ByteArrayInputStream. (.getBytes "20"))}))))

(deftest encodes-dynamic-json-items
  (is (= {"items" [{"id"       1
                   "name"     "widget"
                   "category" "tools"
                   "price"    10
                   "quantity" 2
                   "active"   true
                   "tags"     ["sale"]
                   "rating"   {"score" 4 "count" 9}
                   "total"    60}]
          "count" 1}
         (-> (app {:request-method :get
                   :uri            "/json/1"
                   :query-string   "m=3"})
             :body
             json/read-str))))

(deftest echoes-request-bytes
  (let [response (app {:request-method :post
                       :uri            "/echo"
                       :body           (ByteArrayInputStream. (byte-array [1 2 3]))})]
    (is (= {:status  200
            :headers {"Content-Type" "application/octet-stream"}
            :body    [1 2 3]}
           (update response :body vec)))))

(deftest rejects-non-websocket-requests
  (is (= {:status  426
          :headers {"Content-Type" "text/plain"}
          :body    "websocket upgrade required"}
         (app {:request-method :get
               :uri            "/ws"}))))

(defn -main [& _]
  (let [results (test/run-tests 'httparena.ring-jetty9-adapter.core-test)]
    (when (pos? (+ (:fail results) (:error results)))
      (throw (ex-info "tests failed" results)))))
