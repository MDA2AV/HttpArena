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

    sourceSets {
        all {
            languageSettings {
                optIn("kotlinx.cinterop.ExperimentalForeignApi")
                optIn("kotlin.experimental.ExperimentalNativeApi")
            }
        }
        nativeMain.dependencies {
            implementation("kron:kron")
        }
    }
}
