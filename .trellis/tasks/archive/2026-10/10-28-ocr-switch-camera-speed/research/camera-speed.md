# 研究：拍照关键路径与可验证提速方案

- 查询：普通及极速拍照仍慢，如何去掉可延后的开销并利用CameraX能力，而不降低正式照片细节、不提前提示成功？
- 范围：代码与官方接口资料。
- 日期：2026-10-28。

## 发现

### 现有文件与调用证据

| 文件 | 责任与证据 |
|---|---|
| `mobile_app/lib/src/ui/custom_camera_page.dart:97` | 普通相机使用`ResolutionPreset.high`、JPEG、无音频；106～114初始化、锁定方向、自动对焦。 |
| `mobile_app/lib/src/ui/custom_camera_page.dart:187` | 拍摄等待插件`takePicture`保存，199～209才给成功触觉/闪光；211～218仍等待整图裁剪再在224返回。 |
| `mobile_app/lib/src/ui/app_home.dart:3190` | 全仓唯一生产`CustomCameraPage`调用；返回`XFile`后直接`_processImage`。没有出库或重识别页面依赖此返回类型。 |
| `mobile_app/lib/src/ui/app_home.dart:3233` | 普通图片保存后仍等待`_ensureVerticalImage`，3244开始OCR；1630～1659整图Flutter解码并在宽大于高时编码PNG覆写原路径，存在额外解码和JPEG扩展名与编码不一致风险。 |
| `mobile_app/lib/src/application/capture_image_processor.dart:7` | 现有单次解码、`bakeOrientation`、预览宽高比映射、裁剪和质量95 JPEG；37～51在compute中处理并临时文件写入/rename。可供新调用方复用。 |
| `mobile_app/android/app/src/main/kotlin/com/xcy/inventory/inventory_mobile_app/camera/ExpressCameraView.kt:260` | 极速静态目标1920×1080及最低清单分辨率过滤；268低延迟模式，271闪光OFF、272 JPEG95；278扫码分析，281持续绑定三个use case。 |
| 同上`:327` | 扫码在单号锁定/拍摄时已跳过，且`KEEP_ONLY_LATEST`及单个在跑扫码；不能把仍慢简单归因为重复扫码解码。 |
| 同上`:391` | 当前只有`shutter_to_saved_ms`总耗时，405文件保存回调之后还有`fd.sync`、裁剪映射，再418事件；不能从这一个总值区分曝光/编码/落盘/映射。 |
| 同上`:460` | 裁剪映射只读JPEG尺寸与EXIF/变换，并未完整解码位图；不宜宣称这里在重复做整图像素裁剪。映射不可靠时返回全图。 |
| `mobile_app/lib/src/ui/express_inbound_page.dart:129` | 收到原生保存事件后才允许成功提示，166～195持久入库后reset连续下一单，已没有固定500ms重建。 |
| `mobile_app/lib/src/application/express_processing_queue.dart:67` | 每单`compute`裁剪JPEG后调用OCR；虽然单个串行，仍能与后续相机并发争用CPU及内存。 |
| `mobile_app/android/app/src/main/cpp/ocr_v6_jni.cpp:69` | 本地OCR Engine配置2个线程，并非完全零后台竞争。 |
| `mobile_app/android/app/build.gradle.kts:72` | CameraX core的实际解析版本1.6.0，Camera2/lifecycle/view显式1.6.0。 |

### 最小设计一：普通拍照只交还已保存原图与裁剪元数据

新增明确返回结构（例如`CapturedPhoto`，放domain）：原图`XFile`或路径、归一化`CaptureCrop`、预览aspect。`CustomCameraPage`在`takePicture`保存完成后给现有真实成功反馈，立即返回结构，不执行`CaptureImageProcessor.process`。保留闪光、对焦与拍摄防重入。

唯一调用方`app_home._captureAndRecognizeList`改接收该结构；`_processImage`先将原图保存到应用私有目录并绑定当前草稿。OCR关闭：不裁剪、不解码、不走`_ensureVerticalImage`，直接保留原JPEG、EXIF和手工商品入口。OCR开启：返回相机页面之后复用`CaptureImageProcessor`，单次方向修正+原框裁剪+JPEG编码，再识别；处理出错保留原图并提示可手工录入。

必须让图片草稿先拥有原图，后处理失败或页面销毁不删除仍有业务引用的文件；迟到完成不覆盖新的草稿图片。相册选图不受新相机返回对象影响。不要凭宽大于高擅自转90度，也不要再把PNG写进`.jpg`。

此改动可验证的是“保存完成到离开相机页”不再包含整图处理；不证明传感器快门本身已提速。

### 最小设计二：拍摄页面拥有轻量相机优先租约

应用级小型计数器/租约即可，无需调度框架。普通/极速相机页面挂载时获取，dispose时幂等释放；`ExpressProcessingQueue`取下一任务前若有相机租约则不开始裁剪/OCR，离开后通知继续。已运行一单安全收尾，后续不再启动。嵌套、重复release、异常退出必须有测试；拍照不等待排空OCR，避免以降低竞争为由新增进相机等待。

