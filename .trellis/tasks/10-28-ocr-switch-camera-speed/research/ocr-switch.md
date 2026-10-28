# 研究：设备级OCR总开关与入库兼容

- 查询：如何以最小改动关闭所有图片识别、保留快录和手工补录，并安全暂停旧队列与拒绝迟到结果。
- 范围：内部代码、测试、现有跨端协议；不实施产品代码。
- 日期：2026-10-28。

## 结论

新增独立 `ocr_enabled` 设备级设置，默认开启以兼容既有安装；不复用 `ocr_mode`。关闭期间的新单使用现有 `needsReview`，只存照片与单号，无商品则不增加库存；不新增跨端枚举。旧 pending 保留并暂停，重新开启后仅恢复旧 pending，关闭期间新单不自动补跑。纯文本AI提取保留，不受图片OCR开关控制。

图片入口统一使用可注入的权限/代际门禁；在调用本地推理或发送图像识别请求之前校验，返回后和业务应用前再次校验。关闭乃至快速关闭再开启都递增代际。关闭触发的取消不是识别失败，不把旧 pending 改 failed，也不删除原照片。

## 文件与代码证据

| 文件 | 作用与证据 |
|---|---|
| `mobile_app/lib/src/data/local_inventory_database.dart:33-38` | `_settings = _configuration ?? _db`，普通运行是配置库，注入数据库测试回退同库。 |
| `mobile_app/lib/src/data/local_inventory_scope.dart:10-15` | 配置库为设备目录的 `inventory_config.db`，独立于按server/shop分离的业务库。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:95-121` | 已有OCR行距设置读写模式，可参考新增enabled读写，无需schema升级。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:371-394` | `ocr_mode`值local/self_hosted，是后端选择而非总开关。 |
| `mobile_app/lib/src/domain/models.dart:1` | 已有pending/processing/needsReview/confirmed/failed。 |
| `backend/inventory/models.py:35-48` | 后端支持needsReview；Web `InventoryViewer.vue:26` 显示待核对。 |
| `mobile_app/lib/src/data/local_inventory_sync.dart:372,468` | 同步接受现有枚举并持久化原状态；不需后端或Web改动。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:423-428,633-639,702-706` | 业务备份仅保留express_image_job配置，导入也只恢复此类；设备OCR开关不会随业务备份覆盖。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:834-856,868-893` | confirmInbound支持显式ocrStatus；默认confirmed空明细仅允许特定单号，expressToken存在才建立持久任务。关闭新单传needsReview且不传expressToken，可保持无商品库存不增加。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:942-979` | OCR落库先校验job编码、源图及pending/processing状态，已有防手工修改、重试代际、照片替换的基础。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:1037-1042,1085-1091` | 队列仅取pending/processing；needsReview自然不自动处理。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:1094-1121` | 现重试只支持failed；关闭期间新needsReview无express任务，应使用已有照片手动重识别入口，不假定旧retry函数能用。 |
| `mobile_app/lib/src/data/local_inventory_database.dart:1160-1163` | 手工商品修改先删除express任务，使旧处理结果失效。 |
| `mobile_app/lib/src/application/express_processing_queue.dart:44-75` | 队列每次构造Paddle channel，无开关；每单先Dart裁剪再识别。构造Dart对象本身不加载原生模型。 |
| `mobile_app/lib/src/application/express_processing_queue.dart:91-106` | 所有异常被标failed，专用关闭/取消异常必须单独处理；finally按引用清理输出，保留现有安全语义。 |
| `mobile_app/lib/src/platform/paddle_ocr_channel.dart:27-43` | 本地识别的唯一Dart MethodChannel入口，适合注入统一权限对象并前后验证代际。 |
| `mobile_app/lib/src/ui/app_home.dart:3343-3347` | 启动即kick队列，新设置必须在调度前加载或由next自行检查，不能仅等Widget state刷新。 |
| `mobile_app/lib/src/ui/app_home.dart:1029-1033` | 备份恢复后也kick队列，必须同样受开关控制。 |
| `mobile_app/lib/src/ui/express_inbound_page.dart:55-58,171-186` | 页面初始化和每次入库都会kick；现始终pending+任务，成功文案始终后台识别中，都需条件化。 |
| `mobile_app/lib/src/ui/express_inbound_page.dart:439-456` | 最近单据只区分failed、confirmed与其余，needsReview会错误显示后台识别中；旧pending关闭时应显示识别已暂停。 |

## 全部图片识别入口

1. `app_home.dart:3190-3200,3233-3247` 普通拍照后保存并识别；`3211-3222` 相册共用 `_processImage`。关闭时仍保存图片，直接进入可补录状态，不调用平台。
2. `app_home.dart:1905-1916` 历史图片二次识别，可选本地或图像AI；关闭时入口清晰提示，不先旋转、清空已有商品再报禁用。
3. `app_home.dart:3934-3941` 当前图片重新生成OCR文本；须门禁。
4. `express_processing_queue.dart:67-89` 极速后台识别；关闭时next返回null保留旧pending，重启/恢复/再次kick都不会绕过。裁剪之前、OCR之前、结果应用之前检查permit；若关闭中发生取消，仅保留pending并清理未引用派生图。
5. `ai_inbound_extractor.dart:201-262` 图片AI根据ocr_mode使用自建远程OCR或本机OCR后再调用云端AI。入口与 `_postRemote` 图片路径都需复验permit。
6. `ai_rebuild_warehouse_page.dart:76,100-108,174-182` 单张和批量AI重建仓库。内部都走extractFromImage，可由服务级拦截，但批量循环需遇到禁用后停止，不继续把所有单据记失败；写入前再校验原permit。
7. `ai_inbound_extractor.dart:112-118` `extract(String ocrText)` 是纯文本AI，不受本轮OCR开关限制；原完全本地禁网和工作区保护仍保持。

`rg '\\.recognizeTable\\(|extractFromImage\\(' mobile_app/lib` 未发现其他图片识别生产调用。未来调用必须复用带门禁的channel/service，不能只隐藏UI按钮。

## 最小统一门禁方案

建议新增纯Dart `OcrAccessPolicy`/permit对象：loaded、enabled、generation，保存委托通过数据库读写 `ocr_enabled`；共享实例按配置库身份或规范路径区分，避免不同工作区分别缓存旧状态。测试临时目录之间不得共享静态enabled。

- 默认true，第一次await load后才可capture permit。设置关闭同步递增generation并阻止新许可，持久化失败明确回滚/报错，不能界面显示关闭而底层继续启动。
- `PaddleOcrChannel`构造注入policy；生产构造点仅app_home、ExpressProcessingQueue和AiInboundExtractor三处。已有channel解析测试可注入默认开启的fake policy；不要让测试绕过生产调用默认约定。
- `recognizeTable` 调用前取得permit；平台future完成后validate，即便off→on也不能接纳上一代结果。
- `AiInboundExtractor.extractFromImage`捕获permit，传到可选参数的 `_extract/_postRemote` 供图片识别路径前后校验；纯文本extract不传permit，保持原行为。已有 `_remoteContext/_checkContext` 工作区保护继续执行，不能以OCR开关取代。
- UI及持久队列在最终写入或覆盖商品前验证同一permit；现有job token/path/status条件仍必须保留。若业务事务已开始，需要明确定义关闭边界或在事务中再次验证，不能把外层一次bool判断当事务授权。
- 队列关闭时既不调OCR也不裁剪，保留旧pending和任务；新needsReview不创建任务。重新开启主动kick当前旧队列；切到另一旧工作区后启动队列同样先验证设置。
- 关闭时手工识别按钮可禁用并显示“请先在设置开启OCR”，手工商品编辑保持可用；既有商品不清空。

### 原生释放

`OcrService.kt:26-27` 用单执行线程，engine在executor.terminated释放；`:99-104` shutdown不会并发销毁正在推理的native handle，现有自然空闲释放为10秒。若加入显式release方法，应复用安全shutdown/空闲释放，允许当前native请求结束但丢弃过期结果，不在Run中强行free或kill进程。Dart停止新调用即可保证关闭后不再初始化模型；是否立即回收旧进程RSS需单独测量，不能只靠开关文案宣称零占用。

## 建议测试与断言

- 真实SQLite配置：默认true、保存false重开仍false、本地/A/B切换不变、业务备份导出/恢复不覆盖开关、两个临时设备目录互不影响。
- MethodChannel mock：关闭零recognizeTable调用；调用中关闭后成功结果被拒；off→on也拒旧结果；新的on请求可成功。
- 队列注入fake处理器及OCR：关闭zero crop/zero OCR；旧pending任务保留；开启仅旧pending恢复；关闭期间needsReview不入队；关闭取消不记failed、不丢原图、不写库存。
- 现express_persistence_test已有原子建单、token/path失效、手工修改、删除、备份路径映射测试，保留并加开关竞态，不重写相同断言。
- Widget：设置开关保存和文案；普通/极速关闭只图入库（任意有效单号）、needsReview可补商品；重新识别提示；旧pending显示暂停；历史confirmed商品/库存不变。
- 图像AI以有效配置及HTTP mock验证禁用零图像远程调用，异步配置读取后关闭仍不发送，自建OCR响应后关闭不继续云端AI；纯文本AI在允许联网工作区仍正常。
- 批量AI重建启动前和中途关闭，停止后续图片调用，原库存/商品保留；用户手工修改后旧图片结果不能覆盖。
- 本轮应跑flutter test、analyze和Android构建；真机资源与拍摄延迟无设备时保持待验。

## 建议责任边界

OCR实施者负责：`domain/ocr_settings.dart`或新增纯策略文件、`data/local_inventory_database.dart`设置与必要防护、`application/express_processing_queue.dart`、`platform/paddle_ocr_channel.dart`、`ocr/ai_inbound_extractor.dart`及对应测试。

UI整合实施者负责：`ui/app_home.dart`、`ui/express_inbound_page.dart`、`ui/ai_rebuild_warehouse_page.dart`及Widget测试。若并行，先确定策略API与原生release接口所有权，避免两人同时改app_home或express页。

相机实施者负责普通/极速相机和图像处理路径，不应改变OCR状态协议；需要express页面接入资源协调时同UI整合者约定。

## 相关规范

- `.trellis/spec/frontend/directory-structure.md`：数据访问与UI、平台桥边界。
- `.trellis/spec/frontend/quality-guidelines.md`：正式照片、真实反馈、持久任务与迟到结果保护。
- `.trellis/spec/frontend/remembered-workspace.md`：设备配置与业务库分离、纯本地禁网、切店后旧响应不能应用。
- `.trellis/spec/backend/shop-incremental-sync.md`：原UUID作用域、增量同步和库存语义不变。

## 限制与未发现项

没有运行产品测试或修改产品代码；此研究仅依据现代码。不引入新OCR模型、后端迁移或网络查询。默认开启、旧pending恢复、关闭新单不补跑和纯文本AI保留为父会话明确的当前规划方向。当前PRD处planning，研究不代表已授权实施或真机通过。

## 与相机研究的交接契约

父会话已协调相机研究：`CustomCameraPage`唯一调用点为 `app_home.dart:3194`，拟返回 `CapturedPhoto(rawPath,crop,previewAspect)`，相机实施者新增领域类并修改CustomCameraPage，不修改app_home。

OCR/UI实施者负责适配 `_captureAndRecognizeList/_processImage`：收到原始照片后先可靠保存并展示；OCR关闭时既不裁剪，也不调用 `_ensureVerticalImage`；OCR开启时由后台处理一次裁剪和方向归一后再识别，避免现有_processImage额外完整decode。相册仍返回XFile，需保持其入口兼容。裁剪失败保留原图和可重试提示，不能将后处理失败描述为拍摄保存失败或删除原图。该返回类型属于本轮实施接口，合并时由两责任方共同核对，不得各自猜字段。
