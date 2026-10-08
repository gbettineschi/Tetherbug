plugins {
    id("com.android.application") version "9.4.1"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20"
    id("io.github.takahirom.roborazzi") version "1.76.0"
}

// Release signing comes from the environment (CI decodes the keystore from repo secrets); without
// it, release builds fall back to the debug key so they still build locally.
val releaseKeystore: String? = System.getenv("TETHER_KEYSTORE")

android {
    namespace = "ie.xav.tetherbug"
    compileSdk = 37

    defaultConfig {
        applicationId = "ie.xav.tetherbug"
        // SoftApConfiguration.Builder#setVendorElements is Android 13+.
        minSdk = 33
        targetSdk = 37
        // Set from the release tag in CI: -PversionName=0.1.0 -PversionCode=100.
        versionCode = (findProperty("versionCode") as String?)?.toInt() ?: 1
        versionName = findProperty("versionName") as String? ?: "0.0.0-dev"
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("TETHER_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("TETHER_KEY_ALIAS")
                keyPassword = System.getenv("TETHER_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
    }

    // The store screenshots render on the JVM (Robolectric); see ScreenshotTest.
    testOptions {
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            it.systemProperty("robolectric.pixelCopyRenderMode", "hardware")
            // Robolectric's Android 16 runtime reaches into the JDK's file descriptors.
            it.jvmArgs("--add-opens=java.base/jdk.internal.access=ALL-UNNAMED")
            // So Gradle reruns the screenshots when they're deleted or edited.
            it.outputs.dir("../assets/store/android")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3:1.5.0-alpha24")
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    implementation("org.lsposed.hiddenapibypass:hiddenapibypass:6.1")

    testImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.76.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
}
