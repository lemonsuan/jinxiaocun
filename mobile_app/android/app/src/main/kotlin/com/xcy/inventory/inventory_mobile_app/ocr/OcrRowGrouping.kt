package com.xcy.yuntuitui.inventory.ocr

import kotlin.math.atan2
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Group source-coordinate boxes in a deskewed document frame, preserving column order. */
object OcrRowGrouping {
    private data class Positioned(val source: NativeOcrResult, val x: Float, val y: Float)
    fun group(results: List<NativeOcrResult>, tolerance: Float): List<List<String>> {
        val valid = results.filter { it.text.isNotBlank() && it.centerX.isFinite() && it.centerY.isFinite() && it.width > 0 && it.height > 0 }
        if (valid.isEmpty()) return emptyList()
        val angles = valid.filter { it.width >= it.height * 1.5f && it.angle.isFinite() }.map {
            var angle = it.angle
            while (angle > 45) angle -= 90
            while (angle < -45) angle += 90
            angle
        }.sorted()
        val prior = if (angles.isEmpty()) 0.0 else angles[angles.size / 2].toDouble() * Math.PI / 180
        val medianHeight = valid.map { it.height }.sorted().let { it[it.size / 2] }
        // Box edge angles are noisy on short words. Long-distance center baselines
        // refine the document angle without pairing adjacent text rows.
        val candidates = mutableListOf<Pair<Double, Float>>()
        for (a in valid.indices) for (b in a + 1 until valid.size) {
            val left = if (valid[a].centerX <= valid[b].centerX) valid[a] else valid[b]
            val right = if (left === valid[a]) valid[b] else valid[a]
            val dx = right.centerX - left.centerX
            if (dx < medianHeight * 2) continue
            val slope = atan2((right.centerY - left.centerY).toDouble(), dx.toDouble())
            if (abs(slope - prior) <= 4 * Math.PI / 180) candidates.add(slope to dx)
        }
        val angle = if (candidates.isEmpty()) prior else {
            val ordered = candidates.sortedBy { it.first }
            val half = ordered.sumOf { it.second.toDouble() } / 2
            var weight = 0.0
            ordered.firstOrNull { weight += it.second; weight >= half }?.first ?: prior
        }
        val c = cos(angle).toFloat(); val s = sin(angle).toFloat()
        val sorted = valid.map { Positioned(it, it.centerX * c + it.centerY * s, -it.centerX * s + it.centerY * c) }
            .sortedWith(compareBy<Positioned> { it.y }.thenBy { it.x })
        val heights = valid.map { it.height }.sorted()
        val median = heights[heights.size / 2]
        val rows = mutableListOf<MutableList<Positioned>>()
        val merge = if (tolerance.isFinite()) tolerance.coerceIn(.20f, .60f) else .30f
        for (item in sorted) {
            val row = rows.lastOrNull()
            if (row == null) { rows.add(mutableListOf(item)); continue }
            val center = row.map { it.y }.average().toFloat()
            val height = row.map { it.source.height }.average().toFloat()
            val reference = min(max(height, item.source.height), median * 1.25f)
            val distance = max(3f, min(12f, reference * merge))
            val overlap = min(center + height / 2, item.y + item.source.height / 2) -
                max(center - height / 2, item.y - item.source.height / 2)
            if (abs(item.y - center) <= distance && overlap >= min(height, item.source.height) * (.65f - merge).coerceIn(.2f,.45f)) {
                row.add(item)
            } else rows.add(mutableListOf(item))
        }
        return rows.map { row -> row.sortedBy { it.x }.map { it.source.text.trim() } }
    }
}
