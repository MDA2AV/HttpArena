// The arena app, built inside the Ktor fork's own build: the Dockerfile puts this directory at the fork's root as
// :ktor-httparena-kronos, so the engine and Ktor come in as the fork's projects, at the fork's commit. Its sources are
// all under linux/, so Ktor's build gives it the Linux targets only.
plugins {
    id("ktorbuild.project.internal")
    id("kotlinx-serialization")
}

kotlin {
    linuxX64 {
        binaries.executable {
            baseName = "ktor-kronos"
            entryPoint = "httparena.main"
        }
    }

    sourceSets {
        linuxMain.dependencies {
            implementation(projects.ktorServerKron)
            implementation(projects.ktorServerWebsockets)
            implementation(projects.ktorServerContentNegotiation)
            implementation(projects.ktorSerializationKotlinxJson)
        }
    }
}
