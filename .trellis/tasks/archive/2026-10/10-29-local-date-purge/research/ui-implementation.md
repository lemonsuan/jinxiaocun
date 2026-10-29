# 本机时间段清理 UI 实施

## 修改范围

- `mobile_app/lib/src/ui/data_management_page.dart`：独立新增按时间段物理清理卡，不改变旧隐藏/清理入口语义。按本机时间选择起止日期与分钟，结束分钟包含59.999999秒；非法时间拒绝预览。调用领域计划展示真实可清数量、跳过原因和共享图片保留量。第一确认范围，第二确认仅本机物理移除及恢复隐藏不能找回；取消任一步不执行。零匹配只提示。执行期间禁用正文所有操作，避免重复提交与并行备份/还原/压缩；结果明确待回收图片，不把部分失败说成完全成功。异步使用mounted检查，备份列表加载也增加离页保护。
- `mobile_app/lib/src/ui/app_home.dart`：传入维护租约，捕获当次现有ShopSyncService实例，pauseAndDrain后提供幂等release配对resume；本地模式不创建网络服务。租约覆盖预览、两次确认和执行，所有返回/异常由finally恢复，不持数据库事务等待用户。
- `mobile_app/test/local_purge_widget_test.dart`：临时目录+真实SQLite，未碰用户库。覆盖零匹配、取消第一/第二、第二确认才执行一次且库存保留、预览后变更整笔拒绝；每个路径验证租约恢复。

## 检查

- Dart定向format通过。
- `flutter test --no-pub test/local_purge_widget_test.dart`：5项通过。
- 定向analyze：无error/warning，6条原页面既有info（旧导出上下文、withOpacity与Share旧接口），新代码无info。
- `git diff --check`通过。

## 剩余

由root进行全套回归、独立检查与版本化构建归档；本owner不提交、不改版本、不打包。文件回收安全/同步不复活由数据owner测试。无真机视觉验收，日期时间选择复用Flutter原生控件；未扩大清理范围至未结算/出库/库存。未清理已有导出备份，未承诺介质取证级安全擦除。
