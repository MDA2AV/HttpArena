threads ENV.fetch("MAX_THREADS", 4).to_i
max_io_threads ENV.fetch("MAX_IO_THREADS", 10).to_i

bind "tcp://0.0.0.0:8080"

preload_app!
