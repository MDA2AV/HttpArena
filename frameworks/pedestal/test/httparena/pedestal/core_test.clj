(ns httparena.pedestal.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]
   [httparena.pedestal.core :as core])
  (:import
   [org.eclipse.jetty.util.thread QueuedThreadPool]))

(deftest converts-postgres-uri-for-hikari
  (is (= {:jdbc-url          "jdbc:postgresql://localhost:5432/benchmark?ApplicationName=proof"
          :username          "bench name"
          :password          "p:a@ss"
          :maximum-pool-size 256}
         (core/database-url->hikari-options
          "postgres://bench%20name:p%3Aa%40ss@localhost:5432/benchmark?ApplicationName=proof"))))

(deftest async-db-fallback-normalizes-pedestal-query-params
  (with-redefs [core/datasource! (constantly nil)]
    (is (= {:status  200
            :headers {"Content-Type" "application/json"}
            :body    {"items" [] "count" 0}}
           (update (core/async-db-handler
                    {:query-params {:min "10" :max "50" :limit "50"}})
                   :body
                   json/read-str)))))

(deftest virtual-thread-pool-uses-jettys-public-pool-type
  (is (instance? QueuedThreadPool (core/virtual-thread-pool))))
