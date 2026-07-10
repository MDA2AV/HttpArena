plugins {
    kotlin("jvm") version "2.4.0"
    kotlin("plugin.serialization") version "2.4.0"
    alias(ktorLibs.plugins.ktor)
}

group = "com.httparena"
version = "1.0.0"

application {
    mainClass = "com.httparena.ApplicationKt"
}

dependencies {
    implementation(ktorLibs.server.core)
    implementation(ktorLibs.server.netty)
    implementation(ktorLibs.server.contentNegotiation)
    implementation(ktorLibs.serialization.kotlinx.json)
    implementation(ktorLibs.server.htmlBuilder)

    implementation("io.github.kormium:kormium-postgres:0.9.1")
    implementation("ch.qos.logback:logback-classic:1.5.15")
    runtimeOnly("io.netty:netty-transport-native-epoll:4.2.14.Final")
}

ktor {
    fatJar {
        archiveFileName.set("ktor-kormium-httparena.jar")
    }
}

kotlin {
    jvmToolchain(21)
}
