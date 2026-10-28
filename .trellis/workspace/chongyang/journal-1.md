# Journal - chongyang (Part 1)

> AI development session journal
> Started: 2026-05-15

---



## Session 1: 实现 OpenAI/Gemini 双格式配置页与提取预览 Dialog

**Date**: 2026-05-29
**Task**: 实现 OpenAI/Gemini 双格式配置页与提取预览 Dialog
**Branch**: `feature/mobile-ocr`

### Summary

完成了 AI 智能提取的双格式协议配置（OpenAI 与 Gemini）、大模型提取核心 GemmaExtractor 重塑、扫码添加右侧魔棒按钮自适应弹窗 Dialog 实现，并清理了所有未引用的废弃方法与变量以保证静态校验完全通过。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `e2d4606` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 2: 升级 AI 提取第二协议为 Anthropic 并重构历史入库卡片交互

**Date**: 2026-05-29
**Task**: 升级 AI 提取第二协议为 Anthropic 并重构历史入库卡片交互
**Branch**: `feature/mobile-ocr`

### Summary

将 AI 双格式提取的第二种协议格式由 Google Gemini 更替为 Anthropic 官方 Messages API 标准格式；同时重构了历史入库的卡片头部渲染，改为了紧凑的 7:3 左右结构布局，右侧支持点击直接反转结算状态，且在卡片展开后最上方还原展示了单据 ID。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `08e2742` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 3: 移除备份恢复确认弹窗的 3 秒倒计时限制

**Date**: 2026-05-29
**Task**: 移除备份恢复确认弹窗的 3 秒倒计时限制
**Branch**: `feature/mobile-ocr`

### Summary

去掉了数据库备份恢复确认弹窗上的 3 秒强制安全倒计时锁，移除了 Timer 与 StatefulBuilder 并精简了逻辑层，使得用户确认后即可直接覆盖恢复，操作更为流畅。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `283a0f7` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 4: 实现移动端默认本地店铺一体化重构与LoginPage编译错误修复

**Date**: 2026-05-30
**Task**: 实现移动端默认本地店铺一体化重构与LoginPage编译错误修复
**Branch**: `master`

### Summary

重构移动端以默认本地店铺为核心，完全消除离线版本二元概念；App 启动静默激活本地店铺并直达主页，个人中心新增 Notion 风格工作区卡片并支持动态切换；同时修复了 LoginPage 第 527 行的 Container 编译报错。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `2ebb91b` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 5: 实现注册页密码二次确认与手机号前后端校验并修复注销失效Bug

**Date**: 2026-05-30
**Task**: 实现注册页密码二次确认与手机号前后端校验并修复注销失效Bug
**Branch**: `master`

### Summary

在注册流程中支持密码二次输入确认与手机号收集，扩展了后端 CustomUser 模型字段 phone 并执行了数据迁移。彻底修复了由于注销时 AppHome dispose 提前 close 物理数据库连接导致 LoginPage 无法写入的 Race Condition Bug，并重新打包部署到虚拟机测试。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `fec4018` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 6: 优化历史入库单展开样式使排版紧凑单号对齐

**Date**: 2026-05-30
**Task**: 优化历史入库单展开样式使排版紧凑单号对齐
**Branch**: `master`

### Summary

对历史入库单的展开样式进行了排版紧凑微调，使展开后的订单号和快递单号在字号与粗细上（14字号加粗）完全对齐，并大幅缩减了明细间隙与条目Padding，优化了纵向显示效率，并重新部署至虚拟机验证。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `4ecaddc` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 7: 清理Git历史大文件并顺利完成远程推送与Tag发版

**Date**: 2026-05-30
**Task**: 清理Git历史大文件并顺利完成远程推送与Tag发版
**Branch**: `master`

### Summary

通过第一性原理分析出本地 master 历史中曾提交了 3GB 的 safetensors 大文件。执行了 git reset --soft origin/master 将本地修改撤回暂存区，并将 download/ 大模型目录彻底 unstage 并加入 .gitignore。成功将精简后的代码合并提交并瞬间 push 到了 GitHub，同时推送了 v1.0.0 标签，成功激活了自动构建 CI/CD 工作流。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `e9b91d1` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 8: 优化CI/CD触发条件为仅限标签发版触发并完成推送

**Date**: 2026-05-30
**Task**: 优化CI/CD触发条件为仅限标签发版触发并完成推送
**Branch**: `master`

### Summary

应用户要求优化了 GitHub Actions 的触发条件，将 master 分支的普通推送触发彻底移除，改为仅在推送版本标签 v* 时才启动自动编译。这一改动已通过本地 Git 提交并在一瞬间成功 push 到远程 GitHub。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `faf924d` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 9: 解决Android在Release混淆下导致的JNI方法找不到Crash

