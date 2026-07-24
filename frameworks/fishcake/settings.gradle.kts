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

rootProject.name = "fishcake"

// CodeGreen — the Kotlin port of GenHTTP — is consumed as a Gradle composite build.
// In Docker it is cloned to ./codegreen (see Dockerfile); locally, point at a checkout
// with `-PcodegreenDir=/path/to/CodeGreen`.
val codegreenDir = startParameter.projectProperties["codegreenDir"] ?: "codegreen"
includeBuild(codegreenDir)
