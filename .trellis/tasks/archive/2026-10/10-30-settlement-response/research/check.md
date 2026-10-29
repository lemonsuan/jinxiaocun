# 独立检查

状态：实现两文件及测试已冻结，无剩余已知产品阻塞。检查仅用隔离临时SQLite和受控Widget，不操作用户实际数据库；完整Flutter/Android构建由root统一执行。

## 检查结论

- 单条`setReceiptSettled`代理批量API，数据层每400个ID分片、同一事务、存在性复验、只更新实际变化的`is_settled`，正常dirty触发器保留，不改schema或库存。
- AppHome状态写成功后按ID对当前receipt.copyWith，不await全库存或历史；同ID保存中禁止第二次提交，不同单据保留当前其他字段，状态筛选立即使用新值。
- 核验车回调统一交父页面执行最小事务和局部内存更新，自身拥有列表副本，不再修改外部const/fixed列表；目标ID在提交前冻结，查询结果使用最新父列表映射。
- request generation拒绝旧刷新晚覆盖新刷新；settlementRevision使写前读取失效。只有最新请求发现revision变化才后台补读，不由按钮等待，不让已被较新刷新替代的旧请求重复补读。之后新刷新照常接纳外部合法状态，无永久本机补丁。
- 新后台补刷有catch，失败保留已保存状态并中文提示；不会逃逸为未处理异步异常，也不自行无限重试，之后刷新仍可恢复。
- 作用域与mounted检查阻止迟到页面应用；单条失败不显示新状态。未改照片、OCR或联网同步业务。

## 已发现并修正

- 最初仅增加刷新代际并直接丢弃旧刷新，会同时丢掉同期库存或OCR变化，保存失败也会失去原刷新结果。已交实现owner修正为独立request generation与settlementRevision，加最新失效请求后台补读；Widget覆盖成功和失败两条路径的同期OCR、入库和库存变化。
- 新后台补读查询失败可能逃逸原调用方catch。已交owner仅捕获新增后台分支；Widget覆盖失败提示、已保存状态保留及下一次刷新恢复。
- 新增旧/新完整刷新顺序测试最初调用confirmed入库却传空商品，违反原业务校验；联合定向检查发现后由owner机械改为合法SKU商品，最后10项定向全部通过。没有为了测试放宽产品入库约束。

## 独立回归与命令

`mobile_app/test/settlement_review_test.dart`两项使用临时真实SQLite：

1. 1205单跨400参数分片，最后一单BEFORE UPDATE触发器故意中止，所有状态及dirty代际全部回滚；移除故障后全部成功且每单代际恰好+1。
2. 1205单后追加缺失ID，整批失败，已有记录、dirty代际和库存流水均不变。

- `flutter test --no-pub test/settlement_review_test.dart`：2/2通过。
- `dart analyze test/settlement_review_test.dart`：无问题。
- 对实现与三个新测试文件的定向`dart analyze`：无error/warning，仅AppHome既有3条info（原异步context和withOpacity），新代码无新增info。
- 实现owner最终`settlement_response_test.dart`及`settlement_response_widget_test.dart`：10/10通过；本检查已读取对应受控IO断言，覆盖零整库读取、重复点击、筛选、父子回显、卸载、作用域、旧刷新、后台补刷失败与正常新状态。
- root完整Flutter测试：148项通过、1项可选真实服务测试跳过；完整分析无error/warning，仅原22条info。Android构建进行中，产物验证仍由root负责。

Widget测试使用短轮询drain推进受控SQLite I/O，本轮完整并发测试已通过，未发现等待不稳定；按root要求保持冻结，不为假设性风险额外改测试。无真机连接，不声称具体毫秒提升或已做手机性能验收。

检查者新增独立测试及此报告，未修改实现owner文件、未提交、未构建。
