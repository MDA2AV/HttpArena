(ns httparena.ring.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :as test :refer [are deftest is]]
   [hikari-cp.core :as hikari]
   [httparena.ring.core :as core]
   [next.jdbc :as jdbc]))

(def dataset
  [{:id 1
    :name "Alpha"
    :category "tools"
    :price 2
    :quantity 4
    :active true
    :tags ["new"]
    :rating {:score 5 :count 6}}
   {:id 2
    :name "Beta"
    :category "tools"
    :price 3
    :quantity 5
    :active false
    :tags ["sale"]
    :rating {:score 7 :count 8}}])

(deftest json-route-computes-request-specific-totals
  (with-redefs [core/dataset (delay dataset)]
    (is (= {:items [{:id 1
                     :name "Alpha"
                     :category "tools"
                     :price 2
                     :quantity 4
                     :active true
                     :tags ["new"]
                     :rating {:score 5 :count 6}
                     :total 24}]
            :count 1}
           (json/read-str (:body (core/app {:request-method :get
                                            :uri "/json/1"
                                            :params {"m" "3"}}))
                          :key-fn keyword)))))

(deftest declared-routes-reject-unsupported-methods
  (are [request] (= 405 (:status (core/app request)))
    {:request-method :post :uri "/json/1" :params {}}
    {:request-method :post :uri "/async-db" :params {}}
    {:request-method :get :uri "/upload" :params {}}
    {:request-method :post :uri "/pipeline" :params {}}
    {:request-method :post :uri "/static/app.js" :params {}}))

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

(deftest datasource-creation-retries-after-failure
  (let [attempts (atom 0)
        database ::database
        original @core/datasource]
    (try
      (reset! core/datasource nil)
      (with-redefs [core/database-url->hikari-options (constantly {})
                    hikari/make-datasource (fn [_]
                                             (if (= 1 (swap! attempts inc))
                                               (throw (ex-info "unavailable" {}))
                                               database))]
        (is (= [nil database database]
               [(core/datasource!)
                (core/datasource!)
                (core/datasource!)])))
      (finally
        (reset! core/datasource original)))))

(deftest database-query-failure-falls-back-through-the-ring-handler
  (with-redefs [core/datasource! (constantly ::database)
                jdbc/execute! (fn [& _]
                                (throw (ex-info "query failed" {})))]
    (is (= {"items" [] "count" 0}
           (json/read-str (:body (core/handler {:uri "/async-db"
                                                :request-method :get
                                                :query-string "min=10&max=50&limit=50"})))))))

(deftest database-mapping-failure-falls-back-through-the-ring-handler
  (with-redefs [core/datasource! (constantly ::database)
                jdbc/execute! (constantly [{:id 1 :tags nil}])]
    (is (= {"items" [] "count" 0}
           (json/read-str (:body (core/handler {:uri "/async-db"
                                                :request-method :get
                                                :query-string "min=10&max=50&limit=50"})))))))

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
  (let [results (test/run-tests 'httparena.ring.core-test)]
    (when (pos? (+ (:fail results) (:error results)))
      (throw (ex-info "tests failed" results)))))
