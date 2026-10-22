# R8 configuration for release builds.
#
# AGP 9 runs R8 on release builds. Without this file, R8 also *renames* classes
# and rewrites method descriptors, which breaks two things in this app:
#
#   1. Pigeon's `suspend` methods: `getAll(String, List, Continuation)` becomes
#      `getAll(String, List, v4)` because `kotlin.coroutines.Continuation` is
#      renamed, while the runtime still looks the method up by its original
#      descriptor -> NoSuchMethodError.
#   2. kotlinx-coroutines internals that are referenced by name
#      (`kotlin/coroutines/intrinsics/CoroutineSingletons`) ->
#      ClassNotFoundException.
#
# Turning obfuscation off keeps every name and descriptor as compiled, while
# R8 still shrinks and optimizes the (thin) Java/Kotlin layer. The Dart code is
# AOT-compiled separately, so nothing of value is lost here.

-dontobfuscate

-keep class kotlin.coroutines.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class dev.flutter.pigeon.** { *; }

-dontwarn io.flutter.plugins.**
-dontwarn kotlinx.coroutines.**
