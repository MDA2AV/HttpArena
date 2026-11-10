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

rootProject.name = "kron-arena"

// kron, from its repo at a pinned commit: the Dockerfile puts it at /kron, and -Pkron=<dir> points a local build at a
// checkout. A composite build, so kron's build finds its BoringSSL (native/) under its own root, as it expects.
includeBuild(providers.gradleProperty("kron").getOrElse("/kron")) {
    dependencySubstitution {
        substitute(module("kron:kron")).using(project(":kron"))
    }
}
