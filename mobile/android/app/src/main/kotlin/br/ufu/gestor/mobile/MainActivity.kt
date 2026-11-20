package br.ufu.gestor.mobile

import android.os.Bundle
import android.speech.tts.TextToSpeech
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private val channelName = "br.ufu.gestor.mobile/tts"
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var pendingSpeech: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textToSpeech = TextToSpeech(this, this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speak" -> {
                        val text = call.argument<String>("text")?.trim().orEmpty()
                        if (text.isEmpty()) {
                            result.success(false)
                        } else if (ttsReady) {
                            result.success(speak(text))
                        } else {
                            pendingSpeech = text
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        pendingSpeech = null
                        textToSpeech?.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onInit(status: Int) {
        val engine = textToSpeech ?: return
        ttsReady = status == TextToSpeech.SUCCESS
        if (!ttsReady) return
        var languageStatus = engine.setLanguage(Locale("pt", "BR"))
        if (languageStatus == TextToSpeech.LANG_MISSING_DATA ||
            languageStatus == TextToSpeech.LANG_NOT_SUPPORTED) {
            languageStatus = engine.setLanguage(Locale("pt"))
        }
        if (languageStatus == TextToSpeech.LANG_MISSING_DATA ||
            languageStatus == TextToSpeech.LANG_NOT_SUPPORTED) {
            ttsReady = false
            return
        }
        engine.setSpeechRate(1.0f)
        pendingSpeech?.let { speak(it) }
        pendingSpeech = null
    }

    private fun speak(text: String): Boolean {
        val engine = textToSpeech ?: return false
        val remaining = text.trim()
        if (remaining.isEmpty()) return false
        val chunks = mutableListOf<String>()
        var start = 0
        while (remaining.length - start > 3000) {
            val limit = start + 3000
            val sentenceBreak = remaining.lastIndexOfAny(
                charArrayOf('.', '!', '?', ';', '\n'),
                limit
            )
            val wordBreak = remaining.lastIndexOf(' ', limit)
            val end = if (sentenceBreak > start + 1000) {
                sentenceBreak + 1
            } else if (wordBreak > start) {
                wordBreak
            } else {
                limit
            }
            chunks.add(remaining.substring(start, end).trim())
            start = end
            while (start < remaining.length && remaining[start].isWhitespace()) start++
        }
        chunks.add(remaining.substring(start).trim())
        return chunks.withIndex().all { (index, chunk) ->
            engine.speak(
                chunk,
                if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD,
                Bundle(),
                "gestor-ufu-response-$index"
            ) == TextToSpeech.SUCCESS
        }
    }

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        super.onDestroy()
    }
}
