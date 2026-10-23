(ns httparena.enso.core-test
  (:require
   [s-exp.oda :as oda]
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
               (update response :body #(oda/parse % {:key-fn keyword}))))))))

(deftest query-parameters-are-matched-by-exact-name
  (is (= "7" (:body (core/handler {:uri "/baseline11" :request-method :get
                                   :query-string "xa=100&a=3&ab=200&b=4"}))))
  (is (= "0" (:body (core/handler {:uri "/baseline11" :request-method :get}))))
  (is (= "5" (:body (core/handler {:uri "/baseline11" :request-method :get
                                   :query-string "a=5&b="})))))

(deftest baseline-post-body-ignores-surrounding-whitespace
  (is (= "75" (:body (core/handler {:uri "/baseline11" :request-method :post :query-string "a=13&b=42"
                                    :body (ByteArrayInputStream. (.getBytes " 20\r\n" StandardCharsets/UTF_8))})))))

(deftest json-multiplier-defaults-to-one
  (with-redefs [core/dataset (delay dataset)]
    (is (= [8 15]
           (->> (core/handler {:uri "/json/2" :request-method :get})
                :body
                (#(oda/parse % {:key-fn keyword}))
                :items
                (mapv :total))))))

(deftest numeric-routes-require-digits
  (doseq [uri ["/json/" "/json/abc" "/json/1x" "/delay/" "/delay/-1" "/jsonx/1"]]
    (is (= 404 (:status (core/handler {:uri uri :request-method :get}))))))

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
                            ["/pipeline" 200 "ok"]]]
    (is (= {:status status :headers {"content-type" "text/plain"} :body body}
           (core/handler {:uri uri :request-method :get})))))

(deftest delay-responds-after-its-delay
  (let [start (System/nanoTime)
        response (core/handler {:uri "/delay/50" :request-method :get})]
    (is (= {:status 200 :headers {"content-type" "text/plain"} :body "50"} response))
    (is (>= (/ (- (System/nanoTime) start) 1e6) 50))))

(deftest delay-routes-answer-immediately-without-a-delay
  (doseq [[uri status body] [["/delay/0" 200 "0"]
                            ["/delay/abc" 404 "not found"]]]
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
                            (oda/parse in {:key-fn keyword}))}))))
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
        (is (= (update (core/handler request) :body vec)
               (update (core/handler (assoc request :headers {"accept-encoding" encoding})) :body vec)))))))

(deftest accepts-gzip-follows-quality-values
  (doseq [[header expected] [["gzip, br" true]
                             ["GZIP" true]
                             ["br, gzip;q=0.5" true]
                             ["br ; q=1, gzip ; q=0.001" true]
                             ["*" true]
                             ["gzip;q=0" false]
                             ["gzip;q=0.000" false]
                             ["gzip; q=0, *" false]
                             ["*;q=0" false]
                             ["br" false]
                             ["x-gzip" false]
                             ["" false]
                             [nil false]]]
    (is (= expected (core/accepts-gzip? header)) (pr-str header))))

(deftest accepted-encodings-are-ordered-by-quality
  (doseq [[header expected] [["br;q=1, gzip;q=0.8" ["br" "gzip"]]
                             ["gzip;q=1, br;q=0.5" ["gzip" "br"]]
                             ["gzip, br" ["br" "gzip"]]
                             ["br;q=0, gzip" ["gzip"]]
                             ["*" ["br" "gzip"]]
                             ["*;q=0.5, gzip" ["gzip" "br"]]
                             ["identity" []]
                             [nil []]]]
    (is (= expected (core/accepted-encodings header)) (pr-str header))))

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
                    :type (get-in response [:headers "content-type"])
                    :encoding (get-in response [:headers "content-encoding"])
                    :body (slurp (:body response))}))))
        (doseq [uri ["/static/missing.css" "/static/../app.js" "/static/" "/static/.." "/static/."]]
          (is (= 404 (:status (core/handler (assoc request :uri uri)))))))
      (finally
        (.delete file)
        (.delete root)))))

(deftest static-files-serve-precompressed-twins-from-disk
  (let [root (.toFile (java.nio.file.Files/createTempDirectory
                      "enso-static" (make-array java.nio.file.attribute.FileAttribute 0)))
        files (mapv #(java.io.File. root ^String %) ["app.js" "app.js.br" "app.js.gz" "solo.js.br"])
        serve (fn [uri accept]
                (let [response (core/handler {:uri uri :request-method :get
                                              :headers {"accept-encoding" accept}})]
                  {:status (:status response)
                   :headers (:headers response)
                   :body (let [body (:body response)]
                           (if (string? body) body (slurp body)))}))]
    (try
      (with-redefs [core/static-root (.getPath root)]
        (doseq [version ["v1" "v2"]]
          (doseq [^java.io.File f files]
            (spit f (str (.getName f) " " version)))
          (is (= {:status 200
                  :headers {"content-type" "application/javascript"
                            "content-encoding" "br" "vary" "Accept-Encoding"}
                  :body (str "app.js.br " version)}
                 (serve "/static/app.js" "br;q=1, gzip;q=0.8")))
          (is (= {:status 200
                  :headers {"content-type" "application/javascript"
                            "content-encoding" "gzip" "vary" "Accept-Encoding"}
                  :body (str "app.js.gz " version)}
                 (serve "/static/app.js" "gzip")))
          (is (= {:status 200
                  :headers {"content-type" "application/javascript" "vary" "Accept-Encoding"}
                  :body (str "app.js " version)}
                 (serve "/static/app.js" "identity"))))
        (.delete ^java.io.File (files 1))
        (is (= "gzip" (get-in (serve "/static/app.js" "br, gzip") [:headers "content-encoding"])))
        (is (= 404 (:status (serve "/static/solo.js" "br")))))
      (finally
        (run! #(.delete ^java.io.File %) files)
        (.delete root)))))

(deftest connections-are-not-closed-after-many-requests
  (let [server (enso/run-server core/handler (assoc core/listener-defaults :host "127.0.0.1" :port 0))
        n 1001]
    (try
      (with-open [socket (java.net.Socket. "127.0.0.1" (int (enso/port server)))]
        (.setSoTimeout socket 10000)
        (let [out (.getOutputStream socket)
              in (java.io.BufferedReader. (java.io.InputStreamReader. (.getInputStream socket) StandardCharsets/US_ASCII))]
          (.write out (.getBytes (apply str (repeat n "GET /pipeline HTTP/1.1\r\nHost: x\r\n\r\n")) StandardCharsets/US_ASCII))
          (.flush out)
          (let [lines (loop [statuses 0 closes 0]
                        (if (= statuses n)
                          {:statuses statuses :closes closes}
                          (let [line (.readLine in)]
                            (cond
                              (nil? line) {:statuses statuses :closes closes}
                              ;; bodies carry no newline, so a status line can follow one on the same line
                              (.contains line "HTTP/1.1 ") (recur (inc statuses) closes)
                              (.equalsIgnoreCase line "connection: close") (recur statuses (inc closes))
                              :else (recur statuses closes)))))]
            (is (= {:statuses n :closes 0} lines)))))
      (finally
        (enso/stop server)))))

(defn -main [& _args]
  (let [results (test/run-tests 'httparena.enso.core-test)]
    (when (pos? (+ (:fail results) (:error results)))
      (throw (ex-info "tests failed" results)))))
