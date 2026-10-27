# Technical Design

## Architecture and Boundaries

默认替换为官方 PP-OCRv6_small 检测+识别，使用固定发布版 ONNX Runtime 的 ARM64 CPU 精简构建。首先用官方原始FP32模型建立正确性参照，离线图优化/ORT格式转换后按实际算子和类型生成裁剪配置；运行时保留异常处理，不使用会把错误变成abort的disable_exceptions。移除既有LiteRT及其GPU/OpenCL依赖，避免同时加载/打包两个引擎。推理引擎裁剪属于技术实现目标；若实际模型转换/算子不兼容，先诊断并保留工作分支，不静默交付另一模型或完整版大引擎。

继续保留Flutter MethodChannel合同和Kotlin行分组层。项目自有JNI/C++层负责有界图片预处理、ONNX/ORT张量、DB检测框、几何校正和CTC解码，复用可证明兼容的既有纯C++图像与后处理工具；不直接复制官方SDK的OpenCV依赖。模型资产打包字典txt，由官方recognizer配置确定字符顺序与空白/空格约定，在构建/测试时校验输出类别数。

## Data Flow and Contracts

imagePath -> 有界解码/EXIF方向 -> 按模型BGR/NCHW和均值方差预处理 -> small_det -> DB候选框及映射 -> 逐行几何校正/动态宽度 -> small_rec -> CTC文本/置信度 -> Kotlin行分组 -> rows/rawText -> 现有Dart解析和后台队列。

实际ONNX输入输出、动态轴、算子、字典和后处理参数在模型检查后固化为manifest，不能仅凭网页描述硬编码。检测输入初始测试736/960长边档，按样本错误与资源证据选定有界默认；长行识别使用模型支持的动态宽度（batch1），必要时有重叠分段并经样本验证，不以拉伸丢失内容来换速度。所有阈值记录来源和测试差异。

## Resource and Lifecycle

CPU线程有上界，串行图片、逐行batch1并复用张量缓冲，避免与连续拍摄争抢资源。服务在连续请求期间复用会话，短暂闲置后释放；释放和新请求互斥，超时回调只投递一次，迟到任务不能更新新单据。模型缓存基于版本/哈希失效，升级不读取旧v5缓存。

错误使用结构化平台错误或空结果，具体诊断写受控日志，不作为rawText发送给商品解析。现有库存语义保持不变。本任务不引入未经样本验证的量化版本；后续若FP16/INT8不能证明正确性与实际资源收益，就保留原始模型精度并如实记录体积。

## Compatibility and Spec Migration

无数据库迁移；保留PaddleOcrChannel、rowMergeTolerance、图片路径和后台作业格式。当前spec中Android必须使用v5/LiteRT的限定需随真实实现更新为v6/精简ORT，保留禁止PaddleLite/OpenCV和先审核的既有规范，不借此重做极速库存业务。相机重写代码保留，旧版1.0.5+7作为回滚安装包。

## Validation and Risks

最主要风险是算子裁剪/动态轴兼容、长行几何与字典偏移、ARM64设备推理峰值和速度。用主机实际模型推理和Android原生测试分别验证数值/桥接，发布构建及APK检查验证资产和链接。无真机不能完成PSS/速度和拍照识别体验验收。最终原始small模型比v5 FP16大，不承诺总APK必然缩小。
