# 🏪 云推推商品与店铺仓储一体化管理系统 (Yuntuitui IMS)

一套面向现代电商供应链、多店铺分销与档口仓储的**全场景软硬件一体化管理平台**。系统深度融合**多租户物理隔离**、**作业与报单结算流转**、**离线优先增量同步 (Sync v2)**、**原生高性能相机引擎**、**离线 PaddleOCR 表格提取**与**双模防爆数据备份**等核心技术，实现仓储入库、核验理货、作业派发、拍手报单、结算审核与出入库台账的全链路闭环。

---

## 🏗️ 整体系统架构

系统采用清晰的 Monorepo 多包/多端工程化组织架构：

```
商品管理系统 (根目录)
├── backend/            # 业务后端：Django 5.2 + Django Ninja + PostgreSQL 15
├── frontend/           # Web 前端：Vue 3 + Vite 6 + TypeScript + Tailwind CSS v4
│   ├── src/admin/      # 管理端：作业发布、报单审核、批量查单与快照结算
│   ├── src/views/      # 管理端：商品档案、仓储库存、出入库管理、操作日志
│   └── src/worker/     # 移动端：拍手专用免安装 H5（任务浏览、扫码/批量报单、结算查询）
├── mobile_app/         # 移动端 App：Flutter 3 (Dart) 离线优先原生混合应用
│   ├── android/        # 原生工程：CameraX 视图、零快门延迟(ZSL)、PaddleOCR 推理引擎
│   └── lib/src/        # Flutter 业务：本地 SQLite 数据库、状态租约调度、双模备份
└── releases/           # 生产发布包归档：统一存放带版本号的各端部署安装包
```

### 1. 业务后端 (`backend`)
* **核心框架**：Django 5.2 + Django Ninja（声明式强类型异步 API 框架）。
* **数据库引擎**：PostgreSQL 15（运行于独立 Docker 容器中，暴露 `5433` 端口避免端口冲突）。
* **依赖管理**：基于极速现代 Python 包管理器 `uv` 进行虚拟环境与包依赖锁定。
* **认证授权**：
  * 管理端：无状态 JWT Token + `X-Active-Shop-ID` 标头多租户鉴权。
  * 拍手端：独立轻量会话鉴权（`WorkerBearer`），严格禁止越权访问库存及管理接口。
* **私有媒体库**：凭证图片基于 SHA256 内容寻址哈希防重存储，严格保护私密凭证。

### 2. 现代 Web 前端 (`frontend`)
* **核心栈**：Vue 3 (Composition API) + Vite 6 + TypeScript + Pinia 状态管理。
* **UI 体系**：Element Plus + Tailwind CSS v4，严格遵循「实用主义/Utility-first」视觉标准，主色调选用矿石青（`#0f766e`），交互动效控制在 150ms 以内，严谨高效。
* **双模态终端支持**：
  * **PC 管理控制台**：多维度库存监控、出入库台账、多达 200 单批量查单查图、作业配置与快照结算。
  * **拍手移动 Web 端 (`/worker/...`)**：纯响应式移动视图，手机浏览器即开即用，支持多单号批量粘贴去重报单。

### 3. 仓储移动端 App (`mobile_app`)
* **核心框架**：Flutter (Dart 3)。
* **适用场景**：仓库现场无网/弱网环境下的扫码入库、自研相机极速抓拍、快递面单/出入库单离线 OCR 表格提取、车厢与批次核验、增量差量数据同步。
* **硬件级整合**：自研 Android CameraX 原生高帧率取景流，具备零快门延迟（ZSL）平滑降级、触觉反馈、闪光灯记忆以及与后台图像计算的租约互斥调度。

---

## 🔒 核心技术特性与实现原理

### 1. 多租户物理隔离与数字店铺体系 (Multi-Tenant & Shop Number)
* **双轨标识系统**：
  * 内部关联：采用全局唯一 UUID 作为底层物理主键，确保系统合并与多端离线数据不发生冲突；
  * 人机友好：每家店铺配备唯一的自增 8 位纯数字编号（如 `10003`），用于拍手快捷识别、扫码进店与注册绑定。
* **三级角色访问控制 (RBAC)**：
  * `CREATOR`（创建人）/ `ADMIN`（管理员）：拥有店铺完整配置、库存核算与报单审核权限；
  * `WORKER`（拍手）：仅拥有本店公开作业浏览与本人报单读写权限，无法窥探仓储库存。
* **标头注入与越权拦截**：所有管理请求由 `AuthBearer` 动态校验 `X-Active-Shop-ID` 与用户成员审批状态，杜绝跨店铺横向越权。

