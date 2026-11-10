plugins {
  kotlin("jvm") version "2.4.20"
  id("gg.jte.gradle") version "3.2.5"
  application
}

repositories {
  mavenCentral()
  maven { url = uri("https://jitpack.io") }
}

dependencies {
  val kliteVersion = "2.1.1"
  fun klite(module: String) = "com.github.keksworks.klite:klite-$module:$kliteVersion"
  implementation(klite("server"))
  implementation(klite("json"))
  implementation(klite("jdbc"))
  implementation(klite("slf4j"))
  implementation("org.postgresql:postgresql:42.7.14")

  implementation("gg.jte:jte:3.2.5")
  compileOnly("gg.jte:jte-kotlin:3.2.5")
}

// Klite's preferred flat layout: sources in src/, templates in templates/
sourceSets {
  main {
    kotlin.srcDirs("src")
  }
}

jte {
  sourceDirectory = file("templates").toPath()
  generate()
}

kotlin {
  jvmToolchain(25)
}

application {
  mainClass = "LauncherKt"
}
