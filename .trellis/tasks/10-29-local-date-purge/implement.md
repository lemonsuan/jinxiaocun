# 实施

用户明确优先完成本功能并要求彻底本机清除，两次确认；沿现有已结算范围，不执行任何真实清理。数据owner负责领域模型/part/schema/sync守卫及数据测试；UI owner只data_management_page.dart/app_home.dart及Widget测试；root负责版本和规格/产物/提交，不混入backend/frontend作业WIP。先固定prepareLocalPurge/executeLocalPurge/结果字段，两owner直接协调。

依次实现数据及UI、独立检查、真实SQLite全边界和同步不复活/图片引用/回滚测试、两次确认取消Widget、完整Flutter分析/测试和Android release。App升1.0.12+14，根releases/app-v1.0.12+14.apk，签名/版本检查。仅提交本功能路径，作业WIP继续保留待恢复。范围和保护排除必须在界面明示，不悄悄扩至未结算/出库。默认测试隔离库，不删用户记录。
