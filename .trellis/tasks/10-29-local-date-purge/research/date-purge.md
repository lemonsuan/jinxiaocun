# 研究：按时间段物理清理本机记录

- 查询：已结算入库按时间段物理清理、保留库存和云端、两次确认、避免自动同步复活。
- 范围：内部代码与现有规范，只读研究。
- 日期：2026-10-29。

## 结论

不能给旧clearSettled接口简单添加日期条件。在线旧实现只是sync_hidden遮罩；本地旧实现先在SQLite事务内删除照片再删除记录，存在事务回滚后引用丢文件风险。需要独立的物理清理路径、本机ID阻止重拉标记，以及提交后可恢复的文件回收。

最小安全首版建议：仅清时间范围内已结算入库；在线只允许已有服务器revision且无dirty/outbox/未解决冲突/活跃express job的记录。其余明确列为未同步或处理中而跳过，提示先同步/处理，不能悄悄丢弃尚未到服务器的唯一副本。离线本地库可清符合已结算条件且无活跃处理的记录。所有版本都保留现有warehouse_stock/products和其他单据，库存余额不重算。

## 文件与代码证据

| 文件位置 | 事实 |
|---|---|
| local_inventory_database.dart:1957-2005 | clearSettledTextData在线调用_hideSettled即返回；本地删除入库明细、来源为该单的入库流水、ocr_results和主单，但不改warehouse_stock；物理图片却在DB提交前删除。 |
| 同上:2009-2037 | clearSettledImagesData在线同样隐藏整单，本地删文件后清image_path，没有日期条件或完整跨表引用校验。 |
| 同上:1017-1032 | isImagePathReferenced只查入库主图和出库附件，不查同步路径、队列/冲突快照，不能直接作为新物理回收的完整守卫。 |
| sync_database_schema.dart:4-17 | sync_meta、outbox、conflicts、abandoned存JSON副本；sync_media存local_path及digest，sync_hash保存文件路径缓存，sync_hidden只是ID遮罩。 |
| 同上:18-36 | 本地表INSERT/UPDATE/DELETE触发dirty；清理必须在事务内设置sync_control.suppressed，不能制造服务器删改或待同步空单。 |
| local_inventory_sync.dart:213-278 | applySyncPull会写业务行和sync_meta，再统一更新cursor；无独立purge标记时删掉主表后未来pull或新revision会重新写入。 |
| 同上:432-463 | _writeRemote重建sync_media，缺本机文件写sync://占位；不能只删图片而保留媒体元数据，否则会重下载。 |
| 同上:604-617 | _hideSettled仅INSERT sync_hidden；restoreLocallyHiddenRecords清空全部hidden，不应同时撤销明确物理清理的标记。 |
| 同上:752-801 | acceptServerSyncConflict可绕开常规pull写远程版本，物理清理需统一入口守卫或保证目标冲突已删除/禁止再次采用。 |
| 同上:805-844 | pendingSyncMediaDownloads从sync_media取缺图；attachSyncMedia按参考写文件路径。两者需检查purge，下载完成迟到也不能复活引用。 |
| 同上:153-211 | applySyncPushResults可写sync_meta；若允许清未知结果outbox，迟到ack仍可能重建副本。安全首版排除未ack/dirty，且所有远程写入口统一purge守卫。 |
| 同上:7-39 | 备份只业务表，隐藏和同步标记不导出；恢复会清同步状态。在线恢复按现有约定拒绝，跨设备备份不应自动转移本机purge策略。 |
| shop_sync_service.dart:74-95,290-310 | 有pauseAndDrain/localChange；应暂停并排空同步后准备/复验清理计划，完成后成对resume。 |
| app_home.dart:1037-1048 | DataManagementPage当前仅传database和恢复刷新回调，没有传同步暂停封装；新清理必须接入，而非直接和同步竞跑。 |
| express_processing_queue.dart:101-130 | 处理有job/path/permit保护；但清理仍应排除活跃job，或在删除事务内使其失效，并安全处理已生成派生文件。 |
| local_database_schema.dart:4,145 | schema当前v7，需为新持久表增加版本迁移或可靠IF NOT EXISTS初始化；不能只让新安装拥有表。 |

以上缩写路径均位于mobile_app/lib/src/data、application或ui对应目录。

## 建议最小数据契约与同步防复活

