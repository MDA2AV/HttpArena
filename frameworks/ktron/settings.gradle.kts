pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "ktron-arena"

// Ktron and its runtime, from source: the Dockerfile puts the Ktron repo at /deps/ktron and the Kotlin port of
// ioxide at /deps/ioxide; -Pdeps=<dir> points a local build at another such tree.
val deps = providers.gradleProperty("deps").getOrElse("/deps")
include(":ktron", ":glyph11", ":ioxide")
project(":ktron").projectDir = file("$deps/ktron/ktron")
project(":glyph11").projectDir = file("$deps/ktron/glyph11")
project(":ioxide").projectDir = file("$deps/ioxide")
