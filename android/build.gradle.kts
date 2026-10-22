subprojects {
    // Plugins disagree about compileSdk: some hardcode an old level (file_picker
    // 8.3.7 pinned 34, which is why this hook exists) while their own
    // dependencies require 36+ (flutter_plugin_android_lifecycle follows
    // flutter.compileSdkVersion, 36 on this SDK). The AAR metadata check then
    // fails the whole build. Force every Android module up to the app's level —
    // compileSdk only affects build-time APIs; targetSdk and minSdk stay
    // whatever each module chose. Kept after file_picker was dropped: the next
    // plugin with a stale pin should not cost another debugging session.
    //
    // Must stay ABOVE the evaluationDependsOn(":app") block below: that block
    // force-evaluates :app, and afterEvaluate cannot be registered for an
    // already-evaluated project.
    afterEvaluate {
        val android = extensions.findByName("android") ?: return@afterEvaluate
        // BaseExtension#setCompileSdkVersion(int) — called by reflection so the
        // root script needs no AGP import (the plugin lives in the settings
        // plugins block and is not on this script's compile classpath).
        try {
            android.javaClass
                .getMethod("setCompileSdkVersion", Integer.TYPE)
                .invoke(android, 36)
        } catch (_: Exception) {
            // Not an Android module with a settable compileSdkVersion.
        }
    }
}

allprojects {
    repositories {
        // China-friendly mirrors first: Maven Central / Google Maven are often
        // unreachable or flaky from mainland networks, and a 5xx from them is a
        // hard failure (not a "try the next repo"). Safe to delete these two
        // lines outside China — the official repos below still cover you.
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
        google()
        mavenCentral()
    }
}

subprojects {
    // Plugin projects (e.g. git2dart_binaries) declare their own
    // `buildscript { repositories { google(); mavenCentral() } }`. Registering
    // the mirrors here — before those scripts are evaluated — keeps their
    // classpath resolution off the flaky official hosts as well.
    project.buildscript.repositories.apply {
        maven("https://maven.aliyun.com/repository/google")
        maven("https://maven.aliyun.com/repository/public")
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
