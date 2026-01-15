# Flutter Local Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Keep generic signatures (VERY IMPORTANT)
-keepattributes Signature
-keepattributes *Annotation*

# Firebase safety (recommended)
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
