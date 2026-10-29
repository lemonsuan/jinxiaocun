# 手机结算状态切换提速实施

## 修改边界

只改`mobile_app/lib/src/ui/app_home.dart`和`data/local_inventory_database.dart`以及两份新测试。主会话独占版本/规格/构建和提交；未改Web、数据库schema、OCR业务或全量历史查询实现，未操作用户业务数据。

## 最终行为

- `setReceiptsSettled(Iterable<String>, bool)`去重并在一个事务中按400个ID分组校验及更新。任一缺失/后段写失败整批回滚，正常dirty触发器继续生效；同值不重复update，库存、账本、明细和图片引用不变。单条旧API代理统一入口，工作区选择已变化则拒绝写。
- AppHome单条与核验车共享父回调：只等待本机事务，成功按ID对当前内存对象copyWith，保留其他最新字段，不读取全部库存/入库/出库。pending集合防重；写失败不改显示，mounted及processingScope校验阻止迟到状态应用。
- 核验车维护自己的receipt列表副本；回调返回父当前列表，子页更新本地匹配项和结算计数，重新查询与返回主页一致，不修改widget外部列表，不假定列表可变。
- 刷新使用request序号与settlementRevision。后发完整刷新优先；只有最新请求被结算写入淘汰时才发起一次后台补刷新，不由按钮await，防丢同期OCR/库存变化。补刷新不保留长期补丁，后来合法同步状态正常可见。补刷失败catch中文提示，保存结果保留，下一次刷新可恢复；没有无条件重试循环。

## 验证

- `flutter test --no-pub test/settlement_response_test.dart test/settlement_response_widget_test.dart`：**10/10通过**（数据2、Widget8），输出`/tmp/settlement-impl-tests.txt`。
- 真实SQLite覆盖：去重、仅结算字段变化、明细/图片/库存/账本保留、同值dirty不递增、单条兼容、缺失整批拒绝、空集合。
- Widget使用真实临时SQLite及受控Completer：重复点击只写一次、局部更新零整库读取、筛选即时变化、成功/失败并发旧刷新、实际OCR结果与库存回接、后续外部合法结算变化、核验车一次批写/计数/父子一致、卸载、scope变化、补刷新故障恢复、乱序完整刷新。
- 定向`dart analyze`：无error/warning，新代码无info；AppHome原有3条info（两条旧BuildContext、一条旧withOpacity）保留，输出`/tmp/settlement-impl-analyze.txt`。
- 定向format与`git diff --check`通过。
- 首次Widget批量返回使用pageBack不适配fullscreenDialog，改直接Navigator pop；最后乱序fixture空商品非SF触发原业务必填校验，改合法1件商品。均未放宽产品业务规则，最终全过。

## 后续

实现及测试已冻结，独立checker负责联合复核，主会话跑完整Flutter测试/分析、版本化Android release归档。没有连接真机，不能报告实际手机耗时或FPS提升。未提交、未构建、未修改版本号。
