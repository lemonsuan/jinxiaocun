<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->


# 项目全局 AI 自动提交规则
- **大量改动提交原则**：在每次执行大量的代码改动、页面级别的新建/重构，或者调试完成一个完整功能点时，AI 助理必须自动在 terminal 中执行代码的 git 提交（`git add` & `git commit`）。
- **时间锁提交原则**：若距离上一次 git 提交时间已超过 2 个小时，且当前工作区存在任何实质性代码修改时，AI 助理必须在当前轮次结束前自动将修改提交到本地 Git 仓库，避免开发进度丢失。

# 编译发布与产物归档规则
- **产物统一存放目录**：项目编译打包生成的安装包/构建产物（如 Android APK），必须统一存放在根目录的 `/Users/xcy/Project/商品管理系统/releases` 目录下。
- **强制版本号命名**：编译发布前必须检查并递增 `pubspec.yaml`（或相应项目配置）中的版本号（如 `1.0.4+6`），编译生成的安装包必须以 `app-v<版本号>.apk`（例如 `app-v1.0.4+6.apk`）命名并归档至 `releases/` 目录，禁止产生无版本号的散乱产物。


# 代码注释与说明语言
- 新增或修改的代码注释、备注和说明统一使用中文；既有未涉及的内容不因语言要求进行无关批量改写。