### 2. 作业与报单结算流转系统 (Job & Order Dispatching)
* **作业智能派发**：管理员在后台设定作业（含任务要求、单据示例照片、单件成本及返款金额），可随时发布或关闭。
* **一键邀请与免密注册**：系统自动生成专属带店铺编号的 Hash 注册邀请链接，支持局域网或公网一键复制；拍手打开自动锁定所属店铺，注册即绑定，无须漫长审核流程。
* **高效批量报单**：拍手可一次性录入最多 20 个快递单号，支持从聊天软件或记事本整段复制，系统自动执行空白/中英文逗号/分号拆分与去重。
* **自动到货匹配机制**：
  * 拍手提交的快递单号自动联动同店实时入库流水；
  * 部分入库时标记为“运输中”并显示已到货数量；全部快递到货后自动流转至“已到货”。
* **版本快照结算确认 (Immutable Settlement Snapshots)**：
  * 管理员确认结算时，系统原子捕获当时的作业版本、订单数据、单件金额与入库单据/照片快照归档入库；
  * 结算完成后订单严格只读锁定；如需调整必须由管理员填写原因后撤销，历史审计快照终身保留。

### 3. 离线增量同步引擎 (Sync v2 Engine)
* **悲观行锁串行化**：在服务端执行增量 Push 时，使用 PostgreSQL `SELECT FOR UPDATE` 行级悲观锁独占锁定所属店铺，杜绝高并发网络抖动导致的库存断层。
* **不可变修订版本号 (Revision Snapshots)**：抛弃脆弱易漂移的物理时钟设计，采用单调自增的单据 Revision 代际序列。Pull 拉取采用严格游标分页，保证多端并发无遗漏。
* **强幂等性保障**：客户端每次变更生成唯一操作键（`operation_id`），网络超时重发不产生重复单据或多次扣除库存。

### 4. 批量快递查单与查图 (Parcel Batch Viewer)
* 在管理后台“入库记录”中集成高吞吐批量速查功能：
  * 支持一次性粘贴最多 200 个不同快递单号；
  * 毫秒级聚合呈现对应的实物凭证缩略图、单据状态、并自动聚合计算整批货物涉及的商品总类数与总件数；
  * 未入库单号独立标红提示，商品汇总与单据明细独立分页联动。

### 5. 原生硬件级相机与录单调度优化 (CameraX Pipeline)
* **极速模式与零快门延迟 (ZSL)**：优先绑定 CameraX 零快门延迟流水线，按下快门瞬间立即抓帧落盘；低内存（Low-RAM）设备或老旧机型自动平滑回退，保留全像素静态照片画质。
* **轻触觉与视觉反馈**：摒弃传统全屏闪白遮挡，改为照片真实写入磁盘后触发轻微线性震动、快门图标打勾并提示“已拍好，可以移开”，彻底杜绝提早移机拍糊。
* **闪光灯持久化记忆**：状态自动保存在本地，重启 App 或进出相机维持上次开关状态，避免现场重复开启。
* **拍摄作业租约调度器 (`CaptureWorkCoordinator`)**：
  * 取景拍摄期间持有租约，后台自动挂起计算繁重的裁剪与 OCR 解析任务；
  * 退出取景后自动释放租约并恢复队列，确保连拍时相机预览始终保持满帧不卡顿。

### 6. 离线 OCR 与按需推理流水线 (PaddleOCR & AI Switch)
* **设备级独立 OCR 总开关**：在“我的”页面顶部可随时开启或关闭图片 OCR；设置持久化在设备本地，不受云端同步或店铺切换影响。
* **开启状态**：自研流水线先调用本地 PaddleOCR 提取表格与版面结构，再结合云端或本地大模型精细提取商品名称、编码与数量。
* **关闭状态（极速录单）**：拍摄后直接保存原图并生成待补录草稿，零推理计算、零网络请求，录单速度提升 300%；后续可随时主动手动触发单据重识别。
* **代际令牌安全机制 (`OcrPermit`)**：开关切换自增代际编号，正在运行中的旧请求返回时若发现代际过期自动废弃，防止迟到的 OCR 识别结果覆盖人工修改。

### 7. 稳妥双模数据防爆备份体系 (Dual-Mode Resilient Backup)
针对仓库积攒数千张高分辨率照片导致旧版 Base64 单文件导出内存溢出（OOM/ANR）崩溃的痛点，创新推出双模式备份：
1. ⚡ **纯业务数据备份 (强烈推荐 · 极速稳妥)**：
   * 仅导出商品、库存、单据、核验记录与价格配置；
   * 体积仅几百 KB，**0.1 秒秒级导出**，内存消耗忽略不计，适合日常高频备份。
2. 📦 **全量流式 ZIP 归档包 (含全部实物单据照片)**：
   * 采用磁盘分块流式直接压缩技术，实物照片逐张流式写入 `.zip`；
   * 内存占用恒定低于 10MB，带有实时打包进度弹窗（`正在压缩照片 12/150...`）；
   * 底层通过 Android 原生管道直写系统 `Download/` 目录，彻底杜绝大文件崩溃。
