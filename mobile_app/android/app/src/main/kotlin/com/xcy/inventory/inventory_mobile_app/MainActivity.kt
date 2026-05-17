package com.xcy.yuntuitui.inventory

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
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
                    recognizeTableInOcrProcess(imagePath, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun recognizeTableInOcrProcess(imagePath: String, result: MethodChannel.Result) {
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
