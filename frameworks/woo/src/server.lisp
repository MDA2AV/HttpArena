(defpackage :httparena
  (:use :cl)
  (:export :main))

(in-package :httparena)

;;; ---------------------------------------------------------------------------
;;; Data structures
;;; ---------------------------------------------------------------------------

(defstruct rating score count)
(defstruct dataset-item id name category price quantity active tags rating)

(defvar *dataset* nil)
(defvar *json-large-compressed* nil)
(defvar *static-files* (make-hash-table :test #'equal))
(defvar *db* nil)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun read-file-to-string (path)
  (when (probe-file path)
    (with-open-file (s path :direction :input :external-format :utf-8)
      (let* ((len (file-length s))
             (data (make-string len)))
        (read-sequence data s)
        data))))

(defun read-file-to-bytes (path)
  (when (probe-file path)
    (with-open-file (s path :direction :input :element-type '(unsigned-byte 8))
      (let ((data (make-array (file-length s) :element-type '(unsigned-byte 8))))
        (read-sequence data s)
        data))))

(defun parse-json-file (path)
  (let ((text (read-file-to-string path)))
    (when text (jonathan:parse text :as :alist))))

(defun guess-content-type (name)
  (let* ((dot-pos (position #\. name :from-end t))
         (ext (if dot-pos (subseq name dot-pos) "")))
    (cond
      ((string= ext ".css") "text/css")
      ((string= ext ".js") "application/javascript")
      ((string= ext ".html") "text/html")
      ((string= ext ".woff2") "font/woff2")
      ((string= ext ".svg") "image/svg+xml")
      ((string= ext ".webp") "image/webp")
      ((string= ext ".json") "application/json")
      (t "application/octet-stream"))))

(defun get-cpu-count ()
  "Get number of CPU cores, falling back to 4."
  (handler-case
      (let ((nproc (uiop:run-program "nproc" :output :string)))
        (or (parse-integer (string-trim '(#\Space #\Newline) nproc) :junk-allowed t) 4))
    (error () 4)))

(defun safe-parse-float (str &optional default)
  "Parse a float from string, returning default on failure."
  (handler-case
      (let ((val (with-input-from-string (s str) (read s))))
        (if (numberp val) (coerce val 'double-float) default))
    (error () default)))

;;; ---------------------------------------------------------------------------
;;; Gzip compression via salza2
;;; ---------------------------------------------------------------------------

(defun gzip-compress (data)
  "Compress a byte vector using gzip."
  (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (salza2:with-compressor (comp 'salza2:gzip-compressor
                                  :callback (lambda (buffer end)
                                              (loop for i below end
                                                    do (vector-push-extend (aref buffer i) out))))
      (salza2:compress-octet-vector data comp))
    (let ((result (make-array (length out) :element-type '(unsigned-byte 8))))
      (replace result out)
      result)))

;;; ---------------------------------------------------------------------------
;;; Dataset loading
;;; ---------------------------------------------------------------------------

(defun alist-get (key alist)
  (cdr (assoc key alist :test #'string=)))

(defun parse-item (item)
  (let ((r (alist-get "rating" item)))
    (make-dataset-item
     :id (alist-get "id" item)
     :name (alist-get "name" item)
     :category (alist-get "category" item)
     :price (alist-get "price" item)
     :quantity (alist-get "quantity" item)
     :active (alist-get "active" item)
     :tags (alist-get "tags" item)
     :rating (make-rating
              :score (alist-get "score" r)
              :count (alist-get "count" r)))))

(defun item-to-processed-alist (item)
  (let ((total (/ (round (* (dataset-item-price item)
                            (dataset-item-quantity item) 100)) 100.0d0)))
    `(("id" . ,(dataset-item-id item))
      ("name" . ,(dataset-item-name item))
      ("category" . ,(dataset-item-category item))
      ("price" . ,(dataset-item-price item))
      ("quantity" . ,(dataset-item-quantity item))
      ("active" . ,(if (dataset-item-active item) :true :false))
      ("tags" . ,(coerce (dataset-item-tags item) 'vector))
      ("rating" . (("score" . ,(rating-score (dataset-item-rating item)))
                   ("count" . ,(rating-count (dataset-item-rating item)))))
      ("total" . ,total))))

(defun build-json-response (items)
  (let ((processed (mapcar #'item-to-processed-alist items)))
    (jonathan:to-json
     `(("items" . ,(coerce processed 'vector))
       ("count" . ,(length processed))))))

(defun load-dataset ()
  (let* ((path (or (uiop:getenv "DATASET_PATH") "/data/dataset.json"))
         (items (parse-json-file path)))
    (when items
      (setf *dataset* (mapcar #'parse-item items)))))

(defun load-dataset-large ()
  (let ((items (parse-json-file "/data/dataset-large.json")))
    (when items
      (let* ((structs (mapcar #'parse-item items))
             (json-str (build-json-response structs))
             (json-bytes (babel:string-to-octets json-str :encoding :utf-8)))
        (setf *json-large-compressed* (gzip-compress json-bytes))))))

(defun load-static-files ()
  (when (uiop:directory-exists-p "/data/static/")
    (dolist (path (uiop:directory-files "/data/static/"))
      (let* ((name (file-namestring path))
             (data (read-file-to-bytes path))
             (ct (guess-content-type name)))
        (setf (gethash name *static-files*) (cons ct data))))))

(defun load-db ()
  (when (probe-file "/data/benchmark.db")
    (setf *db* (sqlite:connect "/data/benchmark.db"))))

;;; ---------------------------------------------------------------------------
;;; Query parsing
;;; ---------------------------------------------------------------------------

(defun parse-query-sum (query-string)
  (let ((sum 0))
    (when (and query-string (> (length query-string) 0))
      (dolist (pair (cl-ppcre:split "&" query-string))
        (let ((eq-pos (position #\= pair)))
          (when eq-pos
            (handler-case
                (incf sum (parse-integer (subseq pair (1+ eq-pos))))
              (error () nil))))))
    sum))

(defun get-query-param (query-string key)
  (when (and query-string (> (length query-string) 0))
    (dolist (pair (cl-ppcre:split "&" query-string))
      (let ((eq-pos (position #\= pair)))
        (when (and eq-pos (string= key (subseq pair 0 eq-pos)))
          (return-from get-query-param (subseq pair (1+ eq-pos))))))))

;;; ---------------------------------------------------------------------------
;;; Read request body
;;; ---------------------------------------------------------------------------

(defun read-body-string (env)
  (let ((raw-body (getf env :raw-body))
        (content-length (getf env :content-length)))
    (when raw-body
      (if content-length
          (let ((buf (make-array content-length :element-type '(unsigned-byte 8))))
            (read-sequence buf raw-body)
            (babel:octets-to-string buf :encoding :utf-8))
          (let ((out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
            (loop for byte = (read-byte raw-body nil nil)
                  while byte do (vector-push-extend byte out))
            (babel:octets-to-string out :encoding :utf-8))))))

(defun read-body-length (env)
  "Read body and return its byte length."
  (let ((raw-body (getf env :raw-body))
        (content-length (getf env :content-length)))
    (cond
      ((and content-length raw-body)
       ;; Drain the stream
       (let ((buf (make-array content-length :element-type '(unsigned-byte 8))))
         (read-sequence buf raw-body)
         content-length))
      (raw-body
       (let ((n 0))
         (loop for byte = (read-byte raw-body nil nil)
               while byte do (incf n))
         n))
      (t 0))))

;;; ---------------------------------------------------------------------------
;;; Handlers
;;; ---------------------------------------------------------------------------

(defun handle-pipeline (env)
  (declare (ignore env))
  '(200 (:content-type "text/plain" :server "woo") ("ok")))

(defun handle-baseline11 (env)
  (let* ((query (getf env :query-string))
         (method (getf env :request-method))
         (sum (parse-query-sum query)))
    (when (eq method :POST)
      (let ((body (read-body-string env)))
        (when (and body (> (length body) 0))
          (handler-case
              (incf sum (parse-integer (string-trim '(#\Space #\Newline #\Return #\Tab) body)))
            (error () nil)))))
    `(200 (:content-type "text/plain" :server "woo")
          (,(princ-to-string sum)))))

(defun handle-baseline2 (env)
  `(200 (:content-type "text/plain" :server "woo")
        (,(princ-to-string (parse-query-sum (getf env :query-string))))))

(defun handle-json (env)
  (declare (ignore env))
  (if (null *dataset*)
      '(200 (:content-type "application/json" :server "woo") ("{\"items\":[],\"count\":0}"))
      `(200 (:content-type "application/json" :server "woo")
            (,(build-json-response *dataset*)))))

(defun handle-compression (env)
  (declare (ignore env))
  (if (null *json-large-compressed*)
      '(200 (:content-type "application/json" :server "woo" :content-encoding "gzip") ("{}"))
      `(200 (:content-type "application/json" :server "woo" :content-encoding "gzip")
            (,*json-large-compressed*))))

(defun handle-upload (env)
  `(200 (:content-type "text/plain" :server "woo")
        (,(princ-to-string (read-body-length env)))))

(defun handle-db (env)
  (if (null *db*)
      '(500 (:content-type "text/plain") ("DB not available"))
      (let* ((query (getf env :query-string))
             (min-s (get-query-param query "min"))
             (max-s (get-query-param query "max"))
             (min-price (if min-s (safe-parse-float min-s 10.0d0) 10.0d0))
             (max-price (if max-s (safe-parse-float max-s 50.0d0) 50.0d0)))
        (let ((rows (sqlite:execute-to-list *db*
                      "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50"
                      min-price max-price))
              (items '()))
          (dolist (row rows)
            (destructuring-bind (id name category price quantity active tags-str rscore rcount) row
              (let ((tags (handler-case
                              (let ((p (jonathan:parse tags-str)))
                                (if (listp p) (coerce p 'vector) #()))
                            (error () #()))))
                (push `(("id" . ,id) ("name" . ,name) ("category" . ,category)
                        ("price" . ,price) ("quantity" . ,quantity)
                        ("active" . ,(if (= active 1) :true :false))
                        ("tags" . ,tags)
                        ("rating" . (("score" . ,rscore) ("count" . ,rcount))))
                      items))))
          (let ((items (nreverse items)))
            `(200 (:content-type "application/json" :server "woo")
                  (,(jonathan:to-json
                     `(("items" . ,(coerce items 'vector))
                       ("count" . ,(length items)))))))))))

(defun handle-static (env filename)
  (declare (ignore env))
  (let ((entry (gethash filename *static-files*)))
    (if entry
        `(200 (:content-type ,(car entry) :server "woo") (,(cdr entry)))
        '(404 (:content-type "text/plain") ("Not Found")))))

;;; ---------------------------------------------------------------------------
;;; Router
;;; ---------------------------------------------------------------------------

(defun route-request (env)
  (handler-case
      (let ((path (getf env :path-info)))
        (cond
          ((string= path "/pipeline")   (handle-pipeline env))
          ((string= path "/baseline11") (handle-baseline11 env))
          ((string= path "/baseline2")  (handle-baseline2 env))
          ((string= path "/json")       (handle-json env))
          ((string= path "/compression")(handle-compression env))
          ((string= path "/upload")     (handle-upload env))
          ((string= path "/db")         (handle-db env))
          ((and (>= (length path) 9) (string= (subseq path 0 8) "/static/"))
           (handle-static env (subseq path 8)))
          (t '(404 (:content-type "text/plain") ("Not Found")))))
    (error (c)
      (format *error-output* "[woo] Error: ~A~%" c)
      '(500 (:content-type "text/plain") ("Internal Server Error")))))

;;; ---------------------------------------------------------------------------
;;; Entry point
;;; ---------------------------------------------------------------------------

(defun main ()
  (format t "~&[woo] Loading dataset...~%") (force-output)
  (load-dataset)
  (format t "[woo] Dataset: ~A items~%" (length *dataset*)) (force-output)
  (load-dataset-large)
  (format t "[woo] Large dataset compressed: ~A bytes~%"
          (if *json-large-compressed* (length *json-large-compressed*) 0))
  (force-output)
  (load-static-files)
  (format t "[woo] Static files: ~A~%" (hash-table-count *static-files*)) (force-output)
  (load-db)
  (format t "[woo] DB: ~A~%" (if *db* "loaded" "not available")) (force-output)
  (let ((workers (get-cpu-count)))
    (format t "[woo] Starting on :8080 with ~A workers~%" workers) (force-output)
    (woo:run #'route-request
             :port 8080
             :address "0.0.0.0"
             :worker-num workers
             :debug nil)))
