# 设计

以research/date-purge.md为证据。新增独立物理清理路径，先沿用现有已结算入库范围；按本地时间created_at闭区间选择，未结算/出库/商品与当前库存不删。共享模式仅允许已ack且无dirty/outbox/未解冲突/活跃OCR的记录，其他明示跳过，保留唯一副本。

领域LocalPurgePlan冻结作用域、起止、确切ID及内容hash、可删和跳过/共享图片数量。prepareLocalPurge({required DateTime from,required DateTime to})生成计划，executeLocalPurge(LocalPurgePlan)事务内逐项复验而非重新按日期扩大选集；变更则拒绝重新预览。返回LocalPurgeResult清楚区分已删记录、已删照片、共享保留和待回收失败。

本机sync_purged仅保留kind/id，不存单号/图片/业务JSON，不上传，恢复隐藏不清它。事务抑制dirty触发器，删除选中主单、明细、OCR、该单历史流水及所有同步meta/outbox/conflicts/abandoned/media副本；库存余额不重算。pull/remote/meta/媒体候选和attach统一purge守卫，cursor继续推进，其他文档/库存正常，不能自动复活。

先提交数据库删除及文件回收日志，再清无剩余引用的应用内照片；不先删文件。回收失败可重启重试，引用未知保留。检查其他单据、同步快照和任务引用，sync://或外部路径不删。已有导出备份不自动删，不承诺介质级安全擦除。

UI新增按时间段物理清理卡，不悄悄改变现有全量清理。开始/结束日期时间→预览真实范围数量/跳过原因→确认一→第二次明确仅本机物理移除和不可由恢复隐藏找回→执行。任何取消无删除、忙碌防重复、结果不把失败说全成功。同步pauseAndDrain在预览/确认/执行期间持租约，finally恢复；复用已有同步服务不为本地模式创建网络服务。
