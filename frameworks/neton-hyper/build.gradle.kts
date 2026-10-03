plugins {
    kotlin("multiplatform") version "2.4.0"
    kotlin("plugin.serialization") version "2.4.0"
}

repositories {
    mavenCentral()
}

// Same framework release and business path in both entries; only the engine differs.
// All dependencies resolve from Maven Central, without local repositories or source substitution.
val netonVersion = "1.0.0-beta22"

kotlin {
    // The arena builds linuxX64; macosArm64 is here so the endpoints can be
    // exercised on a developer machine.
    listOf(macosArm64(), linuxX64(), linuxArm64()).forEach { target ->
        target.binaries.executable {
            entryPoint = "main"
            // Preserve the existing Linux link policy in both entries for this comparison.
            // The Hyper4k entry links Rust-backed engine and database static libraries.
            if (target.konanTarget.family == org.jetbrains.kotlin.konan.target.Family.LINUX) {
                linkerOpts("--allow-multiple-definition")
            }
        }
    }

    sourceSets {
        // This entry drives the engine adapter directly for its second listener
        // (:8082), and that adapter is native-only, so the code lives in
        // nativeMain rather than commonMain.
        val nativeMain by creating {
            dependsOn(commonMain.get())
            dependencies {
                implementation("com.netonstream:neton-core:$netonVersion")
                implementation("com.netonstream:neton-logging:$netonVersion")
                implementation("com.netonstream:neton-http:$netonVersion")
                implementation("com.netonstream:neton-routing:$netonVersion")
                implementation("com.netonstream:neton-http-hyper4k:$netonVersion")
                // async-db / fortunes: async Postgres via sqlx4k.
                implementation("com.netonstream:neton-database:$netonVersion")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
                // Encoding straight into a byte buffer, rather than to a String the
                // response layer then re-encodes, is worth about 18% of the JSON
                // path at the item counts this profile uses. Same serializer, same
                // pipeline — only the intermediate String goes away.
                implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-io:1.11.0")
                implementation("org.jetbrains.kotlinx:kotlinx-io-core:0.9.0")
            }
        }
        macosArm64Main.get().dependsOn(nativeMain)
        linuxX64Main.get().dependsOn(nativeMain)
        linuxArm64Main.get().dependsOn(nativeMain)
    }
}
