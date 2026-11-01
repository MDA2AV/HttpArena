// The arena app, built as a project of the Ktor fork's own build (the Dockerfile adds it as :ktor-httparena-kronos), so
// the engine and Ktor come in at the fork's commit. Its sources are under linux/ only, which makes it a Linux-only project.
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
