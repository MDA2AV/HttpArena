// The arena app, built inside the Ktor fork's own build: the Dockerfile puts this directory at the fork's root as
// :ktor-httparena-kronos, so the engine and Ktor come in as the fork's projects, at the fork's commit. It builds two
// ways from one source: the Kotlin/Native binary, and a jar for the JVM, where kron runs through FFM.
plugins {
    id("ktorbuild.project.internal")
    id("kotlinx-serialization")
}

kotlin {
    jvmToolchain(25)

    linuxX64 {
        binaries.executable {
            baseName = "ktor-kronos"
            entryPoint = "httparena.main"
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(projects.ktorServerKron)
            implementation(projects.ktorServerWebsockets)
            implementation(projects.ktorServerContentNegotiation)
            implementation(projects.ktorSerializationKotlinxJson)
        }
        jvmMain.dependencies {
            // Ktor's Compression, for json-comp: it exists only on the JVM
            implementation(projects.ktorServerCompression)
            // Ktor logs through SLF4J on the JVM: the simple provider prints what the native build prints
            implementation(libs.slf4j.simple)
        }
    }
}

// Nothing here uses atomicfu, and the transform would read kron's classes (JDK 25) on the build's own JVM (21).
atomicfu {
    transformJvm = false
}

// The JVM build: the app and everything it runs on in one jar.
tasks.register<Jar>("jvmFatJar") {
    group = "build"
    archiveBaseName.set("ktor-kronos")
    archiveVersion.set("")
    manifest {
        attributes("Main-Class" to "httparena.JvmMainKt", "Enable-Native-Access" to "ALL-UNNAMED")
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    val jvmJar = tasks.named<Jar>("jvmJar")
    dependsOn(jvmJar)
    from(jvmJar.map { zipTree(it.archiveFile) })
    from(configurations.named("jvmRuntimeClasspath").map { classpath -> classpath.map { if (it.isDirectory) it else zipTree(it) } })
    // A signed dependency's signature would not match the merged jar
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
}
