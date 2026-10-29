# 后端恢复实施与检查

## 范围

恢复检查63a57d3已有后端实现，未重写既有模型和迁移。现有实现已包含本人收款资料及独立版本、本人用途图片所有权、订单备注/补图、全量个人统计、结算收款版本复验与历史快照；请求旧字段省略兼容及未知结果原操作键重试均保留。没有修改线协议、认证边界、库存规则或真实开发数据库。

本轮新增修改：

- `backend/jobs/api.py`：新增字段校验错误使用明确中文业务名称。
- `backend/jobs/tests.py`：补图单次预取使订单列表固定查询预算12变13；增加页容量从3到6时查询数不增长的断言，继续防止逐订单额外查询。
- `backend/jobs/test_payout.py`：流图片测试改为消费stream释放，避免直接close触发request_finished关闭PostgreSQL外层测试事务连接；新增跨店收款图片不可读/绑定、禁用身份资料及统计禁止访问、禁用和资料更新竞态复验。

## 验证

在`backend/`执行，均未连接用户5433数据库：

- `.venv/bin/python manage.py test --settings=shop_sync_backend.test_settings --noinput`：87项完成，73通过、14项真实行锁测试按设计跳过。
- `.venv/bin/python manage.py test --settings=shop_sync_backend.postgres_test_settings --noinput`：87项全部通过，无跳过。使用独立容器`work-report-test-pg`、127.0.0.1:25439、临时`test_shop_sync_isolated`数据库，测试结束销毁。
- `.venv/bin/python manage.py makemigrations --check --dry-run --settings=shop_sync_backend.test_settings`：No changes detected。
- `.venv/bin/python manage.py check --settings=shop_sync_backend.test_settings`：无问题。
- `.venv/bin/python -m compileall -q jobs`：通过。
- `git diff --check`：通过。

测试包含两拍手/两店隔离、用途校验、无效/超量图片、旧PATCH字段省略、全量统计、旧请求哈希兼容、收款CAS/同键重试、最新资料结算版本、历史缺收款不冒充最新、已结算不可编辑，以及真实PG结算/修改/禁用竞态。

## 边界与后续

本owner未迁移或重启真实开发服务、未改种子数据、未提交或打包。正式演示前由root备份并应用jobs0002迁移，继续完成两端UI和浏览器全流程验收。收款资料编辑不涉及转账；图片仍沿既有私有媒体保留机制。没有剩余后端实现阻塞。
