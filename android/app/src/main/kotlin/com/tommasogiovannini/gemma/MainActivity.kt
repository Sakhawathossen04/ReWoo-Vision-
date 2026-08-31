package com.tommasogiovannini.gemma

import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Flutter entry activity.
 *
 * Exposes the "rewoo_vision/media" MethodChannel used by the voice
 * assistant to open captured photos / recorded videos with the system
 * viewer (voice commands: "ছবি তোলো", "ভিডিও রেকর্ড করো").
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rewoo_vision/media"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openMedia" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "Media path is missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("NOT_FOUND", "File not found: $path", null)
                            return@setMethodCallHandler
                        }

                        val uri: Uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            file
                        )

                        val mime = when (file.extension.lowercase()) {
                            "mp4", "3gp", "mkv", "webm", "mov" -> "video/*"
                            else -> "image/*"
                        }

                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mime)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message ?: "unknown error", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
