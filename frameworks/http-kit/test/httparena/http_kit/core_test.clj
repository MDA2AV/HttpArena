(ns httparena.http-kit.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]
   [httparena.http-kit.core :as core]
   [next.jdbc :as jdbc]))

(def empty-response
  {:status  200
   :headers {"content-type" "application/json"}
   :body    "{\"items\":[],\"count\":0}"})

(def sample-row
  {:id           1
   :name         "item"
   :category     "cat"
   :price        10
   :quantity     2
   :active       true
   :tags         "[\"a\"]"
   :rating_score 4
   :rating_count 3})

(defn response-body [request]
  (json/read-str (:body (core/async-db-response request)) :key-fn keyword))

(deftest converts-postgres-uri-for-hikari
  (with-redefs [core/database-max-conn (constantly 256)]
    (is (= {:jdbc-url          "jdbc:postgresql://localhost:5432/benchmark?ApplicationName=proof"
            :username          "bench name"
            :password          "p:a@ss"
            :maximum-pool-size 256}
           (core/database-url->hikari-options
            "postgres://bench%20name:p%3Aa%40ss@localhost:5432/benchmark?ApplicationName=proof")))))

(deftest builds-async-db-statements
  (is (= [[core/async-db-query 10 50 50]
          [core/async-db-query 10 50 50]
          [core/async-db-query 10 50 1]
          [core/async-db-query 10 50 50]]
         [(core/async-db-statement {})
          (core/async-db-statement {"min" "invalid"
                                                "max" "invalid"
                                                "limit" "invalid"})
          (core/async-db-statement {"limit" "0"})
          (core/async-db-statement {"limit" "51"})])))

(deftest maps-jdbc-rows-into-the-shared-response-shape
  (with-redefs [core/init-async-db! (constantly ::datasource)
                jdbc/execute! (fn [_ _ _] [sample-row])]
    (is (= {:items [{:id       1
                     :name     "item"
                     :category "cat"
                     :price    10
                     :quantity 2
                     :active   true
                     :tags     ["a"]
                     :rating   {:score 4 :count 3}}]
            :count 1}
           (response-body {:params {}})))))

(deftest returns-the-canonical-empty-response-for-jdbc-failure
  (with-redefs [core/init-async-db! (constantly ::datasource)
                jdbc/execute! (fn [& _]
                                (throw (ex-info "query failed" {})))]
    (is (= {:items [] :count 0}
           (response-body {:params {}})))))

(deftest exposes-async-db
  (with-redefs [core/init-async-db! (constantly nil)]
    (is (= empty-response
           (core/app {:uri "/async-db"})))))
