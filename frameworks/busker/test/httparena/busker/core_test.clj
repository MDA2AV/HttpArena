(ns httparena.busker.core-test
  (:require
   [clojure.data.json :as json]
   [clojure.test :refer [deftest is]]
   [httparena.busker.core :as core])
  (:import
   [java.io ByteArrayInputStream]
   [java.nio.file CopyOption FileVisitOption Files OpenOption Path Paths StandardCopyOption]
   [java.nio.file.attribute FileAttribute]))

(deftest baseline-sums-query-and-body
  (is (= {:status 200
          :headers {"content-type" "text/plain"}
          :body "75"}
         (core/app {:request-method :post
                    :uri "/baseline11"
                    :query-string "a=13&b=42"
                    :body (java.io.StringReader. "20")}))))

(deftest echo-preserves-request-bytes
  (let [payload (byte-array [-1 0 1])
        response (core/app {:request-method :post
                            :uri "/echo"
                            :body (ByteArrayInputStream. payload)})]
    (is (= {:status 200
            :headers {"content-type" "application/octet-stream"}}
           (dissoc response :body)))
    (is (= (seq payload) (seq (:body response))))))

(deftest delay-responds-with-the-delay
  (is (= {:status 200
          :headers {"content-type" "text/plain"}
          :body "5"}
         (core/app {:request-method :get :uri "/delay/5"}))))

(deftest config-separates-protocol-listeners
  (is (= {:http {:http1? true :http2? false :http3? false :tls false}
          :h2c {:http1? false :http2? true :http3? false :tls false}
          :https {:http1? true
                  :http2? false
                  :http3? false
                  :tls {:tls-compatibility-mode :modern}}
          :h2-h3 {:http1? false
                  :http2? true
                  :http3? true
                  :tls {:tls-compatibility-mode :modern}}}
         (update-vals (:entrypoints (core/config))
                      #(select-keys % [:http1? :http2? :http3? :tls])))))

(deftest json-items-follow-request-count-and-multiplier
  (let [source [{:id 1 :name "one" :price 5 :quantity 2}
                {:id 2 :name "two" :price 7 :quantity 3}]]
    (with-redefs [core/dataset (delay source)]
      (is (= {:items [{:id 1 :name "one" :price 5 :quantity 2 :total 30}
                      {:id 2 :name "two" :price 7 :quantity 3 :total 63}]
              :count 2}
             (json/read-str (:body (core/app {:request-method :get
                                               :uri "/json/2"
                                               :query-string "m=3"}))
                            :key-fn keyword)))
      (is (= {:items [{:id 1 :name "one" :price 5 :quantity 2 :total 20}]
              :count 1}
             (json/read-str (:body (core/app {:request-method :get
                                               :uri "/json/1"
                                               :query-string "m=2"}))
                            :key-fn keyword))))))

(def ^Path arena-static
  (Paths/get "../../data/static" (make-array String 0)))

(defn- disk-bytes [^Path dir filename]
  (vec (Files/readAllBytes (.resolve dir ^String filename))))

(defn- static-get
  "Requests `/static/<filename>` with the Accept-Encoding value `accept`, or
  with no Accept-Encoding when `accept` is nil. The body is a vector of bytes."
  [filename accept]
  (-> (core/app (cond-> {:request-method :get :uri (str "/static/" filename)}
                  accept (assoc :headers {"accept-encoding" accept})))
      (update :body vec)))

(defn- with-static-copy
  "Calls `f` with a copy of the arena static files, served as the static root."
  [f]
  (let [dir (Files/createTempDirectory "busker-static" (make-array FileAttribute 0))
        root (.resolve dir "static")]
    (try
      (Files/createDirectory root (make-array FileAttribute 0))
      (with-open [files (Files/list arena-static)]
        (doseq [^Path file (iterator-seq (.iterator files))]
          (Files/copy file (.resolve root (.getFileName file)) (make-array CopyOption 0))))
      (Files/writeString (.resolve dir "secret.txt") "secret" (make-array OpenOption 0))
      (with-redefs [core/static-root root]
        (f root))
      (finally
        (with-open [paths (Files/walk dir (make-array FileVisitOption 0))]
          (doseq [^Path path (reverse (iterator-seq (.iterator paths)))]
            (Files/delete path)))))))

(def arena-accept "br;q=1, gzip;q=0.8")

(deftest static-sends-brotli-variant-when-accepted
  (with-static-copy
    (fn [root]
      (is (= {:status 200
              :headers {"content-type" "application/javascript"
                        "content-encoding" "br"
                        "vary" "Accept-Encoding"}
              :body (disk-bytes root "app.js.br")}
             (static-get "app.js" arena-accept))))))

(deftest static-sends-gzip-variant-when-brotli-is-refused
  (with-static-copy
    (fn [root]
      (is (= {:status 200
              :headers {"content-type" "text/css"
                        "content-encoding" "gzip"
                        "vary" "Accept-Encoding"}
              :body (disk-bytes root "reset.css.gz")}
             (static-get "reset.css" "br;q=0, gzip"))))))

(deftest static-sends-original-without-accepted-coding
  (with-static-copy
    (fn [root]
      (doseq [accept [nil "identity" "br;q=0, gzip;q=0"]]
        (is (= {:status 200
                :headers {"content-type" "application/json"
                          "vary" "Accept-Encoding"}
                :body (disk-bytes root "manifest.json")}
               (static-get "manifest.json" accept))
            (str "Accept-Encoding: " accept))))))

(deftest static-sends-original-of-file-without-variants
  (with-static-copy
    (fn [root]
      (is (= [{:status 200
               :headers {"content-type" "image/webp" "vary" "Accept-Encoding"}
               :body (disk-bytes root "hero.webp")}
              {:status 200
               :headers {"content-type" "font/woff2" "vary" "Accept-Encoding"}
               :body (disk-bytes root "regular.woff2")}]
             [(static-get "hero.webp" arena-accept)
              (static-get "regular.woff2" arena-accept)])))))

(deftest static-follows-replaced-files
  (with-static-copy
    (fn [^Path root]
      (let [before [(:body (static-get "app.js" arena-accept))
                    (:body (static-get "app.js" nil))]]
        (doseq [filename ["app.js" "app.js.br"]]
          (let [replacement (.resolve root (str filename ".new"))]
            (Files/write replacement (.getBytes (str "new " filename)) (make-array OpenOption 0))
            (Files/move replacement (.resolve root ^String filename)
                        (into-array CopyOption [StandardCopyOption/REPLACE_EXISTING]))))
        (is (= {:before [(disk-bytes arena-static "app.js.br") (disk-bytes arena-static "app.js")]
                :after [(vec (.getBytes "new app.js.br")) (vec (.getBytes "new app.js"))]}
               {:before before
                :after [(:body (static-get "app.js" arena-accept))
                        (:body (static-get "app.js" nil))]}))))))

(deftest static-refuses-missing-files-and-paths-outside-root
  (with-static-copy
    (fn [_]
      (is (= [{:status 404 :headers {"content-type" "text/plain"} :body (vec "not found")}
              {:status 404 :headers {"content-type" "text/plain"} :body (vec "not found")}]
             [(static-get "nonexistent.txt" arena-accept)
              (static-get "../secret.txt" arena-accept)])))))
