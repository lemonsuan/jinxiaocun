# 研究：iPhone原生适配难点与分阶段规划

- 查询：现有Flutter仓储App迁移到iPhone，需要补哪些工程、相机、离线OCR、文件和系统集成；与本轮拍手Safari页面如何区分。
- 范围：仓库代码、本机只读工具检查、Apple／Flutter／ONNX Runtime官方资料；仅研究，不实施产品代码。
- 日期：2026-10-29。

## 给用户的结论

可以适配，主要难点不是把Flutter页面重新画一遍，而是补齐 **iOS宿主工程、连续扫码拍照原生桥、离线OCR原生桥**。现有订单、库存、数据库、同步、OCR后处理和大部分页面可复用，但不能直接把Android安装包或`.so`用于iPhone。

本机已有 **Xcode 27.1、iOS SDK 27.1、CocoaPods 1.16.2**，开发工具不是当前首要阻塞。仓库实际没有`mobile_app/ios/`，尚不能直接构建iOS；`.metadata`中记有ios历史条目不代表工程仍存在。没有检查签名身份、开发者Team或真机连接，也没有运行iOS构建。

现有拍手Web页面在Safari上的适配是另一件事：它负责填报、上传补充照片／收款码、查看本人订单和返款，不需要把Android相机或PaddleOCR搬到浏览器。可以先验收Safari报单，再独立推进原生iPhone仓储App。

## 确定证据与可复用边界

