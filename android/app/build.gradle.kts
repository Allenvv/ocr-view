import java.security.MessageDigest
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lab.pm25_capture"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lab.pm25_capture"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}


dependencies {
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.22.0")
}

// Catch an incomplete package before Android can install a model-less APK.
val verifyBundledRec by tasks.registering {
    val modelAssets = layout.projectDirectory.dir("src/main/assets")
    val names = listOf("rec.onnx", "rec.json", "rec.dict.json", "rec-upstream.yml", "rec-LICENSE.txt")
    inputs.files(names.map { modelAssets.file(it) })
    doLast {
        val manifest = JsonSlurper().parse(modelAssets.file("rec.json").asFile) as Map<*, *>
        for ((name, key) in mapOf("rec.onnx" to "sha256", "rec.dict.json" to "dictionarySha256", "rec-upstream.yml" to "upstreamConfigSha256")) {
            val file = modelAssets.file(name).asFile
            val actual = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
            check(actual == manifest[key]) { "Bundled REC asset $name failed SHA-256 validation" }
        }
        check(modelAssets.file("rec-LICENSE.txt").asFile.length() > 0) { "Missing PaddleOCR model license" }
    }
}
tasks.named("preBuild") { dependsOn(verifyBundledRec) }
