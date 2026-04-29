(defproject ring "0.1.0"
  :description ""
  :url "https://github.com/ruroru/ring-http-exchange"
  :license {:name "EPL-2.0"
            :url  "https://www.eclipse.org/legal/epl-2.0/"}

  :dependencies [[org.clojure/clojure "1.12.0"]
                 [org.clojars.jj/ring-http-exchange "1.4.4"]
                 [org.clojars.jj/tassu "1.0.4"]
                 [org.clojars.jj/boa-sql "1.0.10"]
                 [org.clojars.jj/next-jdbc-adapter "1.0.10"]
                 [org.postgresql/postgresql "42.7.5"]
                 [metosin/jsonista "1.0.0"]
                 [com.zaxxer/HikariCP "6.2.1"]
                 [io.github.robaho/httpserver "1.0.29"]
                 [com.github.seancorfield/next.jdbc "1.3.1093"]
                 [org.clojure/core.cache "1.2.263"]]

  :main ^:skip-aot ring.core

  :source-paths ["src"]
  :test-paths ["test"]
  :aot :all
  :resource-paths ["resources"]
  )
