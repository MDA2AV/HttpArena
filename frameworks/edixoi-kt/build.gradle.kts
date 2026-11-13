plugins {
    kotlin("jvm") version "2.4.21"
    application
}

dependencies {
    implementation(project(":ioxide"))
}

kotlin {
    jvmToolchain(25)
}

application {
    mainClass = "edixoi.ProgramKt"
}
