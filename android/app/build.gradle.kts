plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
  id("org.jetbrains.kotlin.plugin.compose")
  id("org.jetbrains.kotlin.plugin.serialization")
  id("com.google.devtools.ksp")
}

android {
  namespace = "so.dayflow.capture"
  compileSdk = 35

  defaultConfig {
    applicationId = "so.dayflow.capture"
    minSdk = 35
    targetSdk = 35
    versionCode = 1
    versionName = "0.1.0"

    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    vectorDrawables.useSupportLibrary = true
  }

  buildTypes {
    release {
      isMinifyEnabled = true
      proguardFiles(
        getDefaultProguardFile("proguard-android-optimize.txt"),
        "proguard-rules.pro"
      )
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions.jvmTarget = "17"
  buildFeatures.compose = true
  packaging.resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
}

dependencies {
  val composeBom = platform("androidx.compose:compose-bom:2025.05.01")
  implementation(composeBom)
  androidTestImplementation(composeBom)

  implementation("androidx.activity:activity-compose:1.10.1")
  implementation("androidx.compose.material3:material3")
  implementation("androidx.compose.material:material-icons-extended")
  implementation("androidx.compose.ui:ui")
  implementation("androidx.compose.ui:ui-tooling-preview")
  debugImplementation("androidx.compose.ui:ui-tooling")

  implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
  implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
  implementation("androidx.lifecycle:lifecycle-service:2.9.0")
  implementation("androidx.lifecycle:lifecycle-process:2.9.0")

  implementation("androidx.room:room-runtime:2.7.1")
  implementation("androidx.room:room-ktx:2.7.1")
  ksp("androidx.room:room-compiler:2.7.1")
  implementation("androidx.work:work-runtime-ktx:2.10.1")

  implementation("androidx.camera:camera-camera2:1.4.2")
  implementation("androidx.camera:camera-lifecycle:1.4.2")
  implementation("androidx.camera:camera-view:1.4.2")
  implementation("com.google.mlkit:barcode-scanning:17.3.0")

  implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
  implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.1")

  testImplementation("junit:junit:4.13.2")
  androidTestImplementation("androidx.test.ext:junit:1.2.1")
  androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
  androidTestImplementation("androidx.compose.ui:ui-test-junit4")
  debugImplementation("androidx.compose.ui:ui-test-manifest")
}
