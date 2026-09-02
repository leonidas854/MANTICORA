# ---------------------------------------------------------------------------
#  Manticora - reglas de R8 para la compilacion de release
# ---------------------------------------------------------------------------

# ML Kit: el plugin de Flutter referencia los reconocedores de chino, japones,
# coreano y devanagari, pero aqui solo se incluye el modelo latino (que es el
# que necesita el espanol). Esas clases nunca se ejecutan, asi que basta con
# silenciar el aviso. Si algun dia se anaden esos idiomas, hay que anadir
# tambien las dependencias correspondientes en build.gradle.kts.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# El modelo latino se carga por reflexion desde los servicios de Google Play.
-keep class com.google.mlkit.vision.text.latin.** { *; }
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }

# Flutter y sus plugins.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Syncfusion PDF trabaja con reflexion sobre sus propios tipos.
-keep class com.syncfusion.** { *; }
-dontwarn com.syncfusion.**
