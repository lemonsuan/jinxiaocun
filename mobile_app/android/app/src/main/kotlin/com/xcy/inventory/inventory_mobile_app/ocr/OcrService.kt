package com.xcy.yuntuitui.inventory.ocr

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ResultReceiver
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** One bounded CPU lane; reuse models within a burst and release after a short idle period. */
class OcrService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val generation = AtomicInteger()
    private val outstanding = AtomicInteger()
    @Volatile private var destroyed = false
    private var latestStartId = 0
    // Only the serial executor touches the native handle, including final cleanup.
    private var engine: PaddleOcrEngine? = null
    private val executor = object : ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(2)) {
        override fun terminated() { engine?.release(); engine = null; super.terminated() }
    }
    private val idleRelease = Runnable {
        val idleGeneration = generation.get()
        val idleStartId = latestStartId
        if (outstanding.get() == 0 && !destroyed) {
            try {
                executor.execute {
                    if (generation.get() == idleGeneration && outstanding.get() == 0) {
                        engine?.release(); engine = null
                        handler.post {
                            if (!destroyed && generation.get() == idleGeneration && outstanding.get() == 0) {
                                stopSelfResult(idleStartId)
                            }
                        }
                    }
                }
            } catch (_: RejectedExecutionException) { /* Service is already shutting down. */ }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId
        generation.incrementAndGet()
        handler.removeCallbacks(idleRelease)
        val imagePath = intent?.getStringExtra(EXTRA_IMAGE_PATH).orEmpty()
        val tolerance = intent?.getFloatExtra(EXTRA_ROW_MERGE_TOLERANCE, DEFAULT_ROW_MERGE_TOLERANCE)
            ?: DEFAULT_ROW_MERGE_TOLERANCE
        val deadline = intent?.getLongExtra(EXTRA_DEADLINE, 0L) ?: 0L
        @Suppress("DEPRECATION")
        val receiver = intent?.getParcelableExtra<ResultReceiver>(EXTRA_RESULT_RECEIVER)
        outstanding.incrementAndGet()
        try {
            executor.execute {
                try {
                    check(!destroyed) { "OCR service closed" }
                    check(deadline <= 0 || SystemClock.elapsedRealtime() < deadline) { "OCR request expired" }
                    require(imagePath.isNotBlank()) { "Missing image path" }
                    val active = engine ?: PaddleOcrEngine(applicationContext).also { engine = it }
                    val recognition = active.recognize(imagePath, tolerance, deadline)
                    check(deadline <= 0 || SystemClock.elapsedRealtime() < deadline) { "OCR request expired" }
                    receiver?.send(RESULT_OK, android.os.Bundle().apply {
                        putStringArrayList(EXTRA_ROWS, ArrayList(recognition.rows.map { it.joinToString("\t") }))
                        putString(EXTRA_RAW_TEXT, recognition.rawText)
                    })
                } catch (error: Throwable) {
                    Log.e("PPOCRv6", "Recognition request failed: ${error.javaClass.simpleName}")
                    sendError(receiver, "OCR_FAILED", "清单识别失败，请重试或手工录入")
                } finally {
                    outstanding.decrementAndGet()
                    handler.post { scheduleIdleRelease() }
                }
            }
        } catch (_: RejectedExecutionException) {
            outstanding.decrementAndGet()
            sendError(receiver, "OCR_BUSY", "识别任务较多，请稍后重试")
            scheduleIdleRelease()
        }
        return START_NOT_STICKY
    }

    private fun scheduleIdleRelease() {
        handler.removeCallbacks(idleRelease)
        if (!destroyed && outstanding.get() == 0) handler.postDelayed(idleRelease, IDLE_RELEASE_MS)
    }
    private fun sendError(receiver: ResultReceiver?, code: String, message: String) {
        receiver?.send(RESULT_ERROR, android.os.Bundle().apply {
            putString(EXTRA_ERROR_CODE, code); putString(EXTRA_ERROR_MESSAGE, message)
        })
    }
    override fun onDestroy() {
        destroyed = true
        handler.removeCallbacks(idleRelease)
        // Do not free an engine while native Run is using it. Queued work exits via the guard.
        executor.shutdown()
        super.onDestroy()
    }
    companion object {
        const val RESULT_OK = 0
        const val RESULT_ERROR = 1
        const val EXTRA_IMAGE_PATH = "imagePath"
        const val EXTRA_ROW_MERGE_TOLERANCE = "rowMergeTolerance"
        const val EXTRA_RESULT_RECEIVER = "resultReceiver"
        const val EXTRA_ROWS = "rows"
        const val EXTRA_RAW_TEXT = "rawText"
        const val EXTRA_ERROR_CODE = "errorCode"
        const val EXTRA_ERROR_MESSAGE = "errorMessage"
        const val EXTRA_DEADLINE = "deadlineElapsedRealtime"
        const val DEFAULT_ROW_MERGE_TOLERANCE = 0.30f
        private const val IDLE_RELEASE_MS = 10_000L
    }
}
