# 2026-10-29最终验证与交付

## 本轮基线与范围

以用户已提交的09c5729为基线，复核8adae3f文档/中文说明、28ea767纯本地化及OCR/相机实现、09c5729开关位置。保留移除云端AI、自建OCR及AI重整库房的决定，保留OCR行距下方开关，不恢复旧入口。开始时工作区干净，此前134条Trellis改动已包含在用户提交中，不归为本轮未提交修改。

本轮按用户追加调整极速扫码UI、移除使用说明、入库拍摄顶部完整单号居中。只修改视觉；相机业务函数、捕获与单号绑定、扫描和队列逻辑保留。补历史重识别弹窗退出有效标记及ZIP操作完成边界、改名ZIP识别兼容，修正过时/无实测支持的文档与少量误导性注释。

## 发现与修复

- 历史弹窗route Future已返回但退出动画未结束时，mounted仍true；增加dialogOpen标记，拒绝迟到结果，处理晚到派生图，引用未知时保留凭证。真实Widget覆盖该时间窗。
- ZIP addFile、close、解压必须等待对应Future；原库同步编码/flush机制不能据此推断已复现损坏，本轮修复的是资源关闭与异常归属边界。
- 识别ZIP后显式解码，不再由文件扩展名选择压缩格式；大写.ZIP和改名.bin均可恢复，正常ZIP不额外复制。
- README开关位置、旧124测试总数、提升300%、恒定低于10MB、毫秒级/满帧/不模糊保证等缺少证据，已改为实际能力与验证边界；纯数据备份照片仅在原路径存在时保留，不误称智能重映射。
- Web注释中注册链接“免密”改为自动带店号，注册仍需密码；批量单据id为客户端键或UUID，单号输入不截断，返回列表包含未匹配号。均不改运行逻辑。

## 验证证据

- 完整Flutter：**121通过、1项显式可选联网测试跳过**，日志`/tmp/ocr-camera-ui-final-tests.txt`。跳过项需要一次性隔离Django服务地址，未针对开发库执行。
- 完整Flutter分析：**0错误、0警告、22项既有信息**，日志`/tmp/ocr-camera-ui-final-analyze.txt`。命令因既有信息以非零退出，不表述为完全无提示。
- 极速UI定向4/4，长单号居中、360宽100字符/1.3字号无溢出；扫码、锁号、保存保持相同平台视图Element/Key/尺寸，平台create仅1次、无额外resize，画框使用原crop。见express-ui-implementation.md。
- 用户提交复核定向28/28，ZIP真实文件/独立库闭环3/3，含照片字节、单据、库存、改名ZIP及坏包保留原库。已包含于完整Flutter回归，不重复加总。见submitted-changes-review.md。
- Android原生JUnit **8/8**（相机策略5、OCR行分组3），`testDebugUnitTest`成功；日志`/tmp/ocr-camera-ui-native-tests.txt`。没有远程依赖更新。
- Android arm64 release成功48.7秒，日志`/tmp/ocr-camera-ui-release-build.txt`。核对versionName1.0.11、versionCode13、仅arm64-v8a及有效签名，沿用Android Debug证书。
- Web **25/25**、vue-tsc与Vite构建通过；仅有依赖中非阻塞纯注释提示。用户修改的4个后端Python文件去除docstring后与b9be3f9可执行语法树一致，没有为了注释改动运行数据库迁移或破坏性测试。
- 相关文件diff检查通过。无修改远程服务器或真实业务数据。

## 版本产物与预览

- `releases/app-v1.0.11+13.apk`，60753192字节。
- SHA256：`4603de812d8c48cfebcd2225a88b81cc4d0efa3ee4dc7aa624fe35bed4656b04`。
- `releases/express-ui-scan-v1.0.11+13.png`、`releases/express-ui-locked-v1.0.11+13.png`。主会话已查看两图，预览来自当前生产UI与静态示意相机背景，不是真机拍摄。

## 真机限制

当前adb没有设备，实际相机调用耗时、ZSL生效、帧率、补光/暗光、移动模糊及PSS没有实测。软件/UI验证与APK交付完成，不声称与系统相机同速；此前相机与OCR任务仍保留真机待验，不能误归档。用户可安装本包按docs/OCR开关与拍照验收说明.md验收。
