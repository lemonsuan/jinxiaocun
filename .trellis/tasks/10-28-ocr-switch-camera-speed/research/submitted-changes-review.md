# 用户已提交改动复核（2026-10-29）

## 复核范围

以当前 `09c5729` 为基线，检查 `b9be3f9..HEAD` 中与移动端相关的代码及用户最新三次提交：`8adae3f` 文档/中文说明、`28ea767` 移除云端AI/自建OCR/重整库房并整合OCR与相机、`09c5729` 将OCR开关移至行距下。保留用户的纯本地PaddleOCR决定及设置位置，没有恢复已删功能。

不改Trellis基础设施、不改版本或提交Git；`express_inbound_page.dart`的新视觉由另一实施者负责，本报告不提前代报该视觉验收或主会话最终构建。

## 已发现并修复

### 历史识别弹窗退出动画中的迟到结果

`app_home.dart` 原先仅以 `dialogContext.mounted` 判断弹窗是否仍可更新。但 `showDialog` 的Future已在路由返回时完成，退出动画期间组件仍可能mounted；此时迟到裁剪可新建派生图，晚于外层临时图片清理，也可能将退出中的弹窗更新成识别结果。

局部修复：增加函数级 `dialogOpen`，路由Future完成立即失效；裁剪、识别和异常反馈前同时检查弹窗有效性与mounted。迟到未引用派生图统一安全清理；工作区已关闭或引用无法验证时保留文件，避免误删有效照片。原图及数据库业务语义未变。

`ocr_review_test.dart` 新增真实Widget分支：强制返回后不推进退出动画，模拟OCR回包，断言退出中的弹窗不再生成确认覆写界面、无异步异常、原库存不变。原有处理中系统返回被阻止、结果返回后可正常退出的分支保留。

新增多条件守卫的3项大括号分析提示已机械修复。

### ZIP导出与恢复的异步完成边界

复核README备份承诺时，检查项目实际锁定的archive 3.6.1源码：`ZipFileEncoder.addFile/close`及`extractFileToDisk`都返回Future，原数据库方法没有等待。该版本编码与flush大部分在首次await之前同步完成，因此不能据此断言原实现必然漏条目或损坏ZIP；确定问题是文件/归档关闭完成和异常没有完整归属导出或恢复Future。

按主会话授权，补齐两个addFile、归档close及解压的await，保持API、格式、数据和照片路径策略不变。新增实际ZIP导出恢复及坏ZIP请求失败保留旧库的回归。没有另建备份框架或宣称恒定内存。

进一步按主会话授权修复文件头与扩展名冲突：ZIP恢复入口改用 `InputFileStream + ZipDecoder.decodeBuffer + extractArchiveToDiskAsync` 明确解码，等待提取并在finally关闭输入流，不再让库按原名字判断格式。正常ZIP不复制，改名或大写扩展名同样可恢复；保持库原有安全路径检查与流式单文件写入方式。

## 调用链结论

- 当前lib/test中没有已删除AI配置页、重整库房页、AiInboundExtractor、自建OCR模式或其配置方法的生产引用。原生OCR和Paddle通道继续可用；没有为删功能新增数据库迁移或清空历史。
- OCR开关确实位于“我的”页OCR行距之后，仍调用同一设备配置持久化方法；保存中禁重复切换，失败反馈且保留之前UI状态。开关跨工作区共享而业务备份不覆盖。
- Paddle通道调用前后均检查设备代际许可，旧许可不能跨策略使用；关闭再开启拒旧结果。后台队列在相机租约及关闭期间不启动后续重任务，owner释放会移除监听。
- 关闭新单使用needsReview且不建立自动job；原pending暂停恢复，不误写failed。商品与库存写入事务首尾校验许可；历史覆写额外比较原图片、商品、状态和元信息，旧结果不能覆盖手工改动。
- 普通原图先私有保存再绑定，保存窗口阻止提前确认。未识别图片的草稿状态不依赖确认时开关；确认递增草稿代际，迟到OCR不会回填已提交单据。
- 普通相机只交还正式原图及裁剪几何，未重新加入同步整图处理或闪白。调用方在开启OCR时一次后台处理，关闭时直接保留原照片。

## 极速UI冻结后的交叉检查

读取UI实施者冻结产物 `express_inbound_page.dart`、`express_camera_chrome.dart`及测试：AndroidView在固定Expanded/同父节点及Key下，顶部、状态和操作槽固定高度，扫描/锁号/保存只切覆盖层。拍摄框直接从现有 `CaptureCrop(.04,.12,.96,.88)`计算，焦点坐标仍按实际预览尺寸归一化；未见相机调用或裁剪身份回归。

单号为完整Text，居中、softWrap、不设maxLines或省略；固定头区容纳普通单号，极长及放大字体可滚动。静态CustomPainter遮罩与角标隔离重绘，没有新增动画或模糊。UI实施者4项测试证明组件创建一次/零resize、长号不溢出及旧导航；主会话仍需看视觉样张和完成最终全量检查。样张是静态示意，不是真机性能证据。

## 实际验证

- `flutter test --no-pub` 指定以下7个文件，**28/28通过**：`ocr_review_test`、`ocr_switch_test`、`ocr_switch_widget_test`、`paddle_ocr_channel_test`、`express_persistence_test`、`custom_camera_handoff_test`、`capture_work_coordinator_test`。日志 `/tmp/submitted-review-tests.txt`。
- 初轮完整Flutter分析没有错误或警告，25项信息中本次守卫带来的3项大括号提示已修复；其余为现有上下文/弃用API提示。
- 最终定向分析 `app_home.dart` 与 `ocr_review_test.dart`：**0错误、0警告，3项既有信息**（另外两处单据操作context及其他页面withOpacity）。日志 `/tmp/submitted-review-target-analyze.txt`。最终全量结果由主会话统一确认。
- 相关Dart格式化及 `git diff --check`通过；没有运行真实设备或发布构建。
- 新增 `backup_zip_roundtrip_test.dart` 最终 **3/3通过**，日志 `/tmp/submitted-review-zip-tests.txt`：两张照片导出完成可立即读取，恢复到独立设备后单据、图片原字节和库存均一致；同一备份改名为`.bin`和大写`.ZIP`均可恢复；损坏ZIP错误由恢复Future抛出，旧单据及库存保留。
- 最终定向分析同时包含app_home、数据库和上述两个测试文件，仍为0错误、0警告及3项原有信息；没有新增分析问题。

## 交主会话处理与未验证项

- 根README基线称开关位于顶部、“毫秒级解析”、恒定低内存及旧124项全通，已通知主会话；主会话反馈已按实际位置与未实测边界修正文档，最终数量以完整测试为准。
- 文件头ZIP识别与原扩展名冲突已按主会话授权修复并验证，不再作为未修复项。
- 纯数据恢复仅在原绝对路径仍存在时保留图片路径，否则清空；不会搜索本机目录。全量ZIP先在内存组装业务JSON再逐张压图片，不能保证恒定10MB。已给主会话精确证据以修正文档，没有改备份架构。
- 旧task design/spec及研究中的远程图片AI、纯文本AI保留和HTTP测试为历史方案；当前纯本地化提交已覆盖，不应按旧文档恢复这些功能。主会话负责同步最终规格。
- 极速页新视觉由UI实施者进行，须最终检查居中完整单号、窄屏、画框/裁剪对应、AndroidView稳定身份和原捕获流程。
- 无Android真机，实际拍照速度、ZSL生效、清晰度、暗光与内存占用均未实测；没有声称已与系统相机同速。
