(ns ring.core-test
  (:require
   [clojure.test :refer [deftest is]]
   [ring.core]))

(deftest baseline-arithmetic-uses-common-parameters
  (is (= [55 75]
         [(#'ring.core/request-sum
           {:request-method :get
            :query-string   "a=13&b=42&ignored=100"})
          (#'ring.core/request-sum
           {:request-method :post
            :query-string   "a=13&b=42&ignored=100"
            :body           (java.io.StringReader. "20")})])))

(deftest json-response-encodes-only-compressed-bodies
  (let [data       {:items [{:id 1 :price 7 :quantity 3 :total 84}] :count 1}
        plain      (#'ring.core/json-response data false)
        compressed (#'ring.core/json-response data true)
        decoded    (with-open [input (java.util.zip.GZIPInputStream.
                                    (java.io.ByteArrayInputStream. (:body compressed)))]
                     (slurp input :encoding "UTF-8"))]
    (is (string? (:body plain)))
    (is (= "application/json" (get-in plain [:headers "Content-Type"])))
    (is (= "gzip" (get-in compressed [:headers "Content-Encoding"])))
    (is (= (:body plain) decoded))))
