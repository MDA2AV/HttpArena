// The arena app, built inside the Ktor fork's own build: the Dockerfile puts this directory at the fork's root as
// :httparena-ktor-kronos, so the engine and Ktor come in as the fork's projects, at the fork's commit.
plugins {
    id("ktorbuild.project.internal")
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
        }
    }
}