**Date**: 2026-05-30
**Task**: 解决Android在Release混淆下导致的JNI方法找不到Crash
**Branch**: `master`

### Summary

分析出了 Release 模式下 R8 混淆器在优化裁剪中对 NativeOcrResult 类及其主构造函数的混淆裁剪是导致真机崩溃 NoSuchMethodError 的真因。配置了 build.gradle.kts 并新建了 proguard-rules.pro 混淆规则文件，物理保全了 JNI 的数据流通信契约。代码成功推送远程并成功无线部署到真机上进行了闭环测试验证。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `dd262e3` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 10: 实现移动端文本选择弹出菜单的自动汉化国际化配置

**Date**: 2026-05-30
**Task**: 实现移动端文本选择弹出菜单的自动汉化国际化配置
**Branch**: `master`

### Summary

在 pubspec.yaml 中添加了 flutter_localizations 系统级依赖包。在 main.dart 的 MaterialApp 根组件中注册了三大核心 LocalizationsDelegate 并支持中文简体 zh_CN。解决了输入框 TextField 在选中文本时复制、粘贴菜单默认展示英文的问题，代码成功推送 GitHub 并无线部署至真机完成闭环测试验证。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `a0f20f8` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 11: 优化入库单重新识别与AI库房重整逻辑

**Date**: 2026-06-08
**Task**: 优化入库单重新识别与AI库房重整逻辑
**Branch**: `master`

### Summary

优化历史入库单覆盖与库房重整流程，改用高效的局部库存差异冲销，代替缓慢的全局库存台账重算；重构 AI 提取机制为「本地离线 OCR + 云端大模型结构化清洗」，合并提取类为通用的 AiInboundExtractor，并清除所有 AI 默认的硬编码配置；在 UI 上增设商品明细点击弹窗与已压缩标签。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `7e65e0e` | (see git log) |
| `d2da7d4` | (see git log) |
| `7ac2094` | (see git log) |
| `b234e38` | (see git log) |
| `7ba67cb` | (see git log) |
| `8f50de9` | (see git log) |
| `13eeae6` | (see git log) |
| `551c83e` | (see git log) |
| `46b11d6` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 12: 合并OCR与AI配置并精简大标题

**Date**: 2026-06-08
**Task**: 合并OCR与AI配置并精简大标题
**Branch**: `master`

### Summary

合并本地与云端AI/OCR配置，新增自建局域网OCR服务支持；从个人中心移除拍照统计功能；移除各主要Tab顶部的冗余标题大字。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `35aae72` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 13: Add Inbound Calendar and Stock Clearing Features

**Date**: 2026-06-17
**Task**: Add Inbound Calendar and Stock Clearing Features
**Branch**: `master`

### Summary

Implemented an inbound history calendar view (grouped by date) and added a debug long press stock clearing function with double options in App, fixed a BuildContext shadowing bug to avoid crashes.

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `b387493` | (see git log) |
| `6d7eb3a` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 14: Add date-filtered zip export for photo inbound receipts

**Date**: 2026-07-20
**Task**: Add date-filtered zip export for photo inbound receipts
**Branch**: `master`

### Summary

Add a feature to filter and export photo inbound receipts within a selected date range into a single ZIP file on Android and iOS.

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `2dc4d90` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 15: 极速入库连续相机重写与OCR端侧选型调研
<!-- trellis-session: v=2 fp=5260cf5a79f44064 -->

**Date**: 2026-10-27
**Task**: 极速入库连续相机重写与OCR端侧选型调研
**Branch**: `codex/express-camera-response`

### Summary

实现持续扫码拍照会话、完整单号顶部展示、可信照片完成反馈和可恢复后台处理；40项测试通过，发布1.0.5+7 ARM64安装包已归档。官方最新OCR调研建议比较PP-OCRv6 small/tiny，未替换现有模型。

### Git Commits

| Hash | Message |
|------|---------|
| `68db83a` | feat(camera): 重写极速入库连续拍照并修正完成反馈与单号绑定 |

### Testing

- [OK] flutter test --no-pub: 40 passed; flutter analyze: 28 pre-existing issues, no new issues; ARM64 release build and APK contents/signature verified

### Status

[OK] **Completed**

### Next Steps

- 连接真机完成连续20单、快门中位数/P95、提示后移动清晰度、弱光和CameraX三用例兼容性验收；任务保留in_progress


## Session 16: PP-OCRv6 small端侧替换完成与验证记录
<!-- trellis-session: v=2 fp=da14cc4eef2c606b -->

**Date**: 2026-10-27
**Task**: PP-OCRv6 small端侧替换完成与验证记录
**Branch**: `codex/ocr-v6-small`

