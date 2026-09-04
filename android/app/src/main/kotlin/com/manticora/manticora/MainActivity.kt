package com.manticora.manticora

import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

// local_auth necesita una FragmentActivity para mostrar el dialogo biometrico.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "manticora/tts")
            .setMethodCallHandler { call, result ->
                if (call.method != "synthesize") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val text = call.argument<String>("text").orEmpty()
                val path = call.argument<String>("path").orEmpty()
                val language = call.argument<String>("language") ?: "es-ES"
                val rate = (call.argument<Number>("rate")?.toFloat() ?: 1.0f)

                if (text.isBlank() || path.isBlank()) {
                    result.error("invalid_arguments", "Faltan el texto o la ruta de salida.", null)
                    return@setMethodCallHandler
                }
                synthesize(text, path, language, rate, result)
            }
    }

    private fun synthesize(
        text: String,
        path: String,
        language: String,
        rate: Float,
        result: MethodChannel.Result,
    ) {
        val replied = AtomicBoolean(false)
        var engine: TextToSpeech? = null

        fun finishError(code: String, message: String) {
            if (replied.compareAndSet(false, true)) {
                runOnUiThread { result.error(code, message, null) }
            }
            engine?.shutdown()
        }

        engine = TextToSpeech(applicationContext) { status ->
            if (status != TextToSpeech.SUCCESS) {
                finishError("tts_init", "No se pudo iniciar el motor de voz.")
                return@TextToSpeech
            }

            val tts = engine
            if (tts == null) {
                finishError("tts_init", "El motor de voz no termino de iniciarse.")
                return@TextToSpeech
            }

            val localeResult = tts.setLanguage(Locale.forLanguageTag(language))
            if (localeResult == TextToSpeech.LANG_MISSING_DATA ||
                localeResult == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                finishError("tts_language", "No hay una voz instalada para $language.")
                return@TextToSpeech
            }

            tts.setSpeechRate(rate.coerceIn(0.5f, 1.6f))
            val output = File(path)
            output.parentFile?.mkdirs()
            val utteranceId = UUID.randomUUID().toString()
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) = Unit

                override fun onDone(id: String?) {
                    if (replied.compareAndSet(false, true)) {
                        runOnUiThread { result.success(path) }
                    }
                    tts.shutdown()
                }

                @Deprecated("Deprecated in Android")
                override fun onError(id: String?) {
                    finishError("tts_failed", "El motor de voz no pudo crear el fichero.")
                }

                override fun onError(id: String?, errorCode: Int) {
                    finishError("tts_failed", "El motor de voz fallo (codigo $errorCode).")
                }
            })

            val params = Bundle()
            val queued = tts.synthesizeToFile(text, params, output, utteranceId)
            if (queued != TextToSpeech.SUCCESS) {
                finishError("tts_queue", "El motor de voz rechazo el texto.")
            }
        }
    }
}
