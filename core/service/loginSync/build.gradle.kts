import com.android.build.gradle.internal.tasks.CompileArtProfileTask

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.android.kotlin.multiplatform.library)
    alias(libs.plugins.android.lint)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    android {
        namespace = "org.simpmusic.loginsync"
        compileSdk = 37
        minSdk = 26
    }

    // Android sends, Desktop receives, and iOS does both (shows a QR for an Android phone, or scans
    // a computer's). The cipher is javax.crypto on Android/JVM and CommonCrypto on iOS.
    jvm()
    iosArm64()
    iosSimulatorArm64()

    sourceSets {
        commonMain {
            dependencies {
                implementation(libs.kotlin.stdlib)
                implementation(libs.kotlinx.serialization.json)
                // Transport: ktorExt carries `api(ktor-client-core)` and the per-platform engine, the
                // same route listenTogether and kizzy take, so the engine choice stays in one place.
                implementation(projects.ktorExt)
                // Logger.
                implementation(projects.common)
            }
        }

        val jvmAndroidMain by creating { dependsOn(commonMain.get()) }
        androidMain.get().dependsOn(jvmAndroidMain)
        jvmMain {
            dependsOn(jvmAndroidMain)
            dependencies {
                // Only the Desktop and iOS host a server; the APK never ships these.
                implementation(libs.ktor.server.core)
                implementation(libs.ktor.server.cio)
            }
        }
        // A custom dependsOn turns the default hierarchy off, so the iOS set is wired by hand.
        val iosMain by creating {
            dependsOn(commonMain.get())
            dependencies {
                implementation(libs.ktor.server.core)
                implementation(libs.ktor.server.cio)
            }
        }
        getByName("iosArm64Main").dependsOn(iosMain)
        getByName("iosSimulatorArm64Main").dependsOn(iosMain)
        val iosTest by creating { dependsOn(commonTest.get()) }
        getByName("iosSimulatorArm64Test").dependsOn(iosTest)
        getByName("iosArm64Test").dependsOn(iosTest)

        commonTest {
            dependencies {
                implementation(libs.kotlin.test)
            }
        }
    }
}

tasks.withType<CompileArtProfileTask> {
    enabled = false
}
