ThisBuild / scalaVersion := "3.3.8"

lazy val root = (project in file("."))
  .settings(
    name := "httparena-http4s",
    libraryDependencies ++= Seq(
      "org.http4s" %% "http4s-ember-server" % "0.23.36",
      "org.http4s" %% "http4s-dsl" % "0.23.36",
      "org.http4s" %% "http4s-circe" % "0.23.36",
      "io.circe" %% "circe-parser" % "0.14.16"
    ),
    assembly / mainClass := Some("Main"),
    assembly / assemblyMergeStrategy := {
      case PathList("META-INF", _*) => MergeStrategy.discard
      case _                        => MergeStrategy.first
    }
  )
