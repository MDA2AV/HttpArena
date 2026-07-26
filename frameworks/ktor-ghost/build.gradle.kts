plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(ktorLibs.plugins.ktor)
    alias(libs.plugins.kotlin.ksp)
}

group = "com.httparena"
version = "1.0.0"

application {
    mainClass = "com.httparena.ApplicationKt"
}

dependencies {
    implementation(ktorLibs.server.core)
    implementation(ktorLibs.server.netty)
    implementation(ktorLibs.server.compression)
    implementation(ktorLibs.server.defaultHeaders)
    implementation(ktorLibs.server.contentNegotiation)
    implementation(ktorLibs.serialization.kotlinx.json)
    implementation(ktorLibs.server.websockets)
    implementation(ktorLibs.server.htmlBuilder)

    implementation(libs.ghost.serialization)
    ksp(libs.ghost.compiler)

    implementation(libs.exposed.core)
    implementation(libs.exposed.jdbc)
    implementation(libs.exposed.json)
    implementation(libs.logback.classic)
    implementation(libs.postgresql)
    implementation(libs.hikaricp)
    runtimeOnly(libs.netty.native.epoll)

    testImplementation(kotlin("test"))
    testImplementation(ktorLibs.server.testHost)
}

ktor {
    fatJar {
        archiveFileName.set("ktor-ghost-httparena.jar")
    }
}

kotlin {
    jvmToolchain(21)
}