租约边界建议覆盖整个连续拍摄页面，保证后续快门间隔也不启动重CPU任务。可见文案应准确：“已保存，退出拍摄后识别”，不能一直宣称正在识别。OCR关闭时的永久/待手工状态由开关实施者负责；租约只临时暂停排队。

### 最小设计三：有能力设备启用ZSL，不支持则回退低延迟

官方API已核对：`CameraInfo.isZslSupported`需要API23及PRIVATE reprocessing；本项目minSdk28满足前者但不代表所有设备都支持。ZSL缓存中间结果并选择接近快门时刻的图像；绑定VideoCapture、flash非OFF或开启OEM扩展会自动禁用。当前极速模式无VideoCapture/扩展、ImageCapture flash OFF，但仍须验证现有三流组合和补光行为。参见[CameraInfo官方接口](https://developer.android.com/reference/androidx/camera/core/CameraInfo#isZslSupported())、[ImageCapture官方常量说明](https://developer.android.com/reference/androidx/camera/core/ImageCapture#CAPTURE_MODE_ZERO_SHUTTER_LAG)。

本地已缓存官方1.6.0 API jar经`javap`确认`isZslSupported`、`CAPTURE_MODE_ZERO_SHUTTER_LAG=2`、`ExperimentalZeroShutterLag`和保存回调`onCaptureStarted`确实存在。使用对应OptIn；不能只看支持位就永久失去旧路由。初始化时查选中相机能力，满足时尝试ZSL；绑定失败时释放本视图拥有的use case，使用同分辨率/同质量MINIMIZE_LATENCY重试一次。不引入每次拍照重绑，失败避免无限循环。

ZSL会多缓存图像，不能称为零内存方案。低RAM设备应保守保留MINIMIZE_LATENCY，或至少在文档列出额外缓冲的权衡；保留JPEG95和最低文字分辨率约束，不将降清晰度当提速。不要把“isZslSupported=true”或设置的captureMode当成实际每次ZSL生效的测量证据。

### 分段耗时与成功反馈

保留原生`takePicture`保存完成、文件有效、必要持久同步之后的成功事件；不要删除`fd.sync`来伪造变快，也不要把`onCaptureStarted`当“可以移开”。官方存在独立保存回调接口：[OnImageSavedCallback](https://developer.android.com/reference/androidx/camera/core/ImageCapture.OnImageSavedCallback)。

在同一次capture上记录request→captureStarted、request→onImageSaved、fileSync、cropMap、request→event等毫秒；Flutter另记event→receiptCommit、commit→readyForNext。`onCaptureStarted`只用于计时；无此回调时不虚造0。日志只含阶段/模式/能力/时长，不含完整单号或图像/OCR文本。普通路径增加takePicture耗时与saved→routeReturn，裁剪在调用方另记。

## 建议责任边界

- 相机实现者：domain返回结构、`custom_camera_page.dart`、`ExpressCameraView.kt`、仅相机相关测试。不要改app_home/队列以免与OCR实施者冲突。
- OCR实现者：app_home唯一调用方与`_processImage`、开关持久化与入口、队列的相机优先协调。返回结构与lease类名先固定；现有crop processor无需重写。
- root：规格、版本、构建归档、设备验收记录、提交。

## 建议验证

1. 返回对象不可变，保存失败无成功回调；成功返回前没有crop processor调用；取消、重复快门、页面退出保持可恢复。
2. 原图和裁剪元数据可保留文字框和EXIF方向；JPEG signature与后缀一致；裁剪失败仍可查看原图；旧compute处理图片边界回归继续通过。
3. 租约嵌套/幂等释放；相机激活时零新OCR，当前在跑只收尾一次；离开后继续；开关关闭不被lease释放重新启动。
4. ZSL支持/不支持/低RAM决策，绑定失败单次回退，暂停/恢复与dispose不泄漏三条use case；Android Kotlin编译检查实验API用法。
5. 原`express_camera_test.dart`、真实SQLite队列过期代际/重启测试、普通拍照Widget调用方测试，完整Flutter回归与release构建。
6. 真机每版本至少20次，区分普通与极速、OCR开/关、日光/暗光，记录中位数/P95、失败、图片文字与四角裁剪。成功后立即移动和稳定参考对照；不以更快闪白判定速度。

## 相关规范

- `.trellis/spec/frontend/quality-guidelines.md`的Continuous Express Camera、Native Offline OCR契约。
- `.trellis/spec/frontend/directory-structure.md`的domain/application/platform/UI边界。
- `.trellis/tasks/10-26-express-camera-response/research/camera-bridge-contract.md`及device-validation.md。

## 边界与未验证项

- 当前没有连接Android真机。性能收益、真实三流ZSL兼容、补光与PSS均未测，不提供虚构的毫秒目标或“已与原生同速”结论。
- 最初搜索和官方网页读取多次网络失败，后续CameraInfo、ImageCapture及回调API参考页成功读取；Google Maven源包下载TLS失败。公开API说明与本地1.6.0官方编译产物互相核对，未声称已获取源码包。
- 普通Flutter camera插件当前没有项目级稳定的ZSL配置接口；本轮不建议为了统一ZSL将普通路径也重写成另一套原生相机，否则会扩大兼容和测试面。
- 不把cropForSavedViewport误描述为完整解码，也不建议把几何映射盲目移到Flutter后猜测裁剪。
