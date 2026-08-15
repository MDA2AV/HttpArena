(ns httparena.ring-jetty9-adapter.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :as test :refer [deftest is]]
   [httparena.ring-jetty9-adapter.core :as core]))

(deftest converts-postgres-uri-for-hikari
  (is (= {:jdbc-url          "jdbc:postgresql://localhost:5432/benchmark?ApplicationName=proof"
          :username          "bench name"
          :password          "p:a@ss"
          :maximum-pool-size 256}
         (core/database-url->hikari-options
          "postgres://bench%20name:p%3Aa%40ss@localhost:5432/benchmark?ApplicationName=proof"))))

(deftest async-db-falls-back-through-the-ring-handler
  (with-redefs [core/datasource! (constantly nil)]
    (is (= {:status  200
            :headers {"Content-Type" "application/json"}
            :body    {"items" [] "count" 0}}
           (update (core/handler {:uri "/async-db"
                                  :request-method :get
                                  :query-string "min=10&max=50&limit=50"})
                   :body
                   json/read-str)))))

(deftest maps-database-rows-with-nested-rating
  (is (= [{:id       1
           :name     "widget"
           :category "tools"
           :price    10
           :quantity 2
           :active   true
           :tags     ["sale"]
           :rating   {:score 4 :count 9}}]
         (core/rows->items [{:id           1
                             :name         "widget"
                             :category     "tools"
                             :price        10
                             :quantity     2
                             :active       true
                             :tags         "[\"sale\"]"
                             :rating_score 4
                             :rating_count 9}]))))

(defn -main [& _args]
  (let [results (test/run-tests 'httparena.ring-jetty9-adapter.core-test)]
    (when (pos? (+ (:fail results) (:error results)))
      (throw (ex-info "tests failed" results)))))
