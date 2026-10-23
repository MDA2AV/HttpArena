plugins {
    kotlin("jvm") version "2.4.21"
    application
}

dependencies {
    implementation("org.genhttp:genhttp-core:11.1.0.2")
    implementation("org.genhttp:genhttp-modules-files:11.1.0.2")
    implementation("org.genhttp:genhttp-modules-webservices:11.1.0.2")
    implementation("org.genhttp:genhttp-modules-websockets:11.1.0.2")

    implementation("com.zaxxer:HikariCP:7.1.0")
    implementation("org.postgresql:postgresql:42.7.14")

    // binds SLF4J to a no-op logger so neither GenHTTP nor HikariCP log anything
    runtimeOnly("org.slf4j:slf4j-nop:2.0.20")
}

kotlin {
    jvmToolchain(25)
}

application {
    mainClass = "genhttp.ProgramKt"
}
