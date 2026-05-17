package com.xcy.yuntuitui.inventory.ocr

import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.ResultReceiver
import java.util.concurrent.Executors

class OcrService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private var engine: PaddleOcrEngine? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val imagePath = intent?.getStringExtra(EXTRA_IMAGE_PATH).orEmpty()
        val rowMergeTolerance = intent?.getFloatExtra(
            EXTRA_ROW_MERGE_TOLERANCE,
            DEFAULT_ROW_MERGE_TOLERANCE,
        ) ?: DEFAULT_ROW_MERGE_TOLERANCE
        @Suppress("DEPRECATION")
        val receiver = intent?.getParcelableExtra<ResultReceiver>(EXTRA_RESULT_RECEIVER)
        executor.execute {
            val recognition = try {
                if (imagePath.isBlank()) {
                    MlKitOcrResult(emptyList(), "")
                } else {
                    val activeEngine = engine
                        ?: PaddleOcrEngine(applicationContext).also { engine = it }
                    activeEngine.recognize(imagePath, rowMergeTolerance)
                }
            } catch (e: Throwable) {
                e.printStackTrace()
                MlKitOcrResult(emptyList(), "OCR_ERROR: ${e.stackTraceToString()}")
            }
            receiver?.send(
                0,
                android.os.Bundle().apply {
                    putStringArrayList(
                        EXTRA_ROWS,
                        ArrayList(recognition.rows.map { row -> row.joinToString("\t") }),
                    )
                    putString(EXTRA_RAW_TEXT, recognition.rawText)
                },
            )
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        engine?.release()
        executor.shutdownNow()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_IMAGE_PATH = "imagePath"
        const val EXTRA_ROW_MERGE_TOLERANCE = "rowMergeTolerance"
        const val EXTRA_RESULT_RECEIVER = "resultReceiver"
        const val EXTRA_ROWS = "rows"
        const val EXTRA_RAW_TEXT = "rawText"
        const val DEFAULT_ROW_MERGE_TOLERANCE = 0.30f
    }
}
