(defproject aleph-bench "0.1.0"
  :description ""
  :url "https://github.com/clj-commons/aleph"
  :license {:name "EPL-2.0"
            :url  "https://www.eclipse.org/legal/epl-2.0/"}

  :dependencies [[org.clojure/clojure "1.12.0"]
                 [aleph "0.8.3" :exclusions [io.netty/netty-all
                                             io.netty/netty-buffer
                                             io.netty/netty-codec
                                             io.netty/netty-codec-http
                                             io.netty/netty-codec-http2
                                             io.netty/netty-codec-dns
                                             io.netty/netty-codec-haproxy
                                             io.netty/netty-common
                                             io.netty/netty-handler
                                             io.netty/netty-handler-proxy
                                             io.netty/netty-resolver
                                             io.netty/netty-resolver-dns
                                             io.netty/netty-transport
                                             io.netty/netty-transport-classes-epoll
                                             io.netty/netty-transport-classes-kqueue
                                             io.netty/netty-transport-native-epoll
                                             io.netty/netty-transport-native-kqueue
                                             io.netty/netty-transport-native-unix-common]]
                 [io.netty/netty-all "4.2.12.Final"]
                 [org.clojars.jj/tassu "1.0.4"]
                 [org.clojars.jj/boa-sql "1.0.10"]
                 [org.clojars.jj/async-boa-sql "1.0.10"]
                 [org.clojars.jj/next-jdbc-adapter "1.0.10"]
                 [org.clojars.jj/vertx-pg-client-async-boa-adapter "1.0.1"]
                 [metosin/jsonista "1.0.0"]

                 [org.clojure/core.cache "1.2.263"]]

  :main ^:skip-aot aleph-bench.core

  :source-paths ["src"]
  :test-paths ["test"]
  :aot :all
  :resource-paths ["resources"]
  )
