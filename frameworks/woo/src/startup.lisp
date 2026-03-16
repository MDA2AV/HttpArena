;;; Startup wrapper for save-lisp-and-die image.
;;; Explicitly loads foreign libraries before calling main,
;;; working around CFFI handle staleness after core restore.

(defpackage :httparena-startup
  (:use :cl))

(in-package :httparena-startup)

(defun toplevel ()
  ;; Force-load foreign libraries that CFFI needs.
  ;; These are the shared objects that woo/sqlite/salza2 depend on.
  (handler-case
      (progn
        ;; Try CFFI's official reload mechanism first
        (cffi:reload-foreign-libraries)
        (format *error-output* "[startup] Foreign libraries reloaded~%")
        (force-output *error-output*))
    (error (c)
      (format *error-output* "[startup] cffi:reload-foreign-libraries failed: ~A~%" c)
      (force-output *error-output*)
      ;; Manual fallback: load the specific libraries we need
      (handler-case
          (progn
            (cffi:load-foreign-library "libev.so")
            (format *error-output* "[startup] libev loaded manually~%")
            (force-output *error-output*))
        (error (c2)
          (format *error-output* "[startup] WARNING: Could not load libev: ~A~%" c2)
          (force-output *error-output*)))))
  ;; Now start the server
  (httparena::main))
