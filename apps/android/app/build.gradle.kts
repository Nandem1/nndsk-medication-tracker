plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.compose.compiler)
  alias(libs.plugins.kotlin.serialization)
  id("com.google.devtools.ksp") version "2.3.13"
}

android {
  namespace = "cl.nndsk.medication"
  compileSdk = 37
  defaultConfig {
    applicationId = "cl.nndsk.medication"
    minSdk = 26
    targetSdk = 37
    versionCode = 1
    versionName = "0.5.0"
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    fun config(name: String, fallback: String) = providers.gradleProperty(name).orElse(fallback).get()
    buildConfigField("String", "API_BASE_URL", "\"${config("apiBaseUrl", "https://example.invalid")}\"")
    buildConfigField("String", "FIREBASE_API_KEY", "\"${config("firebaseApiKey", "configure-me")}\"")
    buildConfigField("String", "AUTH_EMULATOR", "\"${config("authEmulator", "")}\"")
  }

  testBuildType = providers.gradleProperty("testBuildType").orElse("debug").get()
  buildTypes {
    debug { applicationIdSuffix = ".debug" }
    create("e2e") {
      initWith(getByName("debug"))
      applicationIdSuffix = ".e2e"
      matchingFallbacks += "debug"
      buildConfigField("String", "API_BASE_URL", "\"http://127.0.0.1:18084\"")
      buildConfigField("String", "FIREBASE_API_KEY", "\"e2e-public-placeholder\"")
      buildConfigField("String", "AUTH_EMULATOR", "\"http://127.0.0.1:9099\"")
    }
    release {
      isMinifyEnabled = false
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
    }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  buildFeatures {
    compose = true
    aidl = false
    buildConfig = true
    shaders = false
  }

  packaging {
    resources {
      excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
  }
}

kotlin {
  jvmToolchain(21)
}

dependencies {
  val composeBom = platform(libs.androidx.compose.bom)
  implementation(composeBom)
  androidTestImplementation(composeBom)

  // Core Android dependencies
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.lifecycle.runtime.ktx)
  implementation(libs.androidx.activity.compose)

  // Arch Components
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.viewmodel.compose)

  // Compose
  implementation(libs.androidx.compose.ui)
  implementation(libs.androidx.compose.ui.tooling.preview)
  implementation(libs.androidx.compose.material3)
  // Tooling
  debugImplementation(libs.androidx.compose.ui.tooling)
  // Instrumented tests
  androidTestImplementation(libs.androidx.compose.ui.test.junit4)
  debugImplementation(libs.androidx.compose.ui.test.manifest)

  // Local tests: jUnit, coroutines, Android runner
  testImplementation(libs.junit)
  testImplementation(libs.kotlinx.coroutines.test)

  // Instrumented tests: jUnit rules and runners
  androidTestImplementation(libs.androidx.test.core)
  androidTestImplementation(libs.androidx.test.ext.junit)
  androidTestImplementation(libs.androidx.test.runner)
  androidTestImplementation(libs.androidx.test.espresso.core)

  // Navigation
  implementation(libs.androidx.navigation3.ui)
  implementation(libs.androidx.navigation3.runtime)
}

ksp { arg("room.schemaLocation", "$projectDir/schemas") }
dependencies {
  implementation("androidx.room:room-runtime:2.8.5")
  implementation("androidx.room:room-ktx:2.8.5")
  ksp("androidx.room:room-compiler:2.8.5")
  implementation("com.squareup.retrofit2:retrofit:3.0.0")
  implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
}

dependencyLocking { lockAllConfigurations() }
