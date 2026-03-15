;;; Build script — loads the server code and dumps an executable image.

(load "/app/src/server.lisp")

(sb-ext:save-lisp-and-die "/app/woo-server"
  :toplevel #'httparena::main
  :executable t
  :compression t)