1. 新增仅本机sync_purged(kind,id)一类表，至少保留文档类型及稳定同步键，不保留单号、商品、图片摘要、原始JSON。在线记录允许再附最后revision作诊断但非必需。它不发送服务器，也不被“恢复本机隐藏”清除。
2. applySyncPull仍校验kind/id/revision及cursor合法性，目标命中purge就跳过业务、媒体和meta写入，继续正常推进cursor；同包其他记录必须继续应用。不同revision也不能复活旧ID。
3. _writeRemote/_saveMeta和attachSyncMedia等最后写入点最好有同一ID守卫，防旁路或迟到回包。下载候选也排除purge。purge目标已有媒体行在删除事务一并移除，避免不断下载。
4. 清理事务先suppressed=1，删除选中主单/明细/OCR结果/该单入库历史流水、express_image_job以及kind/id对应sync_meta、dirty、outbox、所有已解决/未解决conflicts和abandoned、sync_media、原hidden；插入purge ID，恢复suppressed后提交。安全首版目标本身无dirty/outbox/未解决conflict，不是“清掉未同步记录也算成功”。所有JSON副本必须清掉，不能仅屏蔽查询。
5. 保留商品/库存及其他订单/出库流水；不调用_reconcileStock重算旧历史。全量server stock今后仍正常同步。原已结算状态是手机InboundReceipt.is_settled，与Web作业Settlement无关。
6. 单据时间按created_at解释为用户本地时间；已有DateTime.parse用法既有无时区本地ISO也有带偏移服务端ISO。推荐读取候选并Dart解析后toLocal比较，不直接把混合ISO字符串按字典序比较或假设无偏移时间是UTC。明确闭区间/结束分钟语义，并覆盖跨午夜与+08/UTC等价样本。

## 预览与两次确认

- 首次准备不可变计划：工作区身份、起止时间、确切选中ID、主表/明细/图片及同步revision/generation的规范化快照hash、可删数、跳过原因、图片共享保留数。
- 第一次确认展示范围和真实匹配数量；第二次再次列数量及“仅本机物理删除、现有库存不变、服务器其他设备保留、不可从恢复隐藏找回”。任何取消/返回不执行。
- 第二次执行在同一DB事务复验计划及作用域；被改为未结算、出现dirty/任务或内容变化则整笔拒绝、重新预览，不采用原range再次SELECT全部导致把后来新增记录静默删掉。
- 持有同步pause/drain租约覆盖必要窗口，最终finally恢复，避免一次取消后永久停同步；长时间确认不应无限锁DB。执行按钮忙碌防连点。

## 文件回收与失败顺序

先DB提交“已删除、需回收文件路径”日志，再回收文件，不能先删照片再希望SQLite回滚恢复。可用独立本机回收表保持失败重试；删除成功才移出日志，失败明确报告未完成，重启可继续。不要将失败统一提示全清理成功。

回收前检查所有剩余入库/出库附件、sync_media.local_path、其他同步JSON/express任务中的实际路径引用；有其他引用就保留，不影响其他单据。目标的sync_hash缓存只在文件确实无剩余引用并清理后删除。删除文件仅限应用可管理目录，sync://占位和任意外部路径不能当普通文件删。

DB删除不是介质级安全擦除：SQLite/WAL/用户另外导出的旧备份可能仍留历史，不得声称取证不可恢复。此任务应准确说明“移除本机业务行及无其他引用的图片文件”；旧导出备份不是自动删除对象。是否做额外compact要评估空间和失败，不能拿VACUUM代替引用正确性。

## 必要测试

- 真实SQLite：起止相等/跨日/UTC与本地偏移、仅已结算入库、未结算/出库/商品及库存保留；事务触发器不生成dirty。
- 预览后新增记录不纳入，修改已选记录使整笔拒绝；工作区切换、取消第一/二确认、重复点击无执行。
- 在线ack干净目标可删；dirty、冻结pending、未知结果、未解决conflict、活跃OCR明确跳过且不丢唯一副本；失败不偷偷删除。
- 主表、items、ocr、关联历史流水及所有同步JSON副本均消失，保留仅ID标记；恢复隐藏不撤销purge。
- 原ID相同/更高revision pull、重放、手动同步、重启、迟到媒体attach都不复活，cursor仍推进、同包其他单据及stock正常；不产生服务器delete。
- 同图被其他入库/出库/同步快照引用时不删；图片删除失败可重试、DB失败图片还在、重启回收日志可恢复；路径外部/占位安全。
- 两机隔离：A物理清理，B及模拟服务端数据/照片仍在；业务备份不含同步purge策略或凭据。

## 责任边界

- 数据实现owner：新增领域计划/结果模型、local_inventory_purge.dart、local_inventory_database.dart的part入口、schema新表及migration、local_inventory_sync.dart守卫和必要service媒体收尾，数据层测试。
- UI实现owner：data_management_page.dart日期时间选择、两次确认与结果，app_home.dart传入暂停/恢复封装，Widget测试。需先固定计划API/同步租约签名，避免两个owner改同文件。
- root：最终范围声明、规格、版本/构建/产物、本地提交。backend/frontend作业WIP不碰、不还原，也不得混进本功能提交。

## 相关规范与外部资料

已读.trellis/workflow.md与spec/backend/shop-incremental-sync.md。同步规范原本只规定“隐藏”不传播；本轮物理清理是用户新增例外，应由主会话更新可执行规范，不能擅改服务器协议。全部结论来自本仓库和依赖实际用法，无外部检索、新库或动态平台事实。

## 限制

只读研究，没有运行清理、修改产品、操作Git或执行测试。用户尚未明确扩大至未结算/出库，本方案不替其扩大范围。完全删除与保留同文件其他引用不可同时满足，界面必须真实报告共享引用保留数量。未同步与未知结果记录的处理应在最终设计明确，建议排除而不是冒险擦掉。
