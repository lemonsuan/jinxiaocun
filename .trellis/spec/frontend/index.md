# Frontend Development Guidelines

> Best practices for frontend development in this project.

---

## Overview

This directory contains guidelines for frontend development. Fill in each file with your project's specific conventions.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [默认工作区与离线入口](./remembered-workspace.md) | 启动直达、历史店铺、纯本地禁网与原子切换 | Active |
| [手机结算标记提速](./mobile-settlement.md) | 局部更新、批量事务及迟到刷新协调 | Active |
| [按时间段物理清理本机](./local-date-purge.md) | 双确认、冻结选集、同步防复活及可恢复图片回收 | Active |
| [OCR开关与低占用拍摄](./ocr-switch-camera.md) | 设备总开关、许可代际、相机优先、无闪烁反馈与照片交接 | Active |
| [作业报单跨端契约](../backend/job-reporting.md) | 独立拍手会话、手机报单、管理结算、注册链接及批量查询 | Active |
| [Directory Structure](./directory-structure.md) | Module organization and file layout | Active |
| [Component Guidelines](./component-guidelines.md) | Component patterns, props, composition | To fill |
| [Hook Guidelines](./hook-guidelines.md) | Custom hooks, data fetching patterns | To fill |
| [State Management](./state-management.md) | Local state, global state, server state | To fill |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns | Active |
| [Type Safety](./type-safety.md) | Type patterns, validation | To fill |

---

## How to Fill These Guidelines

For each guideline file:

1. Document your project's **actual conventions** (not ideals)
2. Include **code examples** from your codebase
3. List **forbidden patterns** and why
4. Add **common mistakes** your team has made

The goal is to help AI assistants and new team members understand how YOUR project works.

---

**Language**: All documentation should be written in **English**.
