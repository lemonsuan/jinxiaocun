package com.xcy.yuntuitui.inventory.ocr

data class MlKitOcrResult(
    val rows: List<List<String>>,
    val rawText: String,
)

data class NativeOcrResult(
    val text: String,
    val confidence: Float,
    val centerX: Float,
    val centerY: Float,
    val width: Float,
    val height: Float,
    val angle: Float,
)
