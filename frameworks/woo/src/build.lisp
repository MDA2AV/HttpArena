;; Build script: load everything, save a core image.
;; CFFI foreign libraries are automatically reloaded on core restore.

(ql:quickload '(:woo :jonathan :cl-ppcre :babel :salza2 :sqlite) :silent t)
(load "/app/src/server.lisp")

;; Save executable core. SBCL + CFFI will reopen shared libraries on restart.
(sb-ext:save-lisp-and-die "/app/woo-server"
  :toplevel #'httparena::main
  :executable t
  :save-runtime-options t)
