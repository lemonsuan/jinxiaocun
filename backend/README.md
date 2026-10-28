# 业务后端 (Django Ninja + PostgreSQL)

本目录为系统的业务后端服务，基于 **Django 5.2** 与 **Django Ninja** 构建，负责多租户数据隔离、离线增量同步 (Sync v2)、作业报单与快照结算流转、批量查单查图聚合、私有媒体存储与操作日志审计。

---

## 核心接口说明

1. **增量同步 (Sync v2)**：
   - `POST /api/sync/v2/push`：客户端离线数据增量推送。通过店铺行级悲观锁（`SELECT FOR UPDATE`）串行化执行，严格校验单据基线 Revision，支持操作键（`operation_id`）幂等防重。
   - `GET /api/sync/v2/pull`：基于单调自增版本号（`cursor`）拉取不可变快照记录，消除客户端系统时钟偏差。
   - `POST /api/sync/v2/media` / `GET /api/sync/v2/media/{sha256}`：私有凭证图片上传与下载保护，基于 SHA256 哈希去重。

2. **视图与批量查询 (/api/view/...)**：
   - `/api/view/products`、`/api/view/inbound`、`/api/view/outbound`、`/api/view/stocks`、`/api/view/ledger`、`/api/view/logs`；
   - `POST /api/view/inbound/batch`：高吞吐批量查单查图接口，单次支持最多 200 个快递单号批量查询，单据明细与整批商品汇总独立分页。

3. **作业与拍手报单 (/api/jobs/...)**：
   - 管理端：`/api/jobs`（作业发布与管理）、`/api/jobs/orders`（报单审核与版本快照结算确认）、`/api/jobs/workers`（拍手人员管理）；
   - 公开端：`GET /api/worker/shop?shop_number=10003`、`POST /api/worker/register`、`POST /api/worker/login`；
   - 拍手端：`GET/POST /api/worker/orders`（拍手报单填写，支持最多 20 单号/单）、`GET /api/worker/me`（拍手个人资料）。

---

## 运行与验证

### 1. 运行测试套件
```bash
# SQLite 隔离测试 (覆盖 73 项逻辑测试)
python manage.py test inventory shops jobs --settings=shop_sync_backend.test_settings

# 迁移完整性检查
python manage.py makemigrations --check --dry-run --settings=shop_sync_backend.test_settings
```

### 2. 启动服务
```bash
# 激活虚拟环境
source .venv/bin/activate

# 启动开发服务器
python manage.py runserver 0.0.0.0:8000
```
