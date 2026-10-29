# 执行

用户“创建任务并规划，自行推进”授权本轮完整推进，无需再次确认相同范围。

1. implement owner读取jsonl/spec和源码，按设计完善最小实现及有意义测试。独占mobile_app/lib/src/ui/app_home.dart、必要小型application helper、data结算API和对应tests；不改规格/版本、不提交。
2. check owner独立复核原子事务、dirty同步、局部更新、迟到刷新/重复点击/筛选及工作区边界，必要自修并补回归。
3. root同步规格、全量Flutter test/analyze，允许既有22info不得新增error/warning。版本从1.0.12+14升1.0.13+15，Android arm64 release、aapt/apksigner验证并归档releases/app-v1.0.13+15.apk。
4. 只隔离临时SQLite，不真实改用户结算。报告自动化证据与无真机限制，本地git commit、归档任务、记录日志；原拍照和OCR待真机任务保留。
