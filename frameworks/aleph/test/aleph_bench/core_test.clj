(ns aleph-bench.core-test
  (:require
   [aleph-bench.core]
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]))

(deftest baseline-arithmetic-uses-common-parameters
  (is (= 55
         (#'aleph-bench.core/sum-params "a=13&b=42&ignored=100"))))

(deftest json-response-has-requested-items-and-totals
  (let [source   [{:id 1 :name "first" :price 7 :quantity 3}
                  {:id 2 :name "second" :price 5 :quantity 2}]
        response (#'aleph-bench.core/json-response source 1 4)
        body     (json/read-str (:body response) :key-fn keyword)]
    (is (= 200 (:status response)))
    (is (= "application/json" (get-in response [:headers "Content-Type"])))
    (is (= 1 (:count body)))
    (is (= [{:id 1 :name "first" :price 7 :quantity 3 :total 84}]
           (:items body)))))
