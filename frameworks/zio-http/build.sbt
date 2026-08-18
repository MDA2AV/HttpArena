ThisBuild / scalaVersion := "3.3.8"

lazy val root = (project in file("."))
  .settings(
    name := "httparena-zio-http",
    libraryDependencies ++= Seq(
      "dev.zio" %% "zio-http" % "3.11.3",
      "dev.zio" %% "zio-json" % "0.9.1"
    ),
    assembly / mainClass := Some("Main"),
    assembly / assemblyMergeStrategy := {
      // Netty ships its epoll transport as a native library under META-INF/native,
      // so that tree has to survive the merge or the server falls back to NIO.
      case PathList("META-INF", "native", _*)   => MergeStrategy.first
      case PathList("META-INF", "services", _*) => MergeStrategy.concat
      case PathList("META-INF", _*)             => MergeStrategy.discard
      case _                                    => MergeStrategy.first
    }
  )
