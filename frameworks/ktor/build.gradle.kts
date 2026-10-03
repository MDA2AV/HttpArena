plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ktor)
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

    implementation(libs.exposed.core)
    implementation(libs.exposed.jdbc)
    implementation(libs.exposed.json)
    implementation(libs.logback.classic)
    implementation(libs.postgresql)
    implementation(libs.hikaricp)
    runtimeOnly(variantOf(libs.netty.native.epoll) { classifier("linux-aarch_64") })
    runtimeOnly(variantOf(libs.netty.native.openssl) { classifier("linux-aarch_64") })

    testImplementation(kotlin("test"))
    testImplementation(ktorLibs.server.testHost)
}

ktor {
    fatJar {
        archiveFileName.set("ktor-httparena.jar")
    }
}

kotlin {
    jvmToolchain(25)
}
