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
