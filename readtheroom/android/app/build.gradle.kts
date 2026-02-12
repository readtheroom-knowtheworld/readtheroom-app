import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Load key.properties from the android/ directory (optional for F-Droid builds)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.readtheroom.app"
    compileSdk = 35
    ndkVersion = "27.0.12077973"

    defaultConfig {
        applicationId = "com.readtheroom.app"
        minSdk = 21
        targetSdk = 35
        versionCode = 77               // 🔧 Must increase with every new Play Store upload
        versionName = "1.1.4"   // Recommended for user-facing clarity
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    if (keystorePropertiesFile.exists()) {
        signingConfigs {
            create("release") {
                val storeFilePath = keystoreProperties["storeFile"] as String?
                    ?: throw GradleException("Missing 'storeFile' in key.properties")
                keyAlias = keystoreProperties["keyAlias"] as String?
                    ?: throw GradleException("Missing 'keyAlias' in key.properties")
                keyPassword = keystoreProperties["keyPassword"] as String?
                    ?: throw GradleException("Missing 'keyPassword' in key.properties")
                storePassword = keystoreProperties["storePassword"] as String?
                    ?: throw GradleException("Missing 'storePassword' in key.properties")
                storeFile = file(storeFilePath)
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packagingOptions {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ✅ Updated to meet plugin requirements
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
