# 商品与店铺仓储一体化管理系统

本系统是一套支持**多租户物理隔离**、**离线增量数据同步**以及**全生命周期审计日志**的现代化商品及店铺仓储管理平台。系统采用前后端分离的 Web 管理端，并配合 Flutter 移动端实现高效率的扫码入库、出库与清点。

---

## 🏗️ 整体架构设计

项目根目录采用多包/多端（Monorepo 友好）结构划分，主要包含以下三大子系统：

```
商品管理系统 (根目录)
├── backend/            # Django Ninja + PostgreSQL 15 业务后端
├── frontend/           # Vue 3 + Vite + Tailwind CSS v4 实用主义 Web 管理端
└── mobile_app/         # Flutter / Dart 移动应用 (扫码、离线缓存、拍照 YOLO 清点)
```

### 1. 业务后端 (`backend`)
* **核心框架**：Django 5.2 + Django Ninja (高性能异步声明式 API 框架)。
* **数据库**：PostgreSQL 15 (运行于 Docker 容器中，本地暴露端口 `5433`，避开默认 5432 冲突)。
* **依赖管理**：使用极速的现代 Python 包管理器 `uv` 进行环境与虚拟环境依赖管理。
* **认证方式**：基于 JWT (JSON Web Token) 的无状态鉴权。

### 2. Web 管理后台 (`frontend`)
* **核心技术**：Vue 3 (Composition API) + Vite 6 + TypeScript + Pinia。
* **UI 框架**：Element Plus + Tailwind CSS v4。
* **视觉设计规范**：遵循「实用主义/Utility-first」后台规范。页面以清晰的网格、明确的文字层级和细分割线为主，弱化多余的炫技渐变，主色调选用矿石青（`#0f766e`），交互动效控制在 150ms 以内，营造理性一致的工程化工作台氛围。

### 3. 移动端应用 (`mobile_app`)
* **核心框架**：Flutter (Dart)。
* **核心场景**：提供轻量便捷的离线离网操作，支持扫码识别、本地轻量数据库缓存、以及调用摄像头拍照清点与增量推送拉取同步。

---

## 🔒 核心设计特征

### 1. 多租户隔离机制 (Multi-Tenant Isolation)
* **关系绑定**：系统以 `Shop` (店铺) 为核心单元，用户通过 `ShopMembership` 建立与店铺的从属角色关系（`CREATOR` 创建人、`ADMIN` 管理员、`MEMBER` 普通店员），且需被批准（`status='APPROVED'`) 才能生效。
* **标头注入与越权拦截**：所有客户端（Web 或移动端）在调用业务 API 时，必须在请求头中携带 `X-Active-Shop-ID` (当前激活的店铺 UUID)。后端 `AuthBearer` 认证器会自动核对当前登录用户在该店铺中的真实角色绑定。无绑定关系或申请未通过的请求会被强行拦截并返回 403，确保多租户之间数据不可越界窥探。

### 2. 离线差量增量同步 (Delta Sync Engine)
* 为了保障仓库深处或网络极差环境下的连续操作体验，移动端采用**本地暂存 + 增量双向同步**设计。
* **主键与时间游标**：所有业务模型都继承自 `SyncModel`，采用 UUID 作为物理主键，并记录 `updated_at` (最后修改时间) 和 `is_deleted` (软删除标记)。
* **Push (推送)**：客户端在网络恢复后，向 `/api/sync/push` 发送本地在上次同步后修改或新增的数据包。服务端在同一个数据库事务（`transaction.atomic`）中批量执行 `update_or_create` 以保证写入强一致性。
* **Pull (拉取)**：客户端携带本地记录的 `last_sync_time` 请求 `/api/sync/pull`。服务端通过过滤本店铺下 `updated_at > last_sync_time` 的所有增量记录（包括已软删除的行）下发，客户端在本地数据库进行差量合并更新。

### 3. 操作审计日志与级联校准 (Audit Logging)
* **操作追溯到人**：系统设有 `InboundActionLog`（入库操作日志）审计模型。每一次对入库单据的新增 (`CREATE`)、结算状态修改 (`UPDATE`)、商品明细数量编辑 (`UPDATE`) 以及删除单据 (`DELETE`) 行为，都会在后台自动提取 JWT Token 解析出当前操作人，将详细的操作时间、具体单号和数值前后的变更文字细节精确记录归档。
* **事务级库存回扣**：在删除入库单或修改入库数量时，后端通过 `transaction.atomic` 事务锁锁定相关表，自动计算并级联修正该商品的总在库即时库存（`WarehouseStock`）和账本变动明细（`StockLedger`）。如果数量扣除后会导致负库存，事务将自动回滚并友好报错，阻断坏账发生。

---

## 🚀 开发与启动指南

### 1. 启动本地数据库 (PostgreSQL)
本地开发环境中，数据库配置在 `backend/docker-compose.yml` 中。
在根目录或 `backend` 目录下运行：
```bash
docker-compose up -d
```
这会在后台拉起 PG 容器并监听 `5433` 端口。

### 2. 启动业务后端 (`backend`)
1. 进入 backend 目录，使用 `uv` 运行数据库迁移并填充演示测试数据（包含超级管理员、普通管理员 `shop_admin1` 密码 `admin123` 及测试店铺数据）：
   ```bash
   cd backend
   uv run python manage.py migrate
   uv run python seed_data.py
   ```
2. 启动 Django 后端服务器（监听 `8000` 端口）：
   ```bash
   uv run python manage.py runserver
   ```

### 3. 启动 Web 前端 (`frontend`)
1. 进入 frontend 目录，安装依赖：
   ```bash
   cd frontend
   npm install
   ```
2. 启动前端 Vite 本地开发服务器（监听 `5173` 端口）：
   ```bash
   npm run dev
   ```
3. 浏览器中打开 `http://localhost:5173/` 即可登录并使用系统。前端配置了反向代理，所有的 `/api` 会自动被转发到后端 `http://127.0.0.1:8000/api` 以解决跨域。

### 4. 运行移动端 (`mobile_app`)
在配置好 Flutter 开发环境后，进入 mobile_app 目录，运行以下命令启动调试：
```bash
cd mobile_app
flutter pub get
flutter run
```
