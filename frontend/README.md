# Web 前端 (Vue 3 + Vite 6 + Tailwind CSS v4)

本目录为系统的 Web 前端工程，包含 PC 管理端工作台与拍手端移动 Web 界面。

---

## 模块组织

* **`src/admin/`**：管理端作业报单与批量查单模块。
  - `JobManagement.vue`：作业创建、上下架与参数编辑；
  - `JobOrders.vue`：报单审核、入库联动与不可变快照结算确认；
  - `components/InboundBatchViewer.vue`：最多 200 个单号的批量快递查单与凭证查图组件。
* **`src/worker/`**：拍手专用免安装移动端 H5 模块。
  - `pages/WorkerAuthPage.vue`：根据数字店铺编号自动带入并注册/登录；
  - `pages/WorkerOrderEditor.vue`：多单号批量报单编辑器（支持多行/逗号拆分去重）；
  - `pages/WorkerOrdersPage.vue`：个人报单流转与结算状态列表。
* **`src/views/`**：核心仓储进销存页面。
  - `InboundManagement.vue`：入库管理；
  - `WarehouseStock.vue`：在库库存监控；
  - `StockLedger.vue`：出入库明细账本；
  - `ShopSelect.vue`：店铺选择与数字 ID 加入申请。

---

## 开发与测试

```bash
# 安装依赖
npm install

# 运行自动化测试套件 (25 项全通)
npm test

# 启动本地开发服务器 (支持局域网真机访问)
npm run dev -- --host 0.0.0.0

# 生产环境编译构建
npm run build
```
