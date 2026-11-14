import scala.scalanative.build.Mode

ThisBuild / scalaVersion := "3.10.0"

lazy val root = (project in file("."))
  .enablePlugins(ScalaNativePlugin)
  .settings(
    name := "server",
    Compile / mainClass := Some("Main"),
    Compile / crossTarget := baseDirectory.value / "target" / "native",
    scalacOptions ++= Seq("-release:21", "-Yretain-trees"),
    nativeConfig ~= { config =>
      config
        .withMode(Mode.releaseFull)
        .withMultithreading(true)
    },
    libraryDependencies += "ba.sake" %%% "sharaf-potateh" % "0.22.0"
  )