3. **双向向下兼容还原**：
   * 自动探测文件头辨别 `.zip` 或 `.json`；
   * 100% 兼容恢复早期导出的含 Base64 照片的传统老备份；
   * 还原纯数据备份时智能匹配本地现有照片，路径自适应重映射。

---

## 📂 项目核心目录结构树

```
.
├── backend/                                # Django Ninja 业务后端
│   ├── docker-compose.yml                  # PostgreSQL 15 容器编排 (端口 5433)
│   ├── inventory/                          # 仓储库存核心域
│   │   ├── models.py                       # 商品、入库单、出库单、台账模型
│   │   ├── sync_service.py                 # Sync v2 悲观行锁持久化写入引擎
│   │   ├── batch_view.py                   # 200单批量查单查图聚合接口
│   │   └── media.py                        # 私有凭证图片 SHA256 存证服务
│   ├── jobs/                               # 作业与拍手报单领域
│   │   ├── models.py                       # 拍手账号、作业配置、报单、快照模型
│   │   ├── api.py                          # 管理/公开/拍手分层路由 (Ninja Router)
│   │   ├── auth.py                         # 独立 WorkerBearer 鉴权
│   │   └── services.py                     # 报单幂等写入、状态流转与结算确认
│   ├── shops/                              # 店铺与多租户域
│   │   └── models.py                       # CustomUser、Shop、ShopNumberSequence(数字ID)
│   ├── shop_sync_backend/                  # 项目全局配置
│   │   ├── api.py                          # 统一 API 装配与 HttpBearer 拦截器
│   │   ├── sync_v2.py                      # 增量推送(Push)、拉取(Pull)及媒体路由
│   │   └── settings.py                     # Django 生产/开发配置
│   └── seed_data.py                        # 本地开发测试店铺与演示数据填充器
│
├── frontend/                               # Vue 3 实用主义管理后台与拍手 Web
│   ├── src/
│   │   ├── admin/                          # 管理后台作业报单模块
│   │   │   ├── JobManagement.vue           # 作业创建、启停与编辑
│   │   │   ├── JobOrders.vue               # 报单列表与审核结算工作台
│   │   │   ├── logic.ts                    # 邀请注册链接生成、剪贴板竞态控制
│   │   │   └── batch.ts                    # 批量单号文本解析去重器
│   │   ├── worker/                         # 拍手端专用移动 Web 模块
│   │   │   ├── pages/WorkerAuthPage.vue    # 拍手注册与登录面板
│   │   │   ├── pages/WorkerOrderEditor.vue # 拍手多单号报单填写
│   │   │   ├── pages/WorkerOrdersPage.vue  # 报单状态列表（运输中/已到货/已结算）
│   │   │   └── logic.ts                    # 会话代际隔离、状态格式化、防重 UUID
│   │   ├── views/                          # 核心仓储业务页面
│   │   │   ├── InboundManagement.vue       # 入库管理（集成批量查单组件）
│   │   │   ├── WarehouseStock.vue          # 即时在库库存
│   │   │   ├── StockLedger.vue             # 变动明细账本
│   │   │   └── ShopSelect.vue              # 店铺选择与数字 ID 加入
│   │   └── router/index.ts                 # 双终端路由注册与导航守卫
│   └── tests/                              # Node 原生测试套件 (25 项全通)
│
├── mobile_app/                             # Flutter 离线优先混合 App
│   ├── android/app/src/main/kotlin/        # Android 原生平台实现
│   │   ├── MainActivity.kt                 # 平台通道注册、MediaStore 直写
│   │   └── camera/                         # CameraX 视图、ZSL 模式降级策略
│   ├── lib/src/
│   │   ├── application/
│   │   │   ├── capture_work_coordinator.dart # 拍摄取景与后台任务租约协调器
│   │   │   ├── ocr_access_policy.dart      # OCR 硬件级开关与代际控制
│   │   │   └── capture_image_processor.dart# 后台 Isolate 图像裁剪校准器
│   │   ├── data/
│   │   │   └── local_inventory_database.dart # SQLite 引擎、流式 ZIP 打包与恢复
│   │   ├── platform/
│   │   │   └── paddle_ocr_channel.dart     # 原生离线 OCR 通信通道
│   │   └── ui/
│   │       ├── custom_camera_page.dart     # 自研拍照页 (极速/超清、闪光灯记忆)
│   │       ├── data_management_page.dart   # 数据备份与双向兼容还原面板
│   │       └── express_inbound_page.dart   # 快递扫码核验与入库录单页
│   └── test/                               # Flutter 单元与挂件测试 (124 项全通)
│
├── releases/                               # 编译打包产物归档目录 (强制版本号)
│   ├── app-v1.0.10+12.apk                  # 最新 Android Release 安装包
│   └── web-v0.2.0.zip                      # 最新 Web 静态包产物
└── docs/                                   # 验收指南与业务说明文档
```

