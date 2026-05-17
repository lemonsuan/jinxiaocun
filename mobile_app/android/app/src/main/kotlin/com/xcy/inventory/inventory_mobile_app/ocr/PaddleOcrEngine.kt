package com.xcy.yuntuitui.inventory.ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.util.Log
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Android PP-OCRv5 LiteRT wrapper adapted from the PPOCRv5-Android demo.
 *
 * The Flutter contract stays table-shaped: native returns editable OCR rows and
 * raw text; Dart remains responsible for product-list cleanup.
 */
class PaddleOcrEngine(private val context: Context) : Closeable {

    companion object {
        private const val TAG = "PaddleOcrEngine"
        private const val MODELS_DIR = "models"
        private const val DET_MODEL_FILE = "ocr_det_fp16.tflite"
        private const val REC_MODEL_FILE = "ocr_rec_fp16.tflite"
        private const val KEYS_FILE = "keys_v5.txt"
        private const val CACHE_DIR = "ppocrv5_cache"

        @Volatile
        private var cacheInitialized = false

        init {
            System.loadLibrary("inventory_ocr")
        }

        private fun initializeCache(context: Context) {
            if (cacheInitialized) return
            val cacheDir = File(context.cacheDir, CACHE_DIR).apply { mkdirs() }
            nativeSetCacheDir(cacheDir.absolutePath)
            cacheInitialized = true
        }

        @JvmStatic
        private external fun nativeSetCacheDir(cacheDir: String)

        @JvmStatic
        private external fun nativeShutdown()
    }

    private var nativeHandle = 0L

    fun initialize(): Boolean {
        if (nativeHandle != 0L) return true

        return try {
            initializeCache(context)
            val detModel = copyAssetToCache("$MODELS_DIR/$DET_MODEL_FILE")
            val recModel = copyAssetToCache("$MODELS_DIR/$REC_MODEL_FILE")
            val keys = copyAssetToCache("$MODELS_DIR/$KEYS_FILE")

            nativeHandle = nativeCreate(
                detModel,
                recModel,
                keys,
                OcrAcceleratorType.GPU.value,
            )
            if (nativeHandle == 0L) {
                Log.e(TAG, "nativeCreate returned null handle")
                false
            } else {
                true
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Initialize failed", e)
            nativeHandle = 0L
            false
        }
    }

    fun recognize(imagePath: String): MlKitOcrResult {
        if (!initialize()) {
            return MlKitOcrResult(emptyList(), "ERROR: PP-OCRv5 LiteRT engine init failed")
        }

        val bitmap = decodeBitmapForOcr(imagePath)
            ?: return MlKitOcrResult(emptyList(), "ERROR: Failed to decode image: $imagePath")

        return try {
            val results = nativeProcess(nativeHandle, bitmap).orEmpty()
                .filter { result -> result.text.isNotBlank() }
            val rows = groupResultsIntoRows(results)
            val rawText = rows.joinToString("\n") { row -> row.joinToString(" ") }
            MlKitOcrResult(rows, rawText)
        } catch (e: Throwable) {
            Log.e(TAG, "OCR process failed", e)
            MlKitOcrResult(emptyList(), "OCR_ERROR: ${e.stackTraceToString()}")
        } finally {
            if (!bitmap.isRecycled) {
                bitmap.recycle()
            }
        }
    }

    override fun close() {
        release()
    }

    fun release() {
        if (nativeHandle != 0L) {
            nativeDestroy(nativeHandle)
            nativeHandle = 0L
        }
    }

    fun shutdownRuntime() {
        release()
        nativeShutdown()
        cacheInitialized = false
    }

    private fun copyAssetToCache(assetPath: String): String {
        val target = File(context.cacheDir, assetPath.substringAfterLast('/'))
        if (target.exists() && target.length() > 0L) {
            return target.absolutePath
        }

        context.assets.open(assetPath).use { input ->
            FileOutputStream(target).use { output ->
                input.copyTo(output)
            }
        }
        return target.absolutePath
    }

    private fun decodeBitmapForOcr(imagePath: String): Bitmap? {
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = BitmapFactory.decodeFile(imagePath, options) ?: return null
        val argbBitmap = if (decoded.config == Bitmap.Config.ARGB_8888) {
            decoded
        } else {
            decoded.copy(Bitmap.Config.ARGB_8888, false)?.also { converted ->
                if (converted !== decoded) {
                    decoded.recycle()
                }
            } ?: decoded
        }

        val oriented = applyExifOrientation(imagePath, argbBitmap)
        if (oriented !== argbBitmap && !argbBitmap.isRecycled) {
            argbBitmap.recycle()
        }
        return oriented
    }

    private fun applyExifOrientation(imagePath: String, bitmap: Bitmap): Bitmap {
        val orientation = try {
            ExifInterface(imagePath).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (e: Throwable) {
            return bitmap
        }

        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
            else -> return bitmap
        }

        return try {
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to apply EXIF orientation", e)
            bitmap
        }
    }

    private fun groupResultsIntoRows(results: List<NativeOcrResult>): List<List<String>> {
        val sorted = results.sortedWith(
            compareBy<NativeOcrResult> { it.centerY }.thenBy { it.centerX },
        )
        val medianHeight = sorted.map { it.height }.sorted().let { heights ->
            if (heights.isEmpty()) 0f else heights[heights.size / 2]
        }
        val grouped = mutableListOf<MutableList<NativeOcrResult>>()

        for (result in sorted) {
            val current = grouped.lastOrNull()
            if (current == null) {
                grouped.add(mutableListOf(result))
                continue
            }

            val rowCenter = current.map { it.centerY }.average().toFloat()
            val rowHeight = current.map { it.height }.average().toFloat()
            val referenceHeight = if (medianHeight > 0f) {
                min(max(rowHeight, result.height), medianHeight * 1.25f)
            } else {
                max(rowHeight, result.height)
            }
            val threshold = max(6f, min(14f, referenceHeight * 0.45f))
            val rowTop = current.map { it.centerY - it.height / 2f }.average().toFloat()
            val rowBottom = current.map { it.centerY + it.height / 2f }.average().toFloat()
            val resultTop = result.centerY - result.height / 2f
            val resultBottom = result.centerY + result.height / 2f
            val verticalOverlap =
                min(rowBottom, resultBottom) - max(rowTop, resultTop)
            val minHeight = min(rowHeight, result.height)
            val isSameRow = abs(result.centerY - rowCenter) <= threshold &&
                verticalOverlap >= minHeight * 0.2f
            if (!isSameRow) {
                grouped.add(mutableListOf(result))
            } else {
                current.add(result)
            }
        }

        return grouped
            .map { row ->
                row.sortedBy { it.centerX }
                    .map { it.text.trim() }
                    .filter { it.isNotEmpty() }
            }
            .filter { it.isNotEmpty() }
    }

    private external fun nativeCreate(
        detModelPath: String,
        recModelPath: String,
        keysPath: String,
        acceleratorType: Int,
    ): Long

    private external fun nativeProcess(
        handle: Long,
        bitmap: Bitmap,
    ): Array<NativeOcrResult>?

    private external fun nativeDestroy(handle: Long)
}

private enum class OcrAcceleratorType(val value: Int) {
    GPU(0),
    CPU(1),
    NPU(2),
}
