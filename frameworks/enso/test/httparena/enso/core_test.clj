(ns httparena.enso.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :as test :refer [deftest is]]
   [httparena.enso.core :as core]
   [s-exp.enso :as enso])
  (:import
   [java.io ByteArrayInputStream]
   [java.net URI]
   [java.net.http HttpClient HttpRequest HttpResponse$BodyHandlers]
   [java.nio.charset StandardCharsets]
   [java.util.zip GZIPInputStream]))

(def dataset
  [{:id 1 :name "Alpha" :category "tools" :price 2 :quantity 4
    :active true :tags ["new"] :rating {:score 5 :count 6}}
   {:id 2 :name "Beta" :category "tools" :price 3 :quantity 5
    :active false :tags ["sale"] :rating {:score 7 :count 8}}])

(deftest baseline-parses-query-and-post-body
  (doseq [uri ["/baseline11" "/baseline2"]]
    (is (= {:status 200 :headers {"content-type" "text/plain"} :body "55"}
           (core/handler {:uri uri :request-method :get :query-string "a=13&b=42"})))
    (is (= {:status 200 :headers {"content-type" "text/plain"} :body "75"}
           (core/handler {:uri uri :request-method :post :query-string "a=13&b=42"
                          :body (ByteArrayInputStream. (.getBytes "20" StandardCharsets/UTF_8))})))))

(deftest json-preserves-dataset-and-computes-request-specific-totals
  (with-redefs [core/dataset (delay dataset)]
    (doseq [[n m] [[1 3] [2 7] [0 1] [10 2]]]
      (let [response (core/handler {:uri (str "/json/" n) :request-method :get
                                    :query-string (str "m=" m)})
            items    (mapv #(assoc % :total (* (:price %) (:quantity %) m))
                           (take n dataset))]
        (is (= {:status 200 :headers {"content-type" "application/json"}
                :body {:items items :count (count items)}}
               (update response :body #(json/read-str % :key-fn keyword))))))))

(deftest echo-preserves-binary-body
  (let [payload  (byte-array [0 1 -1 -128 13 10])
        response (core/handler {:uri "/echo" :request-method :post
                                :body (ByteArrayInputStream. payload)})]
    (is (= {:status 200 :headers {"content-type" "application/octet-stream"}
            :body (vec payload)}
           (update response :body vec)))))

(deftest routes-reject-unsupported-requests
  (doseq [[uri status body] [["/echo" 405 "method not allowed"]
                            ["/ws" 426 "websocket upgrade required"]
                            ["/missing" 404 "not found"]
                            ["/pipeline" 200 "ok"]
                            ["/delay/0" 200 "0"]]]
    (is (= {:status status :headers {"content-type" "text/plain"} :body body}
           (core/handler {:uri uri :request-method :get})))))

(deftest websocket-upgrade-bypasses-gzip
  (let [response (core/handler {:uri "/ws" :request-method :get
                                :headers {"connection" "Upgrade" "upgrade" "websocket"
                                          "accept-encoding" "gzip"}})]
    (is (= #{:ring.websocket/listener} (set (keys response))))
    (is (fn? (get-in response [:ring.websocket/listener :on-message])))))

(deftest gzip-round-trips-json-over-enso
  (with-redefs [core/dataset (delay (vec (repeat 100 (first dataset))))]
    (let [server (enso/run-server core/handler {:host "127.0.0.1" :port 0})]
      (try
        (with-open [client (HttpClient/newHttpClient)]
          (let [request  (-> (HttpRequest/newBuilder
                              (URI. (str "http://127.0.0.1:" (enso/port server) "/json/100?m=3")))
                             (.header "Accept-Encoding" "gzip")
                             (.build))
                response (.send client request (HttpResponse$BodyHandlers/ofByteArray))]
            (is (= {:status 200 :encoding "gzip"
                    :body {:items (vec (repeat 100 (assoc (first dataset) :total 24)))
                           :count 100}}
                   {:status (.statusCode response)
                    :encoding (.orElse (.firstValue (.headers response) "content-encoding") "")
                    :body (with-open [in (GZIPInputStream. (ByteArrayInputStream. (.body response)))]
                            (json/read-str (slurp in) :key-fn keyword))}))))
        (finally
          (enso/stop server))))))

(deftest gzip-is-materialized-and-respects-negotiation
  (with-redefs [core/dataset (delay dataset)]
    (let [request {:uri "/json/2" :request-method :get}
          response (core/handler (assoc request :headers {"accept-encoding" "gzip"}))]
      (is (bytes? (:body response)))
      (is (= {"content-type" "application/json"
              "Content-Encoding" "gzip" "Vary" "Accept-Encoding"}
             (:headers response)))
      (doseq [encoding ["" "identity" "gzip;q=0"]]
        (is (= (core/handler request)
               (core/handler (assoc request :headers {"accept-encoding" encoding}))))))))

(deftest static-files-are-live-and-confined-to-root
  (let [root (.toFile (java.nio.file.Files/createTempDirectory
                      "enso-static" (make-array java.nio.file.attribute.FileAttribute 0)))
        file (java.io.File. root "app.js")
        request {:uri "/static/app.js" :request-method :get
                 :headers {"accept-encoding" "gzip"}}]
    (try
      (with-redefs [core/static-root (.getPath root)]
        (doseq [body ["first version" "replacement with a different length"]]
          (spit file body)
          (let [response (core/handler request)]
            (is (= {:status 200 :type "application/javascript" :encoding nil :body body}
                   {:status (:status response)
                    :type (get-in response [:headers "Content-Type"])
                    :encoding (get-in response [:headers "Content-Encoding"])
                    :body (slurp (:body response))}))))
        (doseq [uri ["/static/missing.css" "/static/../app.js" "/static/"]]
          (is (= 404 (:status (core/handler (assoc request :uri uri)))))))
      (finally
        (.delete file)
        (.delete root)))))

(defn -main [& _args]
  (let [results (test/run-tests 'httparena.enso.core-test)]
    (when (pos? (+ (:fail results) (:error results)))
      (throw (ex-info "tests failed" results)))))
