plugins {
    kotlin("multiplatform") version "2.4.20-RC3"
    kotlin("plugin.serialization") version "2.4.20-RC3"
}

repositories {
    mavenCentral()
}

// One published coordinate. `neton` brings core + logging + http + routing and
// the hyper4k engine, so the arena entry builds from Maven exactly like any
// other application would — no source checkout, no composite build.
val netonVersion = "1.0.0-beta7"

kotlin {
    // The arena builds linuxX64; macosArm64 is here so the endpoints can be
    // exercised on a developer machine.
    listOf(macosArm64(), linuxX64(), linuxArm64()).forEach { target ->
        target.binaries.executable { entryPoint = "main" }
    }

    sourceSets {
        // This entry drives the engine adapter directly for its second listener
        // (:8082), and that adapter is native-only, so the code lives in
        // nativeMain rather than commonMain.
        val nativeMain by creating {
            dependsOn(commonMain.get())
            dependencies {
                implementation("com.netonstream:neton:$netonVersion")
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
