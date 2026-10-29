# iPhone原生适配规划

## 目标
单独列出Flutter移动端运行于iPhone的确定难点与实施规划；与手机Safari使用现有Web页面明确区分。

## 边界
仅研究和文档，不创建iOS产品代码、不安装工具链、不注册开发者账号、不发布或签名。以当前纯本地PaddleOCR及Android连续扫码拍照为基线，不恢复已移除云端AI。

## 验收
对照实际iOS工程、插件、MethodChannel、CameraX/AVFoundation、离线OCR模型/运行时、文件下载/分享/备份、权限、安全区/键盘、后台、构建签名及真机测试逐项给出证据、风险级别、方案和依赖。涉及动态平台要求以Apple/Flutter/ONNX官方资料核对，不凭记忆承诺可直接复用。研究独立于Web实施，可并行完成。
