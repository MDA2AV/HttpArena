;; Build script: load everything, save a core image.
;; No :compression — avoids decompression delay at startup.
;; LD_PRELOAD handles CFFI foreign library reload.

(ql:quickload '(:woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)
(load "/app/src/server.lisp")

(sb-ext:save-lisp-and-die "/app/woo-server"
  :toplevel #'httparena::main
  :executable t
  :save-runtime-options t)
