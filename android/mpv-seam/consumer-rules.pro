# The native glue resolves the MpvSeam dispatcher methods by NAME from C++
# (JNIEnv::GetMethodID in jni_utils.cpp: eventProperty*, eventEndFile, event, logMessage). Any
# future R8 pass must not rename or remove them, or every mpv callback would die with a JNI
# NoSuchMethodError. Mirrors upstream libmpv-android's own consumer rule.
-keep class com.vortx.android.player.mpv.seam.MpvSeam { *; }
