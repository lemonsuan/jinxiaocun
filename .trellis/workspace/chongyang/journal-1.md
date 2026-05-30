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