### Summary

替换为官方v6_small FP32 ORT模型、匹配CTC字典及2.5MB精简ARM64 CPU引擎，修复倾斜行对齐和超时取消；1.0.6+8安装包60.6MB已归档。

### Git Commits

| Hash | Message |
|------|---------|
| `5b18b09` | feat(ocr): 替换为PP-OCRv6 small与精简ARM64推理引擎 |
| `fd651ca` | chore(ocr): 固化CTC字典空格字符与校验规则 |

### Testing

- [OK] Flutter41项、Kotlin3项、真实模型主机样本5类与超时恢复通过；ARM64发布、APK模型哈希/依赖/签名/16KB对齐检查通过；静态分析28项既有问题，无新增。

### Status

[OK] **Completed**

### Next Steps

- 连接Android真机验证实际单据、冷暖启动/P95及峰值PSS；模型和拍照任务均保留待真机验收。用户清单为规则列，现有字段规则暂保留，SLANet_plus未加入本版。


## Session 17: 同店铺增量同步与本机删除隔离完成
<!-- trellis-session: v=2 fp=20e8d25801afdbec -->

**Date**: 2026-10-27
**Task**: 同店铺增量同步与本机删除隔离完成
**Branch**: `codex/shop-incremental-sync`

### Summary

Flutter/Django/Vue三端完成增量同步、持久重试与冲突、私有图片及只读查看；本机删除不传播。APK1.0.7+9和Web0.1.0已归档；未部署生产、待两台真机验收。

### Main Changes

- 保留历史库/图片/库存，隔离服务器与店铺；在线删除仅隐藏本机，显式拒绝单据放弃保留证据。

### Git Commits

| Hash | Message |
|------|---------|
| `d509ac7` | feat(sync): 完成同店铺增量同步、本机删除隔离与在线只读查看 |

### Testing

- [OK] Flutter67+真实Django联调1，PostgreSQL26并发及留存测试，Web3/构建/浏览器；静态分析0错误，保留28项既有提示。

### Status

[OK] **Completed**

### Next Steps

- 更新目标后端迁移及Web后，用两台真机验收同店同步、断网恢复与相机/OCR表现。


## Session 18: 默认店铺离线直达完成并启动前后端
<!-- trellis-session: v=2 fp=cab35edd36939472 -->

**Date**: 2026-10-28
**Task**: 默认店铺离线直达完成并启动前后端
**Branch**: `codex/shop-incremental-sync`

### Summary

默认记住工作区，历史店铺离线进入与纯本地禁网完成，APK1.0.8+10归档；按用户要求启动本机前后端并备份补齐同步迁移。

### Main Changes

- 持久历史和原子选择、设置取消保留、认证暂停及友好中文离线状态；新增备注说明中文。

### Git Commits

| Hash | Message |
|------|---------|
| `b6a4890` | feat(mobile): 默认直达已保存店铺并支持离线与完全本地模式 |

### Testing

- [OK] Flutter104及真实后端联调1通过，API36隔离模拟器实际断网冷启动/切换/最终APK验证通过；分析零错误，原28项既有问题保留。

### Status

[OK] **Completed**

### Next Steps

- 前端5173、后端8000及PostgreSQL保持运行；两台物理手机和原相机/OCR仍待真机验收。


## Session 19: 数字店铺与拍手作业报单联调交付
<!-- trellis-session: v=2 fp=f921ae0a2c294f9d -->

**Date**: 2026-10-28
**Task**: 数字店铺与拍手作业报单联调交付
**Branch**: `codex/work-order-reporting`

### Summary

完成三角色权限、数字店铺号、批量查图汇总、独立拍手多快递报单与到货结算；本地迁移重启并归档版本产物。

### Main Changes

- 数字店铺10000起，保留UUID缓存与历史关联；本店拍手独立身份、禁用和重置旧会话失效。
- 作业无报名直接报单；管理员查看全单快递图片商品，三态及历史金额/证据快照，结算不转账。
- 备份开发库后增量迁移，原3店5关系2入库保留；10003独立演示店，5173/8000新版运行。

### Git Commits

| Hash | Message |
|------|---------|
| `b5f2520` | feat: 完成数字店铺、批量查图和拍手多快递报单结算 |

### Testing

- [OK] 隔离PostgreSQL73/73；前端25/25及类型构建；Flutter107通过1可选跳过、分析0错误28既有提示；release APK版本及签名核验。
- [OK] 真实浏览器完整闭环、360/390手机布局、两店两拍手隔离、复制超时回退、禁用和重置密码通过。

### Status

[OK] **Completed**

### Next Steps

- 用户按docs/作业报单验收说明.md验收；相机/OCR旧任务及新版APK真机验收仍待设备。
