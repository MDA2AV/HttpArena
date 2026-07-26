plugins {
    kotlin("jvm") version "2.1.20"
    kotlin("plugin.serialization") version "2.1.20"
    application
    id("com.gradleup.shadow") version "8.3.5"
}

group = "com.httparena.fishcake"
version = "1.0.0"

repositories {
    mavenCentral()
}

dependencies {
    // CodeGreen modules (substituted from the included build by group:name).
    implementation("org.codegreen:internal:0.1.0")   // engine:internal — Host
    implementation("org.codegreen:api:0.1.0")
    implementation("org.codegreen:io:0.1.0")
    implementation("org.codegreen:layouting:0.1.0")
    implementation("org.codegreen:webservices:0.1.0")
    implementation("org.codegreen:reflection:0.1.0")
    implementation("org.codegreen:conversion:0.1.0")

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.1")

    // Postgres for the async-db / crud profiles, queried directly (as genhttp-11 uses Npgsql).
    implementation("org.postgresql:postgresql:42.7.4")
    implementation("com.zaxxer:HikariCP:6.2.1")
}

application {
    mainClass.set("com.httparena.fishcake.MainKt")
}

kotlin {
    jvmToolchain(21)
}

tasks.shadowJar {
    archiveFileName.set("fishcake.jar")
    mergeServiceFiles()
}
