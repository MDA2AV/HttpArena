// The arena app, built as a project of the Ktor fork's own build (the Dockerfile adds it as :ktor-httparena-kronos), so
// the engine and Ktor come in at the fork's commit. Its sources are under jvm/ only, which makes it a JVM-only project.
plugins {
    id("ktorbuild.project.internal")
    id("kotlinx-serialization")
}

kotlin {
    // kron's jar is built for JDK 25
    jvmToolchain(25)

    sourceSets {
        jvmMain.dependencies {
            implementation(projects.ktorServerKron)
            implementation(projects.ktorServerWebsockets)
            implementation(projects.ktorServerContentNegotiation)
            implementation(projects.ktorServerCompression)
            implementation(projects.ktorSerializationKotlinxJson)
            implementation(libs.slf4j.simple)
        }
    }
}

// The transform would read kron's classes (JDK 25) on the build's own JVM (21); nothing here uses atomicfu.
atomicfu {
    transformJvm = false
}

// The app and everything it runs on in one jar.
tasks.register<Jar>("jvmFatJar") {
    archiveBaseName.set("ktor-kronos")
    archiveVersion.set("")
    manifest {
        attributes("Main-Class" to "httparena.MainKt", "Enable-Native-Access" to "ALL-UNNAMED")
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    val jvmJar = tasks.named<Jar>("jvmJar")
    dependsOn(jvmJar)
    from(jvmJar.map { zipTree(it.archiveFile) })
    from(configurations.named("jvmRuntimeClasspath").map { classpath -> classpath.map { if (it.isDirectory) it else zipTree(it) } })
    // A signed dependency's signature would not match the merged jar
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
}
