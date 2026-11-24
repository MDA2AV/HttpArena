ThisBuild / scalaVersion := "3.10.0"

lazy val root = (project in file("."))
  .settings(
    name := "httparena-sharaf",
    resolvers += "Sonatype Central Snapshots" at "https://central.sonatype.com/repository/maven-snapshots/",
    dependencyOverrides += "ba.sake" %% "potateh" % "0.6.1-SNAPSHOT",
    libraryDependencies ++= Seq(
      "ba.sake" %% "sharaf-potateh" % "0.24.1-SNAPSHOT",
      "ba.sake" %% "squery" % "0.13.0",
      "com.zaxxer" % "HikariCP" % "7.1.0",
      "org.postgresql" % "postgresql" % "42.7.14"
    ),
    assembly / mainClass := Some("Main"),
    assembly / assemblyOutputPath := baseDirectory.value / "target" / "app.jar",
    assembly / assemblyMergeStrategy := {
      case PathList("META-INF", "services", _*) => MergeStrategy.concat
      case PathList("META-INF", _*)             => MergeStrategy.discard
      case _                                    => MergeStrategy.first
    }
  )
