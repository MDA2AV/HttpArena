(ns httparena.http-kit.core-test
  (:require
   [clojure.test :refer [deftest is]]
   [httparena.http-kit.core :as core]))

(deftest handles-baseline-and-pipeline
  (is (= {:status  200
          :headers {"content-type" "text/plain"}
          :body    "55"}
         (core/app {:uri            "/baseline11"
                    :request-method :get
                    :params         {"a" "13"
                                     "b" "42"}})))
  (is (= {:status  200
          :headers {"content-type" "text/plain"}
          :body    "ok"}
         (core/app {:uri            "/pipeline"
                    :request-method :get}))))

(deftest rejects-non-websocket-requests-to-ws
  (is (= {:status  426
          :headers {"content-type" "text/plain"}
          :body    "websocket upgrade required"}
         (core/app {:uri            "/ws"
                    :request-method :get}))))
