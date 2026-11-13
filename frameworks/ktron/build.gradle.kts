plugins {
    kotlin("jvm") version "2.4.21"
    id("com.google.devtools.ksp") version "2.3.12"
    application
}

dependencies {
    implementation(project(":ktron"))
    ksp("com.ghostserializer:ghost-compiler:1.3.5")
}

kotlin {
    jvmToolchain(25)
}

application {
    mainClass = "arena.MainKt"
}