| 文件或只读检查 | 已确认事实 |
|---|---|
| `mobile_app/`目录清单、`.metadata:14-33` | 没有ios目录、Runner工程、Info.plist和iOS原生注册代码；元数据留有旧ios标记。 |
| `mobile_app/pubspec.yaml:9-28` | Flutter、SQLite、路径、HTTP、图片、文件选择、分享和camera等已有跨平台依赖。 |
| 本机缓存插件podspec | camera_avfoundation 0.10.1、image_picker_ios 0.8.13+6最低iOS13；mobile_scanner 7.2.0使用Apple Vision，podspec最低iOS12；不能据插件可用就宣称自研桥已支持iOS。 |
| `mobile_app/lib/src/ui/custom_camera_page.dart:108-116` | 普通拍照已走camera插件、JPEG、关闭音频，适合作为iOS首阶段拍照路径。 |
| `mobile_app/lib/src/ui/express_inbound_page.dart:350-375` | 极速入口明确拒绝非Android，并直接创建AndroidView；换系统后不会自动出现iOS相机。 |
| `mobile_app/lib/src/platform/express_camera_channel.dart:17-25,71-88` | 已有稳定capture/reset/torch/focus/pause/resume/dispose契约，可复用Dart接口，iOS需另写实现。 |
| `mobile_app/lib/src/platform/paddle_ocr_channel.dart:37-70` | 本地OCR统一MethodChannel及许可代际可复用；没有对应iOS原生处理器。 |
| `mobile_app/android/app/src/main/cpp/CMakeLists.txt:5-18` | 当前只链接Android arm64-v8a `.so`、android/log/jnigraphics，不能直接链接到iOS。 |
| `mobile_app/android/app/src/main/cpp/ocr_v6_jni.cpp:64-95` | JNI入口依赖JNIEnv、AndroidBitmap，必须换成Apple图片到RGBA的适配层。 |
| `mobile_app/android/app/src/main/cpp/ocr_v6_engine.h:20-29`、`ocr_v6_engine.cpp:3-15` | 生产引擎以RGBA、宽高和stride为接口，主要计算核是标准C++及ORT，具备抽成共享核心的条件；不是从零重写模型推理。 |
| `mobile_app/android/app/src/main/kotlin/.../ocr/OcrRowGrouping.kt:13-61` | 识别框分行／倾斜校正当前在Kotlin，iOS必须移植或提到共享C++；否则文字识别正常也可能列行错位。 |
| `mobile_app/tools/ocr/build_runtime.py:23,83-99` | 当前固定ORT1.21.1、Android API28、arm64-v8a、CPU reduced runtime，脚本不是iOS构建脚本。 |
| `mobile_app/lib/src/ui/data_management_page.dart:448-466` | Android自动输出Downloads，非Android目前仅生成App内还原点，需补“存储到文件／分享”完成导出。 |
| `mobile_app/lib/src/ui/app_home.dart:4857-4887` | 部分单据照片导出已有非Android的SharePlus分支，可复用并补实际Files/iCloud场景。 |
| `mobile_app/lib/src/data/local_inventory_scope.dart:7-15` | 配置／业务库已通过path_provider定位，可保留工作区隔离逻辑，不重建店铺或修改内部UUID。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:1342-1378` | 照片当前存绝对路径，备份还原有imagePathMap／basename映射；跨系统恢复必须验证，纯数据备份不能凭空带来另一台手机的照片。 |
| `mobile_app/lib/src/application/shop_sync_service.dart:36-45`、`app_home.dart:68-70` | 同步以进前台和15秒前台定时器驱动，不能据此承诺iOS锁屏后仍持续同步。 |

以上Kotlin路径中的`...`指`com/xcy/inventory/inventory_mobile_app`目录；只读发现不代表已移植或编译验证。

## 难点单列与建议方案

| 优先级／难度 | 难点 | 建议实施与验收 |
|---|---|---|
| P0／中 | 缺iOS宿主工程 | 在独立实施阶段补Runner、Bundle ID、资源、插件注册与构建设置；先让OCR关闭时的普通拍照、本地库存和店铺缓存跑通。保留Android目录与现有数据格式。 |
| P0／高 | 本地PP-OCRv6_small不能直接复用Android二进制 | 保留用户选定v6_small，抽共享C++，制作iOS设备arm64与所需模拟器切片的ORT framework/XCFramework；补Swift/Objective-C++桥、模型／字典资源打包、manifest校验、RGBA/EXIF转换、Kotlin分行算法、串行队列与取消。用同一批真实清单验证文本、行列和数量，不只测“能加载”。 |
| P0／高 | 极速持续扫码和正式拍照 | 用AVFoundation单个AVCaptureSession承载预览、条码metadata输出和正式照片输出；通过UiKitView注册现有viewType或明确平台适配层。不能分别让mobile_scanner和camera各抢一次摄像头，再宣称复用会话。 |
| P0／高 | 保存反馈与取景裁剪一致 | AVFoundation照片回调不等同文件已可靠保存；JPEG数据写完再发onCaptured，保持captureId和完整单号绑定。重建iOS预览坐标、旋转、镜像、EXIF和裁剪映射，不能照搬Android ViewPort。保持轻反馈、无闪白和同一预览身份。 |
| P1／中 | 权限与店铺局域网连接 | 按实际API配置相机/照片用途说明。HTTP、IP地址、本地网络授权和ATS分别验证，优先HTTPS；本地网络授权不是ATS例外的替代。拒绝权限必须可恢复，本地模式不得因此强制联网登录。 |
| P1／中 | Downloads不通用、备份与照片移机 | iPhone改为Files／分享导出，导入文件先落App可管理目录；验证取消、iCloud文件、磁盘不足、ZIP和照片跨Android/iOS恢复。不要自动写Android公共目录，也不要仅生成App内备份就提示已导出到外部。 |
| P1／中 | 后台与杀进程恢复 | 依赖现有SQLite持久任务和幂等同步，在回前台继续；短暂后台任务仅用于必要收尾。iOS后台调度由系统决定，不能以Android Service式常驻或15秒定时器作为保证。 |
| P1／中 | 低性能设备与图片内存 | FP32双模型约31MB只是资源文件，不是峰值内存。先CPU保证结果一致，控制单张解码尺寸和队列；再按设备测耗时、P95、内存及温度，不预先承诺比Android快或无感。 |
| P1／中 | 页面、手势和键盘 | 已有SafeArea可复用，仍须检查刘海/灵动岛、底部手势区、系统返回与弹窗、中文输入、键盘遮住确认、长单号、大字号和横竖屏。需要真实iPhone，模拟器不能替代相机与OCR资源验证。 |
| P1／中 | 签名与交付 | 确定Team/Bundle ID、测试手机与分发方式；开发证书用于真机，TestFlight/App Store需相应开发者计划及签名流程。没有验证已有账号状态，不写“已可发布”。 |
| P2／需决策 | 最低系统与机型 | Flutter及本机常用插件的基础门槛可到iOS13；新相机加速API、所选ORT打包配置可能抬高目标。应先列真实设备，再决定最低系统，不能单凭Flutter门槛承诺所有旧iPhone可用。 |

## OCR方案取舍（仅规划，不替用户更换模型）

1. **建议基线：保留PP-OCRv6_small＋ORT CPU。** 保持模型、字典和主要后处理一致，便于对照Android结果；代价是自建Apple运行时和桥接。现有两份ORT资源为Android/ARM优化产物，应在目标Apple运行时实际加载及对齐输出后再确定能否原样复用。
2. **CoreML Execution Provider后续评估。** 可能利用Apple硬件，但不是“打开开关就加速”：现有basic minimal CPU构建不能直接变成CoreML构建，需匹配extended/相应运行时与模型支持并测回退、动态宽度、内存和总耗时。官方[自定义ORT构建](https://onnxruntime.ai/docs/build/custom.html)说明了basic/extended支持边界。
3. **Apple Vision仅作为比较候选。** 可减少自带推理依赖，但不再是同一Paddle模型，中文、编码、数量、行列及系统版本差异须重新验收；Vision文字框并不自动等于现有商品结构。支持语言和识别精度/速度模式应按实际系统查询，参见[VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)。当前没有更换引擎的授权决定。

## 相机加速的系统约束

Apple提供[AVCapturePhotoOutput](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput)、[AVCaptureMetadataOutput](https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput)及[拍摄就绪协调器](https://developer.apple.com/documentation/avfoundation/avcapturephotooutputreadinesscoordinator)，可分别承载正式照片、条码及快门可用状态。建议按原有“照片保存后才成功”的契约实现。

本机Apple iPhoneOS SDK的`AVCapturePhotoOutput.h`显示ZSL和快速连拍优先等能力带iOS17可用性及设备配置支持检查；快速连拍优先还允许自动降低拍照质量以跟上速度。因此不应为了与系统相机体感接近默认牺牲单据清晰度，也不应把iOS17加速API当全部iPhone必备。低系统保留正式照片路径并做明确降级，实际支持需运行时判断。

## 本轮拍手Safari页面的独立适配清单

用户最新范围是“作业／已做作业／我的”三个入口，作业详情为可视区域宽高各90%的居中弹窗；只填文本和上传、追加照片，不恢复拍手图库。我的收款资料含微信号、支付宝手机号/收款人和收款码，填报页可打开同一份资料编辑弹窗，关闭必须保留订单草稿。

这些页面不依赖原生OCR移植，应在本轮Web验收中单独检查：

- **Safari视口与键盘：** 90%应以实际可视区域计算，长内容在弹窗内滚动；核对地址栏伸缩、软键盘、底部手势区，防固定提交按钮盖住输入。必要时按VisualViewport变化协调滚动，不能仅用桌面Chrome改390宽冒充Safari实测。
- **表单与弹窗草稿：** 详情／收款弹窗关闭或切Tab后保留当前订单、快递号、补充文字和待上传照片；中文输入法组合态、自动填充和“下一项”键要实际测试。
- **照片/收款码格式：** iPhone文件可能是HEIC/HEIF、JPEG或PNG，`accept=image/*`只是选择提示，不能证明浏览器或服务端能解码全部格式。对实际上传链核对MIME、扩展名、EXIF方向、体积限制及服务端支持；若未支持HEIC，给出清晰可恢复提示或另行实现经测试的转换，不能静默丢图。官方Flutter[image_picker资料](https://pub.dev/packages/image_picker)也区分了模拟器HEIC限制与真机测试。
- **隐私与权限：** 收款码仅本人及有权本店管理员可访问，不得生成匿名公共URL；不同拍手不能互见，账号切换后旧blob与请求清理。资料更新不应改写已返款历史快照，未返款按当前资料展示。
- **Safari复制/上传/恢复：** HTTP局域网下剪贴板可能不可用，应保留手动复制；检查文件选择取消、切后台再回来、会话失效、提交结果未知重试，不重复创建订单。
- **现有基础：** `frontend/src/worker/worker.css:50,62`已有safe-area底部留白，`frontend/index.html:6`有viewport meta；这些只是基础，不等于新90%弹窗和键盘覆盖已验证。

## 建议实施次序与每阶段放行条件

| 阶段 | 交付内容 | 放行条件 |
|---|---|---|
| A：边界与基础工程 | 确定真实机型/最低系统、分发方式；补iOS宿主与插件，OCR关闭下普通拍照、离线库存、店铺缓存、Files备份 | iPhone真机可安装，原数据/照片/店铺作用域不丢；错误权限可恢复。 |
| B：离线OCR验证 | v6_small模型与字典打包、Apple ORT、共享核心、分行算法、取消及Dart桥 | 同组清晰/倾斜/长行/表单样张与Android对齐，超时可恢复，开关关闭零调用；先独立推理再接极速队列。 |
| C：连续扫码拍照 | AVFoundation单会话、UiKitView、单号锁定、裁剪、保存事件、前后台 | 连续20单无错配漏单，保存前无成功反馈；各机型光照下记录中位数/P95和模糊/失败。 |
| D：整合与资源 | 统一相机租约、队列/同步恢复、导出/导入、键盘/大字号、低内存与温度 | 全量Flutter回归、iOS构建、真实设备耗时/内存及后台恢复验收，不以模拟器数字代替真机。 |
| E：分发 | 签名、TestFlight或确认的测试分发、隐私说明和版本产物归档 | 确认账号/证书与实际安装、升级保留数据；不承诺审核通过时间。 |

未给固定工期：目前尚无iOS原生验证、目标机型或分发选择，OCR和相机两项需要先做技术验证，之后才适合估算工作量。

## 官方资料与版本核对

- [Flutter iOS开发环境](https://docs.flutter.dev/platform-integration/ios/setup)：Xcode、CocoaPods、真机开发模式与开发证书；本轮仅只读核对本机工具，没有执行安装、许可接受或账号操作。
- [Flutter iOS构建发布](https://docs.flutter.dev/deployment/ios)：最低目标应满足Flutter、插件和使用API的最大要求；IPA、签名与TestFlight/App Store流程。
- [Flutter UiKitView](https://api.flutter.dev/flutter/widgets/UiKitView-class.html)：原生视图需有边界约束，生命周期随State；建议保留同一视图避免反复释放重建。
- [ORT iOS构建](https://onnxruntime.ai/docs/build/ios.html)、[自定义构建](https://onnxruntime.ai/docs/build/custom.html)、[ORT格式](https://onnxruntime.ai/docs/performance/model-optimizations/ort-format-models.html)：iOS运行时需另外构建，reduced/minimal与模型格式相匹配。
- [ORT v1.21.1 Apple构建配置](https://github.com/microsoft/onnxruntime/blob/v1.21.1/tools/ci_build/github/apple/default_full_apple_framework_build_settings.json)：该版本官方配置有device arm64与simulator arm64/x86_64。普通iOS说明页仍只列x86模拟器，不能据此断言Apple Silicon模拟器不支持；本项目所需reduced CPU配置须单独验证。默认完整配置的iOS目标15.1并不是所有自定义构建不可更改的最低版本。
- [Apple本地网络用途说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)、[本地网络隐私说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)、[ATS本地网络配置](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)：局域网授权与传输安全分别处理，目标系统/IP/HTTP组合要真机验证。
- [Apple照片权限](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription)：读写与仅新增照片用途不同，按实际API配置，不自动申请无关权限。
- [Apple文件目录](https://developer.apple.com/documentation/technologyoverviews/files-and-directories)、[系统文档选择器](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)：使用系统提供的容器和用户选择的文件位置，导出到App沙盒之外需要对应交互。
- [Apple后台策略](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)：后台时机由系统调度，不能承诺持续定时执行；重要单据应先持久保存再可恢复处理。

## 相关规范与未验证事项

已阅读`.trellis/workflow.md`、`.trellis/spec/frontend/index.md`、`directory-structure.md`、`quality-guidelines.md`中的Native Offline OCR与Continuous Express Camera契约，并参考当前子任务PRD。

未创建或修改iOS工程、产品代码、依赖配置、证书、任务状态或Git；未测试iPhone相机、Safari、新上传接口或iOS推理，不报告iOS已编译通过。现有iOS插件缓存只证明依赖提供相应实现，不代表当前应用已完成平台集成。本文中Swift/AVFoundation、ORT打包与Vision比较都是后续建议，不是已实施事实。