---

## 🚀 本地开发与快速启动

### 1. 环境准备
确保本机已安装以下基础开发套件：
* **Node.js** >= 18.0.0
* **Python** >= 3.12（推荐配合 `uv`）
* **Docker & Docker Compose**（用于拉起 PostgreSQL 15）
* **Flutter SDK** >= 3.24.0 及 **Android SDK**（如需调试/编译移动端）

---

### 2. 启动本地数据库 (PostgreSQL)
在项目根目录执行：
```bash
docker-compose -f backend/docker-compose.yml up -d
```
* 服务将启动并在本地 `5433` 端口暴露 PostgreSQL（账号：`postgres`，密码：`postgres`，库名：`shop_sync_db`）。

---

### 3. 启动业务后端 (`backend`)
1. 进入 backend 目录，创建虚拟环境并安装全部依赖：
   ```bash
   cd backend
   uv venv --python 3.12
   source .venv/bin/activate
   uv pip install -r requirements.txt
   ```
2. 执行数据库迁移并灌入测试演示数据：
   ```bash
   python manage.py migrate
   python manage.py seed_data
   ```
   * *内置演示管理员：`admin` / 密码：`admin123`*；
   * *内置演示店铺：`10003，作业报单功能验收店（演示）`*；
   * *内置演示拍手：`paishou_demo` / 密码：`DemoWorker2026!`*。
3. 启动 Django Ninja 后端开发服务器：
   ```bash
   python manage.py runserver 0.0.0.0:8000
   ```

---

### 4. 启动 Web 前端 (`frontend`)
1. 打开新终端，进入 frontend 目录并安装依赖：
   ```bash
   cd frontend
   npm install
   ```
2. 启动 Vite 开发服务器（支持手机局域网联调）：
   ```bash
   npm run dev -- --host 0.0.0.0
   ```
3. 浏览器访问：
   * **PC 管理端**：`http://localhost:5173/`；
   * **手机拍手端**：`http://<电脑局域网IP>:5173/#/worker/login?shop=10003`。

---

### 5. 调试与编译移动端 (`mobile_app`)
1. 进入移动端工程目录并获取依赖：
   ```bash
   cd mobile_app
   flutter pub get
   ```
2. 启动 Android 模拟器或连接真机后调试运行：
   ```bash
   flutter run
   ```
3. 编译发布版 Release APK：
   ```bash
   flutter build apk --release
   ```

---

## 📦 发布包管理与归档规范 (Release Policy)

为保证工程交付的严肃性与产物可追溯性，项目制定了以下严格规范：

1. **统一存放目录**：
   * 所有构建产物（包括 Android APK 安装包、Web 静态包）必须统一归档至根目录的 **`/releases`** 目录下。
2. **强制版本号命名**：
   * 移动端以 `app-v<版本号>.apk` 命名，例如 `releases/app-v1.0.10+12.apk`；
   * Web 端以 `web-v<版本号>.zip` 命名，例如 `releases/web-v0.2.0.zip`；
   * 禁止产生无版本号的临时或散乱产物；编译发版前必须在 `mobile_app/pubspec.yaml` 或 `frontend/package.json` 中自增版本号。

---

## 🧪 自动化测试与质量检验

项目在各端均建立了完备的自动化测试体系：

### 1. 后端接口与隔离性测试
```bash
cd backend
python manage.py test inventory shops jobs --settings=shop_sync_backend.test_settings
```
* 覆盖多租户越权拦截、数字店铺 ID 分配、作业报单幂等提交、结算快照只读锁定与批量聚合查询。

### 2. 前端逻辑与状态测试
```bash
cd frontend
npm test
```
* 25 项全通，覆盖批量单号分隔去重、注册链接安全协议、剪贴板竞态超时、会话版本代际防护及金额精度校验。

### 3. 移动端单元与组件测试
```bash
cd mobile_app
flutter test
```
* 124 项全通，覆盖 OCR 硬件级开关持久化、相机租约互斥调度、离线 SQLite 事务回滚、ZIP 流式数据恢复及多工作区切换。

---

## 📝 贡献与编码准则

1. **语言规范**：代码注释、文档、说明、提交信息与用户界面提示文案**统一使用中文**；
2. **提交准则**：在执行大型功能改动或调试完成完整功能点后，助理必须自动在 terminal 中执行代码的 git 提交（`git add & git commit`）；
3. **架构纪律**：业务单据修改必须经由事务原子锁与版本号机制，严禁直接在数据库中执行无日志、无快照的跳跃性篡改。
