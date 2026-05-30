package com.xcy.yuntuitui.inventory

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.content.ContentValues
import android.provider.MediaStore
import android.os.Build
import android.os.Environment
import java.io.File
import java.io.FileOutputStream
import com.xcy.yuntuitui.inventory.ocr.OcrService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "inventory_app/scanner"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanTrackingNumber" -> result.success(null)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "inventory_app/paddle_ocr"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "recognizeTable" -> {
                    val imagePath = call.argument<String>("imagePath")
                    if (imagePath.isNullOrBlank()) {
                        result.error("INVALID_IMAGE_PATH", "imagePath is required", null)
                        return@setMethodCallHandler
                    }
                    val rowMergeTolerance = call.argument<Double>("rowMergeTolerance")
                        ?.toFloat()
                        ?: OcrService.DEFAULT_ROW_MERGE_TOLERANCE
                    recognizeTableInOcrProcess(imagePath, rowMergeTolerance, result)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "inventory_app/system_utils"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val fileName = call.argument<String>("fileName").orEmpty()
                    val bytes = call.argument<ByteArray>("bytes")
                    if (fileName.isBlank() || bytes == null) {
                        result.error("INVALID_ARGS", "fileName or bytes is empty", null)
                        return@setMethodCallHandler
                    }
                    val ok = saveToDownloads(fileName, bytes)
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToDownloads(fileName: String, bytes: ByteArray): Boolean {
        val resolver = contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentValues = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues) ?: return false
            return try {
                resolver.openOutputStream(uri)?.use { outputStream ->
                    outputStream.write(bytes)
                    true
                } ?: false
            } catch (e: Exception) {
                e.printStackTrace()
                false
            }
        } else {
            @Suppress("DEPRECATION")
            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (!downloadsDir.exists()) {
                downloadsDir.mkdirs()
            }
            val file = File(downloadsDir, fileName)
            return try {
                FileOutputStream(file).use { out ->
                    out.write(bytes)
                    true
                }
            } catch (e: Exception) {
                e.printStackTrace()
                false
            }
        }
    }

    private fun recognizeTableInOcrProcess(
        imagePath: String,
        rowMergeTolerance: Float,
        result: MethodChannel.Result
    ) {
        val handler = Handler(Looper.getMainLooper())
        val delivered = AtomicBoolean(false)
        val timeout = Runnable {
            if (delivered.compareAndSet(false, true)) {
                result.success(
                    mapOf(
                        "rows" to emptyList<List<String>>(),
                        "rawText" to "",
                    )
                )
            }
        }
        handler.postDelayed(timeout, OCR_TIMEOUT_MS)

        val receiver = object : ResultReceiver(handler) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                if (!delivered.compareAndSet(false, true)) {
                    return
                }
                handler.removeCallbacks(timeout)
                val rowLines = resultData
                    ?.getStringArrayList(OcrService.EXTRA_ROWS)
                    .orEmpty()
                val rawText = resultData
                    ?.getString(OcrService.EXTRA_RAW_TEXT)
                    .orEmpty()
                val rows = rowLines.map { line ->
                    line.split('\t')
                        .map { cell -> cell.trim() }
                        .filter { cell -> cell.isNotEmpty() }
                }.filter { row -> row.isNotEmpty() }
                result.success(
                    mapOf(
                        "rows" to rows,
                        "rawText" to rawText,
                    )
                )
            }
        }

        try {
            startService(
                Intent(this, OcrService::class.java)
                    .putExtra(OcrService.EXTRA_IMAGE_PATH, imagePath)
                    .putExtra(OcrService.EXTRA_ROW_MERGE_TOLERANCE, rowMergeTolerance)
                    .putExtra(OcrService.EXTRA_RESULT_RECEIVER, receiver)
            )
        } catch (e: Throwable) {
            e.printStackTrace()
            if (delivered.compareAndSet(false, true)) {
                handler.removeCallbacks(timeout)
                result.success(
                    mapOf(
                        "rows" to emptyList<List<String>>(),
                        "rawText" to "MAIN_ACTIVITY_ERROR: ${e.stackTraceToString()}",
                    )
                )
            }
        }
    }

    private companion object {
        const val OCR_TIMEOUT_MS = 45_000L
    }
}
