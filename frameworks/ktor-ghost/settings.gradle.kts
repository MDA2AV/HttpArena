pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        maven("https://redirector.kotlinlang.org/maven/ktor-eap")
    }
    versionCatalogs {
        create("ktorLibs").from("io.ktor:ktor-version-catalog:3.6.0-http3-eap-1660")
    }
}

rootProject.name = "ktor-ghost-httparena"
