# 本机日期清理数据层实施记录

## 范围与接口

- 新增 `domain/local_purge.dart`，提供不可变 `LocalPurgePlan`、`LocalPurgeResult` 与中文 `LocalPurgePlanChanged`。
- `LocalInventoryPurge.prepareLocalPurge(from:,to:)` 读取已结算入库，按 `DateTime.parse(...).toLocal()` 闭区间匹配；冻结准确 ID、数据库身份与单据/明细/OCR/流水/同步副本指纹。
- `executeLocalPurge(plan)` 检查当前选中工作区，在单次数据库事务复验目标，拒绝内容或待同步状态变化。预览后新单不会纳入。
- 在线要求服务器已确认 revision，且无 dirty/outbox/未解决冲突；待处理识别或持久图片任务保守跳过，失败任务明确显示待重试。

## 持久化与同步

- schema 升级 v8，迁移和初始化都建立 `sync_purged(kind,id)` 与 `local_purge_gc(path)`；前者只有稳定键，不包含业务内容，也不上传、不被恢复隐藏清除。
- 事务抑制 dirty 触发器，物理删除已选主单、明细、OCR、该单入库历史流水、相关本机同步 meta/outbox/conflicts/abandoned/media/hidden 与任务键，不修改商品及当前库存，不发送服务器删除。
- pull 校验后跳过已清理 ID，仍推进 cursor，并应用同包其他记录/库存；meta、远程写入口、冲突采用服务器入口、下载候选和迟到 attach 同样防复活。
- 冲突远程身份必须与冲突根身份一致，避免旁路写入其他单据。

## 图片回收

- 数据提交与回收日志先完成；随后才删除无其他引用的照片。SQLite 写事务覆盖引用复验与文件移除，避免新增引用竞态。
- 检查其他入库/出库附件、OCR、任务设置及全部同步 JSON 副本；解析嵌套 JSON，规范化路径并比较实际路径别名。历史已解决冲突旧图片也加入回收候选。
- 只处理应用文件根目录内照片格式路径或 cloud_media 缓存，拒绝符号链接、外部路径、数据库等其他文件；目录等异常对象保留待回收日志。
- 成功后清理对应 hash 缓存；共享文件保留；失败持久化并可重试，真实工作区启动自动重试。迟到下载被拒绝附着后，也执行回收。
- 本次结果只统计本次计划路径，旧回收日志不会虚增本次删除数。

## 文件责任与检查

修改：`local_inventory_database.dart`、`local_inventory_scope.dart`、`local_database_schema.dart`、`sync_database_schema.dart`、`local_inventory_sync.dart`、`shop_sync_service.dart`；新增 `local_inventory_purge.dart`、`local_purge.dart`、`local_purge_test.dart`。独立 reviewer 新增 `local_purge_review_test.dart`。

已运行真实隔离 SQLite 测试：本功能与同步数据库/服务共46项全部通过；后续小修改另跑本功能10项。定向 Flutter analyze（data、领域模型、同步服务与自身测试）通过。测试覆盖日期边界/UTC等价、目标冻结、事务回滚不丢图、完整业务副本移除且库存保留、共享图片、失败持久化重启恢复、在线排除不安全单据、高版本重放/迟到 attach 不复活、游标与同包其他库存正常。

没有对用户实际数据库执行清理，没有改 UI、服务器、版本号或提交。根会话负责全量回归、APK和提交。物理清理指业务行和无引用图片移除，不宣称存储介质安全擦除，用户旧导出备份不自动删除。
