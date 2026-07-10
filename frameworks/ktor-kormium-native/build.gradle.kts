plugins {
    kotlin("multiplatform") version "2.4.0"
    kotlin("plugin.serialization") version "2.4.0"
}

group = "com.httparena"
version = "1.0.0"

kotlin {
    // linuxX64 is the arena target (built inside the Dockerfile); macosArm64 exists
    // only so the app can be compiled and smoke-tested on a dev Mac.
    listOf(linuxX64(), macosArm64()).forEach { target ->
        target.binaries.executable {
            entryPoint = "com.httparena.main"
        }
    }

    sourceSets {
        nativeMain.dependencies {
            implementation(ktorLibs.server.core)
            implementation(ktorLibs.server.cio)
            implementation(ktorLibs.server.contentNegotiation)
            implementation(ktorLibs.serialization.kotlinx.json)
            implementation(ktorLibs.server.htmlBuilder)

            implementation("io.github.kormium:kormium-postgres:0.9.1")
        }
    }
}
