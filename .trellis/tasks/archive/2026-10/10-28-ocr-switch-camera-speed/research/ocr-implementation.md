# OCR开关与Flutter整合实施记录

## 已完成

- 配置库新增ocr_enabled，默认开启，设备作用域共享OcrAccessPolicy。保存切换递增generation，旧许可即使关闭后再开启也失效；不同设备不共用设置，业务备份不导出或覆盖开关。
- PaddleOcrChannel生产构造必须提供设备策略，推理前后验证同一许可及其策略归属。AiInboundExtractor图片路径在自建OCR、云端AI实际发送前后同样验证，纯文本AI不受图片开关影响。
- 队列retain/release跟随主页与极速页生命周期，设备策略或拍摄租约变化时重新调度。无owner、OCR关闭或相机激活均不启动新任务，异步查询返回后再次检查。当前处理取消不标failed、不清原图，历史pending保留，开启后恢复。
- updateInboundOcrResult、图片AI/历史重识别overwrite在事务开始和结束检查许可；关闭过程中整笔明细/库存变更回滚。重识别比较原单据照片路径、状态、单号/方案/结算等元信息和商品快照，拒绝覆写期间的手工修改。
- AppHome设置页增加OCR总开关。普通拍照接收CapturedPhoto，先保存并展示原图；关闭时跳过像素处理及OCR，开启时离开相机后一次裁剪/校正/JPEG编码。删除宽图擅转和PNG覆写JPG的旧链路。后处理失败保原照片。
- 普通草稿独立记录是否待补录，不以提交时开关状态冒充识别完成。原图复制/绑定的短窗口屏蔽入库输入与确认，确认时冻结输入；异步识别不覆盖新的图片/手工商品，提交完成也不清除期间新输入的下一单号。
- 极速关闭新单显式needsReview且不创建自动识别任务；准确区分待补录、识别暂停和退出拍摄后处理。正式保存后轻触觉和局部成功勾，不闪屏、不提前成功，不为动画延迟下一单。
- 历史手动旋转生成独立JPEG派生图，确认事务通过后才替换照片引用，未引用派生图安全清理。原凭证不被预览操作原地覆写。
- AI批量重整遇关闭停止后续任务、不计失败，保留暂停结果文案和已完成数量。

## 本代理修改范围

新增application/ocr_access_policy.dart、test/ocr_switch_test.dart、test/ocr_switch_widget_test.dart；修改application/express_processing_queue.dart、capture_image_processor.dart（安全旋转）、data/local_inventory_database.dart、platform/paddle_ocr_channel.dart、ocr/ai_inbound_extractor.dart、ui/app_home.dart、express_inbound_page.dart、ai_rebuild_warehouse_page.dart及原channel/navigation测试。

相机领域对象、租约实现、普通相机页及Android相机由相机代理负责。本代理没有修改版本号、提交Git或打包。

## 定向验证

最终命令：

```sh
flutter test --no-pub test/ocr_switch_test.dart test/ocr_switch_widget_test.dart test/paddle_ocr_channel_test.dart test/express_navigation_test.dart test/express_persistence_test.dart test/local_mode_network_test.dart
```

**31/31通过**，日志`/tmp/ocr-switch-focused-final.txt`。新增10项真实配置/事务/Channel/HTTP/队列测试，新增1项真实AppHome Widget回归同时验证原图复制门禁及关闭拍照后重新开启仍待补录。既有20项识别平台、持久化、退出与完全本地网络限制继续通过。

核心断言包括关闭零平台调用、off→on拒旧返回、拍摄期间暂停及退出唤醒、关闭新单无job无库存、处理中关闭保pending和原图、两个库存写入事务在关闭时完全回滚、手工元信息不被旧AI覆盖、自建OCR返回时关闭不继续云端请求、纯文本AI仍可用。持久化测试直接读磁盘配置行，避免仅复用缓存的假阳性。

先前静态分析确认无编译错误，当前根会话统一最终analyze及全量测试、Android构建；本代理不将未跑的最终检查标记为通过。git diff --check通过，相关Dart已格式化。

## 限制

没有连接真机，不能宣称达到系统相机速度或测得PSS下降。关闭只阻止新识别及旧结果写入，不在native Run中强行释放模型；已运行推理安全结束，沿用原服务空闲释放策略。新图只保存时商品库存为零，后续可手工补录或开启OCR后主动重识别。
