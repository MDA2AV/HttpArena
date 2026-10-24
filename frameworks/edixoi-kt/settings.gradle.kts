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

rootProject.name = "edixoi-kt"

// The Kotlin port of ioxide, from the ioxide repo's kotlin/ioxide: the Dockerfile puts it at /ioxide-kt/ioxide,
// and -PioxideKt=<dir> points a local build at a checkout.
include(":ioxide")
project(":ioxide").projectDir = file(providers.gradleProperty("ioxideKt").getOrElse("/ioxide-kt/ioxide"))
