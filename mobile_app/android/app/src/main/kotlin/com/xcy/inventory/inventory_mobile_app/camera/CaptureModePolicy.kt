package com.xcy.yuntuitui.inventory.camera

/**
 * 相机捕获模式与零快门延迟（Zero-Shutter Lag, ZSL）调度策略。
 *
 * 核心设计原则：
 * 1. 硬件探测与内存保护：仅在底层 CameraX 明确支持且设备并非 Low-RAM（低运行内存）机型时优先启用零快门延迟；
 *    避免低端 Android 机型因环形帧缓冲区占用内存导致 Activity 闪退或系统强杀。
 * 2. 优雅回退机制：当尝试绑定 ZSL 失败（如部分厂商 HAL 层不兼容 Preview+ImageCapture+Analysis 三流并发）时，
 *    安全捕获异常，触发回退回调并无损平滑降级为普通高质量捕获模式，确保取景与拍照永不崩溃。
 */
internal object CaptureModePolicy {
    /**
     * 判断当前设备是否建议启用零快门延迟模式。
     *
     * @param supported 底层相机硬件是否声称支持 ZSL
     * @param lowRam 当前 Android 系统是否报告为低内存运行设备
     * @return 满足支持且非低内存机型时返回 true
     */
    fun preferZeroShutterLag(supported: Boolean, lowRam: Boolean): Boolean = supported && !lowRam

    /**
     * 带有自动异常回退的相机用例绑定执行器。
     *
     * @param preferZsl 是否倾向于以零快门延迟模式绑定
     * @param bind 实际执行 CameraX 用例绑定的闭包函数，参数为是否启用 ZSL
     * @param onFallback 当 ZSL 模式绑定抛出异常时的回退监听闭包
     * @return 绑定成功后产生的对象
     */
    fun <T> bindWithFallback(
        preferZsl: Boolean,
        bind: (Boolean) -> T,
        onFallback: (Exception) -> Unit,
    ): T {
        if (!preferZsl) return bind(false)
        return try {
            bind(true)
        } catch (error: Exception) {
            onFallback(error)
            bind(false)
        }
    }
}
