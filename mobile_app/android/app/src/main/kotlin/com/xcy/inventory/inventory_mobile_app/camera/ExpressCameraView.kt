package com.xcy.yuntuitui.inventory.camera

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ExperimentalZeroShutterLag
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.camera.view.TransformExperimental
import androidx.camera.view.transform.CoordinateTransform
import androidx.camera.view.transform.FileTransformFactory
import androidx.camera.view.transform.OutputTransform
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/** A page-scoped camera session. Locking a barcode never tears down the camera. */
class ExpressCameraFactory(
    private val activity: FlutterActivity,
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    private val views = mutableSetOf<ExpressCameraView>()

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val parameters = args as? Map<*, *> ?: emptyMap<Any, Any>()
        return ExpressCameraView(activity, messenger, viewId, parameters) { views.remove(it) }
            .also { views.add(it) }
    }

    fun onCameraPermissionResult() {
        views.toList().forEach { it.onCameraPermissionResult() }
    }

    companion object {
        const val VIEW_TYPE = "inventory_app/express_camera"
        const val PERMISSION_REQUEST = 7834
    }
}

class ExpressCameraView(
    private val activity: FlutterActivity,
    messenger: BinaryMessenger,
    viewId: Int,
    parameters: Map<*, *>,
    private val onDisposed: (ExpressCameraView) -> Unit,
) : PlatformView, MethodChannel.MethodCallHandler, DefaultLifecycleObserver {
    private val previewView = PreviewView(activity).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }
    private val channel = MethodChannel(messenger, "${ExpressCameraFactory.VIEW_TYPE}/$viewId")
    private val main = Handler(Looper.getMainLooper())
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private val captureExecutor = Executors.newSingleThreadExecutor()
    private val analyzing = AtomicBoolean(false)
    private val scanner = BarcodeScanning.getClient(
        BarcodeScannerOptions.Builder().setBarcodeFormats(
            Barcode.FORMAT_CODE_128,
            Barcode.FORMAT_CODE_39,
            Barcode.FORMAT_CODE_93,
            Barcode.FORMAT_CODABAR,
            Barcode.FORMAT_EAN_13,
            Barcode.FORMAT_EAN_8,
            Barcode.FORMAT_ITF,
            Barcode.FORMAT_UPC_A,
            Barcode.FORMAT_UPC_E,
        ).build(),
    )
    private val requestedOutput = parameters["outputDirectory"] as? String ?: ""
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null
    private var imageCapture: ImageCapture? = null
    @Volatile private var lockedTracking: String? = null
    private var captureId: String? = null
    @Volatile private var capturing = false
    @Volatile private var paused = false
    private var explicitlyPaused = false
    @Volatile private var disposed = false
    @Volatile private var eventsReady = false
    private var pendingInitialError: Map<String, Any>? = null
    private var initializing = false
    private var permissionRequestInProgress = false
    private var permissionDenied = false
    @Volatile private var bound = false
    @Volatile private var generation = 0
    private var torchEnabled = parameters["torchEnabled"] == true
    private var viewportAspect = 0f
    private var boundRotation = -1
    private var zslRequested = false
    private val createdAt = SystemClock.elapsedRealtime()

    init {
        channel.setMethodCallHandler(this)
        activity.lifecycle.addObserver(this)
        previewView.post { startCamera() }
    }

    override fun getView(): View = previewView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed && call.method != "dispose") {
            result.error("DISPOSED", "相机页面已关闭", null)
            return
        }
        when (call.method) {
            "capture" -> capture(call, result)
            "reset" -> {
                if (capturing) {
                    result.error("CAPTURE_BUSY", "正在拍摄，请稍候", null)
                } else {
                    lockedTracking = null
                    captureId = null
                    result.success(null)
                }
            }
            "setTorch" -> {
                torchEnabled = call.argument<Boolean>("enabled") == true
                val activeCamera = camera
                if (activeCamera == null || !bound) {
                    result.error("NOT_READY", "相机尚未就绪", null)
                } else if (!activeCamera.cameraInfo.hasFlashUnit() && torchEnabled) {
                    result.error("NO_FLASH", "当前摄像头没有补光灯", null)
                } else {
                    val future = activeCamera.cameraControl.enableTorch(torchEnabled)
                    future.addListener({
                        try {
                            future.get()
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("TORCH_FAILED", "补光灯设置失败", null)
                        }
                    }, ContextCompat.getMainExecutor(activity))
                }
            }
            "focus" -> {
                val x = call.argument<Number>("x")?.toFloat()
                val y = call.argument<Number>("y")?.toFloat()
                if (camera == null || !bound || x == null || y == null || capturing ||
                    !x.isFinite() || !y.isFinite()
                ) {
                    result.error("NOT_READY", "当前无法对焦", null)
                } else {
                    val point = previewView.meteringPointFactory.createPoint(
                        x.coerceIn(0f, 1f) * previewView.width,
                        y.coerceIn(0f, 1f) * previewView.height,
                    )
                    camera!!.cameraControl.startFocusAndMetering(
                        FocusMeteringAction.Builder(point).setAutoCancelDuration(3, TimeUnit.SECONDS).build(),
                    )
                    result.success(null)
                }
            }
            "pause" -> {
                explicitlyPaused = true
                paused = true
                if (!capturing) unbind()
                result.success(null)
            }
            "resume" -> {
                val firstHandshake = !eventsReady
                eventsReady = true
                explicitlyPaused = false
                paused = false
                val initialError = pendingInitialError
                pendingInitialError = null
                if (firstHandshake && initialError != null) {
                    emit("onError", initialError)
                } else {
                    startCamera()
                }
                result.success(null)
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    @androidx.annotation.OptIn(ExperimentalZeroShutterLag::class)
    private fun startCamera() {
        if (disposed || paused || initializing) return
        if (bound) {
            emit("onReady", emptyMap())
            return
        }
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (permissionDenied) {
                emitError("CAMERA_PERMISSION_DENIED", "请在系统设置中允许相机权限后重试")
            } else if (!permissionRequestInProgress) {
                permissionRequestInProgress = true
                activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), ExpressCameraFactory.PERMISSION_REQUEST)
            }
            return
        }
        if (previewView.width <= 0 || previewView.height <= 0 || previewView.display == null) {
            previewView.addOnLayoutChangeListener(object : View.OnLayoutChangeListener {
                override fun onLayoutChange(v: View, l: Int, t: Int, r: Int, b: Int,
                    oldL: Int, oldT: Int, oldR: Int, oldB: Int) {
                    if (r > l && b > t) {
                        previewView.removeOnLayoutChangeListener(this)
                        startCamera()
                    }
                }
            })
            return
        }
        initializing = true
        val requestGeneration = ++generation
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            if (disposed || paused || requestGeneration != generation) {
                initializing = false
                return@addListener
            }
            try {
                val activeProvider = future.get()
                provider = activeProvider
                val lowRam = (activity.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
                    ?.isLowRamDevice ?: true
                val supportsZsl = activeProvider.getCameraInfo(CameraSelector.DEFAULT_BACK_CAMERA).isZslSupported
                val preferredZsl = CaptureModePolicy.preferZeroShutterLag(supportsZsl, lowRam)
                val activeCamera = CaptureModePolicy.bindWithFallback(
                    preferZsl = preferredZsl,
                    bind = { useZsl -> bindCaptureSession(activeProvider, useZsl) },
                    onFallback = {
                        // 只清本视图拥有的流，同画质回退；不触发额外初始化或无限循环。
                        releaseOwnedUseCases()
                        Log.w(TAG, "ZSL绑定不兼容，回退低延迟模式")
                    },
                )
                camera = activeCamera
                viewportAspect = previewView.width.toFloat() / previewView.height
                boundRotation = previewView.display.rotation
                bound = true
                initializing = false
                if (activeCamera.cameraInfo.hasFlashUnit()) activeCamera.cameraControl.enableTorch(torchEnabled)
                Log.d(TAG, "camera_ready_ms=${SystemClock.elapsedRealtime() - createdAt} zsl_supported=$supportsZsl low_ram=$lowRam zsl_requested=$zslRequested")
                emit("onReady", emptyMap())
            } catch (error: Exception) {
                initializing = false
                unbind()
                Log.e(TAG, "Camera session binding failed", error)
                if (error is UnsupportedCaptureResolution) {
                    emitError("UNSUPPORTED_CAPTURE_RESOLUTION", "当前摄像头无法提供清晰的单据照片，请使用普通入库")
                } else {
                    emitError("CAMERA_INIT_FAILED", "无法启动扫码拍照相机，请重试或使用普通入库")
                }
            }
        }, ContextCompat.getMainExecutor(activity))
    }

    @androidx.annotation.OptIn(ExperimentalZeroShutterLag::class)
    private fun bindCaptureSession(activeProvider: ProcessCameraProvider, useZsl: Boolean): Camera {
        val rotation = previewView.display.rotation
        val resolution = ResolutionSelector.Builder().setResolutionStrategy(
            ResolutionStrategy(Size(1920, 1080), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
        ).setResolutionFilter { sizes, _ -> sizes.filter { hasDocumentResolution(it) } }.build()
        val newPreview = Preview.Builder().setTargetRotation(rotation).build()
        newPreview.setSurfaceProvider(previewView.surfaceProvider)
        val newCapture = ImageCapture.Builder()
            .setCaptureMode(if (useZsl) ImageCapture.CAPTURE_MODE_ZERO_SHUTTER_LAG else ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .setResolutionSelector(resolution)
            .setTargetRotation(rotation)
            .setFlashMode(ImageCapture.FLASH_MODE_OFF)
            .setJpegQuality(95)
            .build()
        val newAnalysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setTargetRotation(rotation)
            .build()
        newAnalysis.setAnalyzer(analysisExecutor) { image -> analyze(image) }
        val viewport = previewView.viewPort ?: throw IllegalStateException("Preview viewport unavailable")
        val group = UseCaseGroup.Builder().setViewPort(viewport)
            .addUseCase(newPreview).addUseCase(newCapture).addUseCase(newAnalysis).build()
        // 在绑定前记录本视图拥有的流，任一步失败均能完整释放。
        preview = newPreview
        analysis = newAnalysis
        imageCapture = newCapture
        val activeCamera = activeProvider.bindToLifecycle(activity, CameraSelector.DEFAULT_BACK_CAMERA, group)
        // 校验实际协商的原始照片流，不能把较小取景裁剪误作照片分辨率。
        val streamResolution = newCapture.resolutionInfo?.resolution
        if (streamResolution == null || !hasDocumentResolution(streamResolution)) {
            throw UnsupportedCaptureResolution()
        }
        zslRequested = useZsl
        return activeCamera
    }

    fun onCameraPermissionResult() {
        permissionRequestInProgress = false
        if (disposed) return
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera()
        } else {
            permissionDenied = true
            emitError("CAMERA_PERMISSION_DENIED", "请在系统设置中允许相机权限后重试")
        }
    }

    @androidx.annotation.OptIn(ExperimentalGetImage::class)
    private fun analyze(image: ImageProxy) {
        if (disposed || paused || !eventsReady || !bound || lockedTracking != null || capturing ||
            !analyzing.compareAndSet(false, true)
        ) {
            image.close()
            return
        }
        val media = image.image
        if (media == null) {
            analyzing.set(false)
            image.close()
            return
        }
        val analysisGeneration = generation
        try {
            scanner.process(InputImage.fromMediaImage(media, image.imageInfo.rotationDegrees))
                .addOnSuccessListener(ContextCompat.getMainExecutor(activity)) { barcodes ->
                    if (!disposed && !paused && eventsReady && bound && analysisGeneration == generation &&
                        lockedTracking == null && !capturing) {
                        val value = barcodes.firstNotNullOfOrNull { it.rawValue?.trim()?.takeIf(String::isNotEmpty) }
                        if (value != null) {
                            lockedTracking = value
                            emit("onTracking", mapOf("trackingNumber" to value))
                        }
                    }
                }
                .addOnCompleteListener {
                    image.close()
                    analyzing.set(false)
                }
        } catch (error: Exception) {
            image.close()
            analyzing.set(false)
        }
    }

    @androidx.annotation.OptIn(TransformExperimental::class)
    private fun capture(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("captureId")
        val tracking = call.argument<String>("trackingNumber")
        val activeCapture = imageCapture
        if (capturing || !bound || paused || activeCapture == null) {
            result.error("CAPTURE_BUSY", "相机尚未就绪或正在拍摄", null)
            return
        }
        if (id.isNullOrBlank() || !id.matches(Regex("[A-Za-z0-9_-]{1,120}")) ||
            tracking.isNullOrBlank() || tracking != lockedTracking
        ) {
            result.error("INVALID_CAPTURE", "快递单号与当前拍摄不一致，请重新扫码", null)
            return
        }
        val crop = readCrop(call.argument<Map<String, Number>>("crop"))
        val file = try {
            val directory = File(requestedOutput).canonicalFile
            val dataRoot = File(activity.applicationInfo.dataDir).canonicalPath + File.separator
            require(directory.path.startsWith(dataRoot)) { "Output directory must be app private" }
            require(directory.isDirectory || directory.mkdirs()) { "Cannot create image directory" }
            File(directory, "express_$id.jpg").also { require(!it.exists()) { "Capture ID already exists" } }
        } catch (error: Exception) {
            result.error("SAVE_FAILED", "无法创建照片文件，请检查存储空间后重试", null)
            return
        }
        capturing = true
        captureId = id
        val start = SystemClock.elapsedRealtime()
        val aspect = viewportAspect
        val previewWidth = previewView.width
        val previewHeight = previewView.height
        val currentRotation = previewView.display?.rotation ?: boundRotation
        activeCapture.targetRotation = currentRotation
        val currentAspect = if (previewHeight > 0) previewWidth.toFloat() / previewHeight else 0f
        val stableGeometry = currentRotation == boundRotation && aspect > 0 &&
            abs(currentAspect - aspect) / aspect < 0.015f
        // 旋转或缩放后不能沿用旧预览几何信息裁剪。
        val sourceTransform = if (stableGeometry) previewView.outputTransform else null
        val options = ImageCapture.OutputFileOptions.Builder(file).build()
        try {
            activeCapture.takePicture(options, captureExecutor, object : ImageCapture.OnImageSavedCallback {
                override fun onCaptureStarted() {
                    // 曝光启动仅作计时，绝不能在这里提示照片已保存。
                    Log.d(TAG, "request_to_capture_started_ms=${SystemClock.elapsedRealtime() - start}")
                }

                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    val savedAt = SystemClock.elapsedRealtime()
                    try {
                        check(file.isFile && file.length() > 0L) { "Empty capture file" }
                        RandomAccessFile(file, "rw").use { it.fd.sync() }
                        val syncedAt = SystemClock.elapsedRealtime()
                        val mappedCrop = cropForSavedViewport(file, crop, aspect, sourceTransform, previewWidth, previewHeight)
                        val mappedAt = SystemClock.elapsedRealtime()
                        val elapsed = mappedAt - start
                        main.post {
                            capturing = false
                            if (disposed) {
                                file.delete()
                                return@post
                            }
                            Log.d(TAG, "shutter_to_saved_ms=$elapsed request_to_image_saved_ms=${savedAt - start} file_sync_ms=${syncedAt - savedAt} crop_map_ms=${mappedAt - syncedAt} request_to_event_ms=${SystemClock.elapsedRealtime() - start} zsl_requested=$zslRequested")
                            emit("onCaptured", mapOf(
                                "captureId" to id,
                                "trackingNumber" to tracking,
                                "imagePath" to file.absolutePath,
                                "shutterToSavedMs" to elapsed,
                                "crop" to mappedCrop,
                            ))
                            if (paused) unbind()
                        }
                    } catch (error: Exception) {
                        main.post { failCapture(file, id, "SAVE_FAILED", "照片保存失败，请重拍") }
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    main.post { failCapture(file, id, "CAPTURE_FAILED", "拍摄失败，请保持手机稳定后重试") }
                }
            })
            result.success(null)
        } catch (error: Exception) {
            capturing = false
            file.delete()
            result.error("CAPTURE_FAILED", "拍摄请求失败，请重试", null)
        }
    }

    private fun failCapture(file: File, id: String, code: String, message: String) {
        file.delete()
        capturing = false
        if (!disposed) emitError(code, message, id)
        if (paused) unbind()
    }

    private fun readCrop(raw: Map<String, Number>?): RectF {
        if (raw == null) return RectF(0f, 0f, 1f, 1f)
        val values = listOf("left", "top", "right", "bottom").map { raw[it]?.toFloat() ?: Float.NaN }
        if (values.any { !it.isFinite() }) return RectF(0f, 0f, 1f, 1f)
        val crop = RectF(values[0].coerceIn(0f, 1f), values[1].coerceIn(0f, 1f),
            values[2].coerceIn(0f, 1f), values[3].coerceIn(0f, 1f))
        return if (crop.width() > 0f && crop.height() > 0f) crop else RectF(0f, 0f, 1f, 1f)
    }

    /** 将实际预览变换映射到按EXIF方向解释的已保存JPEG。 */
    @androidx.annotation.OptIn(TransformExperimental::class)
    private fun cropForSavedViewport(
        file: File, crop: RectF, aspect: Float, source: OutputTransform?,
        previewWidth: Int, previewHeight: Int,
    ): Map<String, Float> {
        val full = mapOf("left" to 0f, "top" to 0f, "right" to 1f, "bottom" to 1f)
        if (source == null || previewWidth <= 0 || previewHeight <= 0) return full
        return try {
            val dimensions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.absolutePath, dimensions)
            val rotation = ExifInterface(file).rotationDegrees
            val width = if (rotation == 90 || rotation == 270) dimensions.outHeight else dimensions.outWidth
            val height = if (rotation == 90 || rotation == 270) dimensions.outWidth else dimensions.outHeight
            if (width <= 0 || height <= 0 || aspect <= 0 ||
                abs(width.toFloat() / height - aspect) / aspect >= 0.015f) return full
            val target = FileTransformFactory().apply { setUsingExifOrientation(true) }.getOutputTransform(file)
            val rectangle = RectF(crop.left * previewWidth, crop.top * previewHeight,
                crop.right * previewWidth, crop.bottom * previewHeight)
            CoordinateTransform(source, target).mapRect(rectangle)
            if (listOf(rectangle.left, rectangle.top, rectangle.right, rectangle.bottom).any { !it.isFinite() }) return full
            val left = (rectangle.left / width).coerceIn(0f, 1f)
            val top = (rectangle.top / height).coerceIn(0f, 1f)
            val right = (rectangle.right / width).coerceIn(0f, 1f)
            val bottom = (rectangle.bottom / height).coerceIn(0f, 1f)
            if (right <= left || bottom <= top) full else mapOf("left" to left, "top" to top, "right" to right, "bottom" to bottom)
        } catch (error: Exception) {
            // 几何变换不可用时保留原图，不猜测破坏性裁剪。
            Log.w(TAG, "Crop transform unavailable; preserving full photo")
            full
        }
    }

    private fun emit(method: String, payload: Map<String, Any>) {
        if (disposed) return
        if (!eventsReady) {
            if (method == "onError") pendingInitialError = payload
            return
        }
        channel.invokeMethod(method, payload)
    }

    private fun emitError(code: String, message: String, id: String? = null) {
        val payload = mutableMapOf<String, Any>("code" to code, "message" to message)
        if (id != null) payload["captureId"] = id
        emit("onError", payload)
    }

    private fun unbind() {
        generation++
        initializing = false
        releaseOwnedUseCases()
    }

    private fun releaseOwnedUseCases() {
        analysis?.clearAnalyzer()
        val useCases = listOfNotNull(preview, imageCapture, analysis)
        if (useCases.isNotEmpty()) provider?.unbind(*useCases.toTypedArray())
        camera = null
        preview = null
        imageCapture = null
        analysis = null
        bound = false
    }

    override fun onPause(owner: LifecycleOwner) {
        paused = true
        if (!capturing) unbind()
    }

    override fun onResume(owner: LifecycleOwner) {
        if (!explicitlyPaused) {
            paused = false
            startCamera()
        }
    }

    override fun onDestroy(owner: LifecycleOwner) = dispose()

    override fun dispose() {
        if (disposed) return
        disposed = true
        unbind()
        activity.lifecycle.removeObserver(this)
        channel.setMethodCallHandler(null)
        scanner.close()
        analysisExecutor.shutdown()
        captureExecutor.shutdown()
        onDisposed(this)
    }

    private class UnsupportedCaptureResolution : IllegalStateException("Capture stream below document resolution")

    companion object {
        private const val TAG = "ExpressCamera"

        private fun hasDocumentResolution(size: Size): Boolean =
            maxOf(size.width, size.height) >= 1280 && minOf(size.width, size.height) >= 720
    }
}
