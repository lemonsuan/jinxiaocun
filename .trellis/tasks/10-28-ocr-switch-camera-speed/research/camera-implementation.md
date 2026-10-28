# 相机实施结果

## 文件责任与完成内容

- `domain/captured_photo.dart`：不可变`CapturedPhoto(imagePath,crop,previewAspect)`，仅传原图路径及当次取景参数。
- `application/capture_work_coordinator.dart`：共享`instance`及可独立构造的ChangeNotifier租约；嵌套直到全部释放才恢复后台，释放幂等，销毁后的迟到清理安全。
- `ui/custom_camera_page.dart`：正式takePicture及非空文件检查后才轻触觉和局部按钮勾，取消整屏白色覆盖及整屏忙碌暗层；只等一帧局部反馈即返回原图与拍摄前锁定的框参数，不执行裁剪/重编码，不增加固定动画等待。原图不会被本页覆盖。前后台与退出增加初始化代际，旧初始化不抢回摄像头。
- Android `camera/CaptureModePolicy.kt`、`ExpressCameraView.kt`：非低RAM且支持时优先ZSL；绑定失败清理本视图拥有流并同画质单次回退。JPEG95、1920x1080目标和最低1280x720等效约束不变。保留fd.sync和真实保存成功事件，新增captureStarted、文件保存、sync、map及event阶段计时，不记录单号/图像/OCR文本。
- 新增Flutter租约与普通相机真实MethodChannel交接测试；新增JVM模式策略测试。

## 固定交接API

`CapturedPhoto`使用命名参数，imagePath必填、crop默认full、previewAspect可空。调用方app_home由OCR实施者适配。

`CaptureWorkCoordinator.instance`、`isActive`、`addListener/removeListener`、`acquire()->VoidCallback`。普通相机自身持租约，极速页及队列监听由OCR实施者负责。未修改app_home、express_inbound、数据库或OCR文件。

## 实际验证

- Flutter定向：`capture_work_coordinator_test.dart`、`custom_camera_handoff_test.dart`、原`express_camera_test.dart`，**13/13通过**，日志`/tmp/camera-speed-final-tests.txt`。
- 普通Widget通过模拟真正相机MethodChannel：保存未完成无成功勾/触觉，保存失败不成功且可以重试，成功后原图字节不变、路径和裁剪参数交接、仅一次轻触觉、路由退出租约释放。夹具图片仅做原图交接，未用它证明真实清晰度。
- 定向Dart分析：0错误/0警告，4项既有withOpacity信息提示，没有新增问题，日志`/tmp/camera-speed-final-analyze.txt`。
- `:app:compileDebugKotlin`及`:app:testDebugUnitTest --tests com.xcy.yuntuitui.inventory.camera.CaptureModePolicyTest`：通过；JVM **5/5**，覆盖低RAM/不支持、首选成功、清理后回退、回退失败不重试、低延迟失败不扩展模式。日志`/tmp/camera-speed-kotlin.txt`，Gradle已释放。
- `git diff --check`相关文件通过。未改版本、未打release APK、未提交；最终全套回归与归档由主会话执行。

## 物理验收限制

没有Android真机，ZSL实际生效、三流设备兼容、补光、资源占用、同机延迟中位数/P95及移动模糊均未实测。现实现只能证明移除普通相机页同步像素处理与安全模式回退，不能声称原生相机速度。onCaptureStarted只计时，不产生成功事件。
