plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    linuxX64 {
        binaries {
            executable {
                baseName = "kron-arena"
                entryPoint = "edixoi.main"
            }
        }
    }

    // The same app on the JVM, where kron reaches io_uring and BoringSSL through the FFM API: JDK 22 and up.
    jvm()
    jvmToolchain(25)

    sourceSets {
        matching { it.name.startsWith("native") || it.name.startsWith("linux") }.all {
            languageSettings {
                optIn("kotlinx.cinterop.ExperimentalForeignApi")
                optIn("kotlin.experimental.ExperimentalNativeApi")
            }
        }
        commonMain.dependencies {
            implementation("kron:kron")
        }
    }
}

// The JVM build: the app and everything it runs on in one jar, kron's BoringSSL among its resources.
tasks.register<Jar>("jvmFatJar") {
    group = "build"
    archiveBaseName.set("kron-arena")
    archiveVersion.set("")
    manifest {
        attributes("Main-Class" to "edixoi.MainKt", "Enable-Native-Access" to "ALL-UNNAMED")
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    val jvmJar = tasks.named<Jar>("jvmJar")
    val runtime = configurations.named("jvmRuntimeClasspath")
    dependsOn(jvmJar, runtime)
    from(jvmJar.map { zipTree(it.archiveFile) })
    from(runtime.map { classpath -> classpath.map { if (it.isDirectory) it else zipTree(it) } })
}
