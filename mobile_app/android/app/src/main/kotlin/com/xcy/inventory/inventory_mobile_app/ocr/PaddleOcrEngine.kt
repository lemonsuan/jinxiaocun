package com.xcy.yuntuitui.inventory.ocr

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.SystemClock
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import org.json.JSONObject
import kotlin.math.max

/** Official PP-OCRv6_small models, executed by the reduced ARM64 CPU ORT runtime. */
class PaddleOcrEngine(private val context: Context) : Closeable {
    companion object {
        private const val DEFAULT_ROW_MERGE_TOLERANCE = 0.30f
        private const val MIN_ROW_MERGE_TOLERANCE = 0.20f
        private const val MAX_ROW_MERGE_TOLERANCE = 0.60f
        private const val MAX_BITMAP_SIDE = 2048
        init { System.loadLibrary("inventory_ocr") }
    }

    private var nativeHandle = 0L

    private fun initialize() {
        if (nativeHandle != 0L) return
        val manifest = context.assets.open("models/manifest.json").bufferedReader().use { JSONObject(it.readText()) }
        val models = manifest.getJSONArray("models")
        val paths = mutableMapOf<String, String>()
        val cache = File(context.cacheDir, "ppocrv6_small").apply { check(isDirectory || mkdirs()) }
        for (index in 0 until models.length()) {
            val entry = models.getJSONObject(index)
            val assetPath = entry.getString("assetPath")
            val filename = entry.getString("targetPath")
            require(filename == File(filename).name && !filename.contains("..")) { "Invalid model filename" }
            val expectedSize = entry.getLong("sizeBytes")
            val expectedHash = entry.getString("sha256")
            val target = File(cache, filename)
            if (!matches(target, expectedSize, expectedHash)) {
                val temporary = File(cache, "$filename.pending")
                try {
                    context.assets.open(assetPath).use { input ->
                        FileOutputStream(temporary).use { output -> input.copyTo(output); output.fd.sync() }
                    }
                    check(matches(temporary, expectedSize, expectedHash)) { "Model asset verification failed" }
                    check(temporary.renameTo(target)) { "Cannot install verified model" }
                } finally { temporary.delete() }
            }
            paths[filename] = target.absolutePath
        }
        nativeHandle = nativeCreate(
            requireNotNull(paths["ppocrv6_small_det.ort"]),
            requireNotNull(paths["ppocrv6_small_rec.ort"]),
            requireNotNull(paths["keys_v6_small.txt"]),
        )
        check(nativeHandle != 0L) { "PP-OCRv6_small initialization failed" }
        // The old cache is never reused and is safe to remove after the new runtime initializes.
        File(context.cacheDir, "ppocrv5_cache").deleteRecursively()
        listOf("ocr_det_fp16.tflite", "ocr_rec_fp16.tflite", "keys_v5.txt").forEach { File(context.cacheDir, it).delete() }
    }

    private fun matches(file: File, size: Long, expected: String): Boolean {
        if (!file.isFile || file.length() != size) return false
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { stream ->
            val buffer = ByteArray(65536)
            while (true) { val read = stream.read(buffer); if (read < 0) break; digest.update(buffer, 0, read) }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } == expected
    }

    fun recognize(imagePath: String, rowMergeTolerance: Float = DEFAULT_ROW_MERGE_TOLERANCE, deadlineElapsed: Long = 0): MlKitOcrResult {
        initialize()
        val bitmap = decodeBitmapForOcr(imagePath)
        try {
            val budget = if (deadlineElapsed > 0) deadlineElapsed - SystemClock.elapsedRealtime() else 35_000L
            check(budget > 0) { "OCR request expired" }
            val results = requireNotNull(nativeProcess(nativeHandle, bitmap, budget.coerceAtMost(35_000L))) { "OCR returned no response" }
                .filter { it.text.isNotBlank() }
            val rows = groupResultsIntoRows(results, normalizeRowMergeTolerance(rowMergeTolerance))
            return MlKitOcrResult(rows, rows.joinToString("\n") { it.joinToString(" ") })
        } finally { if (!bitmap.isRecycled) bitmap.recycle() }
    }

    override fun close() = release()
    fun release() { if (nativeHandle != 0L) { nativeDestroy(nativeHandle); nativeHandle = 0L } }

    private fun decodeBitmapForOcr(imagePath: String): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(imagePath, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Missing or unreadable OCR image" }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > MAX_BITMAP_SIDE) sample *= 2
        val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888; inSampleSize = sample }
        val decoded = requireNotNull(BitmapFactory.decodeFile(imagePath, options)) { "Cannot decode OCR image" }
        val argb = if (decoded.config == Bitmap.Config.ARGB_8888) decoded else {
            val converted = requireNotNull(decoded.copy(Bitmap.Config.ARGB_8888, false))
            decoded.recycle(); converted
        }
        val matrix = Matrix()
        val orientation = try { ExifInterface(imagePath).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) }
            catch (_: Exception) { ExifInterface.ORIENTATION_NORMAL }
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.preScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.preScale(-1f, 1f) }
            else -> return argb
        }
        return try { Bitmap.createBitmap(argb, 0, 0, argb.width, argb.height, matrix, true).also { if (it !== argb) argb.recycle() } }
            catch (error: Throwable) { argb.recycle(); throw error }
    }

    private fun normalizeRowMergeTolerance(value: Float): Float {
        if (value.isNaN() || value.isInfinite()) {
            return DEFAULT_ROW_MERGE_TOLERANCE
        }
        return value.coerceIn(MIN_ROW_MERGE_TOLERANCE, MAX_ROW_MERGE_TOLERANCE)
    }

    private fun groupResultsIntoRows(results: List<NativeOcrResult>, tolerance: Float): List<List<String>> =
        OcrRowGrouping.group(results, tolerance)

    private external fun nativeCreate(detModelPath: String, recModelPath: String, keysPath: String): Long
    private external fun nativeProcess(handle: Long, bitmap: Bitmap, timeoutMs: Long): Array<NativeOcrResult>?
    private external fun nativeDestroy(handle: Long)
}
