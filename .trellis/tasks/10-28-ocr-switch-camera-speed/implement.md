# 实施与验证计划

## 进入实施前

PRD、design、implement及真实jsonl已齐备并验证；用户在完整方案（含无闪烁反馈）之后明确回复“开始”，已执行task.py start，状态in_progress。实施/检查由Trellis子代理完成，主会话负责整合、规格、版本、构建和本地提交。

## 顺序及文件责任

1. OCR实施代理：新增设备级策略、配置读写、所有图片OCR与AI门禁、队列暂停/恢复、数据库许可复验；负责app_home/express_inbound/ai_rebuild页面与测试，完整适配CapturedPhoto。相机实施代理不改这些共享UI。
2. 相机实施代理：CapturedPhoto领域类、CaptureWorkCoordinator租约类、custom_camera_page、Android ExpressCameraView及其测试。普通页只返回原图元数据，取消闪白改轻触觉和局部成功；原生自适应ZSL、单次回退、分段耗时。与OCR代理先固定类API。
3. 跨责任契约：CapturedPhoto.imagePath:String、crop:CaptureCrop、previewAspect:double?；CaptureWorkCoordinator.acquire()->幂等release、isActive及变化通知。相机页持租约，队列检查并监听；极速页接租约和无闪烁UI由OCR代理负责。新文件最终命名开工前双方一致。
4. 独立trellis-check复核开关绕过、关闭过程中写入竞态、重复/迟到回调、原图引用、队列唤醒、相机lease泄漏、ZSL回退和成功反馈顺序；精确修复发现项。
5. 主会话整合规格和已知限制，验证并递增App版本后Android arm64 release，核对APK版本、内容与签名，根releases归档。2026-10-29最新版本为1.0.11+13；前一轮1.0.10+12候选未归档，不将其构建结果代替当前验证。仅提交本轮任务文件，保留用户已经提交的其他改动；旧相机/OCR真机任务不归档。

## 必要验证

- 临时真实SQLite：默认/重启/切工作区/备份不覆盖开关；关闭新单needsReview无任务无虚增库存，原pending暂停/恢复、原图留存；取消及off→on拒旧结果，手工修改不被覆盖。
- Channel/HTTP：关闭零本地调用及零图片远程调用，处理中取消非failed，纯文本AI与纯本地禁网回归。
- 队列：相机租约时无新裁剪或OCR，嵌套和重复释放正确，退出唤醒但off不唤醒；捕获过程不等待排空。
- Widget/状态：开关和准确文案、无整屏闪白、延迟保存无成功/失败不震动、下一单清反馈，普通原图返回与迟到草稿保护。
- 图片：EXIF方向、框裁剪、JPEG magic与扩展名、失败保原图。
- dart format仅相关文件；flutter analyze --no-pub（区分既有28项提示）及完整flutter test --no-pub；Android相关JVM测试、Kotlin编译和release构建。
- 无设备：adb已空，留同机普通/极速、OCR开关、日光/暗光各20次中位数/P95及移动模糊/清晰度验收，不虚报系统相机级速度。

## 风险与回退点

不强制中断native推理或kill进程；保留旧图片、job token和状态保护。普通相机调用者只有app_home，必须同步更改返回泛型。ZSL失败仅单次回退同画质。出现新架构/兼容风险时回到planning说明，不无限扩大任务。

## 2026-10-29继续实施范围

当前以用户09c5729及之前纯本地化、文档提交为基线，工作区开始时干净；旧分工中AI相关入口已由用户移除，不重新实施。UI代理只调整极速页呈现及必要测试，保留扫码/捕获/保存/原生逻辑和预览身份，移除使用说明，顶部单号居中；检查代理复核用户提交，修历史弹窗关闭与迟到结果清理等确定问题。主会话检查前后端注释提交的行为一致性、修正不实性能文档，并统一运行当前完整移动端测试/分析/Android构建；UI交付前查看mock预览截图。
