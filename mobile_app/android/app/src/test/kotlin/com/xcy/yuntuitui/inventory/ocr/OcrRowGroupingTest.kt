package com.xcy.yuntuitui.inventory.ocr

import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin

class OcrRowGroupingTest {
    @Test fun keepsSkewedColumnsInOneRowAndOrdersByX() {
        val angle = 5f
        val radians = angle * Math.PI / 180
        fun box(text: String, x: Float, y: Float) = NativeOcrResult(text, .99f,
            (x * cos(radians) - y * sin(radians)).toFloat(),
            (x * sin(radians) + y * cos(radians)).toFloat(), 90f, 30f, angle)
        val data = listOf(box("3", 900f, 120f), box("护发素", 430f, 200f),
            box("A1001", 100f, 120f), box("洗发水", 430f, 120f), box("A1002", 100f, 200f), box("2",900f,200f))
        assertEquals(listOf(listOf("A1001", "洗发水", "3"), listOf("A1002", "护发素", "2")), OcrRowGrouping.group(data,.30f))
    }
    @Test fun ignoresEmptyRowsAndNormalizesInvalidTolerance() {
        assertEquals(emptyList<List<String>>(), OcrRowGrouping.group(emptyList(),Float.NaN))
        assertEquals(listOf(listOf("商品")), OcrRowGrouping.group(listOf(NativeOcrResult("商品",.9f,50f,50f,60f,25f,0f)),Float.NaN))
    }
    @Test fun groupsRealV6SkewedFixtureWithoutMixingQuantities() {
        // Recorded actual PP-OCRv6_small detections from skewed_list.png (5 degree document).
        val detections = listOf(
            NativeOcrResult("商品清单", .99f, 191.878f, 167.601f, 244.594f, 85.7562f, -4.42533f),
            NativeOcrResult("3", .99f, 1058.25f, 215.182f, 74.7518f, 48.3737f, 86.5252f),
            NativeOcrResult("洗发水", .99f, 530.457f, 253.23f, 187.582f, 85.517f, -3.84038f),
            NativeOcrResult("A1001", .99f, 167.542f, 291.241f, 182.766f, 85.9582f, -3.33439f),
            NativeOcrResult("12", .99f, 1086.22f, 335.278f, 86.2133f, 77.8331f, 85.5557f),
            NativeOcrResult("护发素", .99f, 538.599f, 372.196f, 193.9f, 93.3075f, -4.16256f),
            NativeOcrResult("B2002", .99f, 180.515f, 411.859f, 184.641f, 85.4272f, -3.42464f),
            NativeOcrResult("5", .99f, 1078.89f, 454.186f, 76.709f, 46.8245f, 84.451f),
            NativeOcrResult("沐浴露", .99f, 550.864f, 493.443f, 194.622f, 94.5897f, -2.80605f),
            NativeOcrResult("C3003", .99f, 192.212f, 531.459f, 185.078f, 87.9616f, -4.14586f))
        assertEquals(listOf(listOf("商品清单"), listOf("A1001", "洗发水", "3"),
            listOf("B2002", "护发素", "12"), listOf("C3003", "沐浴露", "5")), OcrRowGrouping.group(detections, .30f))
    }
}
