# 极速扫码界面还原与单号居中

## 范围

按2026-10-29最新要求，参考旧极速页面白底、居中标题、黑色扫码窗口的应用风格，移除说明卡片、长段教程和底部对焦指导。保留当前连续相机、扫码锁号、拍摄、存储及OCR状态逻辑；不恢复已删除的云端功能。

## 文件

- `mobile_app/lib/src/ui/express_inbound_page.dart`：仅修改build呈现及增加纯控件构建方法；白底居中标题、紧凑信息栏、黑色预览窗、圆形快门、补光/重扫和简洁最近入库。与HEAD比较，build之前扫描、捕获、存储和队列代码除新UI导入外完全一致。
- `mobile_app/lib/src/ui/express_camera_chrome.dart`：固定96高度的顶部信息区；完整快递单号居中换行、不设最大行或省略，极长及放大字体可在固定区内垂直滚动。静态遮罩和角标由轻量CustomPainter绘制，无模糊、扫描线或全屏闪烁。锁号时画框直接取相机使用的原_crop参数。
- `mobile_app/test/express_camera_chrome_test.dart`：完整长单号及窄屏大字体、真实AndroidView创建次数和尺寸稳定回归，以及本机可读视觉样张导出。

## 相机与几何保护

顶部96、状态48、操作80及最近记录74高度固定，扫描、锁号、保存期间不改变布局槽尺寸。AndroidView保持相同父节点、ValueKey和原视图代际；只切换遮罩/文字，不为样式重新创建或resize相机。扫码框为原90%×32%居中窗口，拍摄框由原 `CaptureCrop(.04,.12,.96,.88)` 计算，触摸对焦仍使用实际预览区域尺寸归一化。只有原故障重试路径仍可增加viewGeneration。

## 实际验证

- `flutter test --no-pub test/express_camera_chrome_test.dart test/express_navigation_test.dart`：**4/4通过**，日志 `/tmp/express-ui-test.txt`。
- Widget通过mock真实platform_views通道，扫描→锁号→保存成功→再扫描只有一次create、零resize，AndroidView Element和Size保持不变；锁号画框坐标与原_crop逐边相同。
- 100字符单号在360窄屏及1.3倍字体下完整保留、居中、可换行，无溢出；原返回导航回归继续通过。
- 定向Dart分析 **无问题**，相关格式及git diff检查通过。
- 视觉样张：`/tmp/express-ui-scan.png`、`/tmp/express-ui-locked.png`。使用生产顶部与画框组件，背景是静态示意颜色、底部为样张布局，不是真机相机画面或实际清晰度证据。

## 限制

不宣称真实硬件拍摄速度。静态角标、纯色遮罩及文字自身没有相机重启或固定等待；实际硬件兼容、延迟与图像仍需要真机验收。未修改pubspec版本、原生代码、app_home/数据文件、Git提交或构建发布包，最终全量检查和打包由主会话处理。
