# brainstorm: 移动扫码入库与库存管理架构

## Goal

设计一套 App-only 的商品入库与库存统计系统架构。目标是让收货人员在安卓或苹果 App 内完成快递单号二维码扫码录入、商品清单拍照识别、商品明细确认、结算标记、历史入库查询、商品总量查询和商品出货查询；系统以本地优先和库存流水保证离线可用与数据可追溯，进价与卖价为可选字段。

## What I already know

* 用户场景：收到一堆快递后，用手机完成快递码扫码录入、商品清单拍照、商品录入与上传。
* 当前版本改为 App 完成所有操作，PC 端暂时不做。
* App 需要统计仓库中每个商品的库存数量，进价/卖价非强制。
* 每次卖出时，用户会用“采购单/出单”的形式从仓库扣减库存。
* 手机扫码设备可能是安卓，也可能是苹果。
* 每一单商品入库后，用户可以自由标记该单是否已结算。
* App 需要支持历史入库信息查询、商品总量查询和商品出货查询。
* 用户希望尽量离线完成所有操作，包括快递单号录入和商品清单识别；快递单号二维码与商品清单格式相对标准。
* 用户确认按单人单设备使用，不需要多人多手机同时录入同一仓库。
* 用户指定扫码使用原生能力。商品清单中的商品名称和数量最初要求使用 PaddleOCR Mobile + PP-Structure，后因 Android 真机 Paddle Lite 崩溃改为 Android 使用 ML Kit Text Recognition bundled 中文模型 + 自定义后处理规则离线识别。
* 用户现在要求阅读 `https://github.com/iFleey/PPOCRv5-Android` 这个完整 Android 调用 Demo，并以它为基础重写 App，使 Android 能正确识别中文商品清单。
* 已读取参考 Demo：它使用 PP-OCRv5 TFLite FP16 模型、LiteRT native runtime、Kotlin JNI、C++17、纯 C++ 图像预处理、DBNet/CTC 后处理和 GPU/NPU/CPU fallback，不依赖 Paddle Lite 或 OpenCV。
* 当前 Android OCR 使用 Paddle Lite `.nb` 模型、OpenCV 和 `libpaddle_light_api_shared.so`，与参考 Demo 的 LiteRT/TFLite 运行链不同。
* 用户已确认采用方案 A：保留 Flutter 库存 App，仅完整重写 Android OCR 引擎为参考 Demo 的 PP-OCRv5 LiteRT/TFLite 调用链。
* 用户提出新的交互调整：拍照识别/相册识别左右排布；解释并优化“生成商品草稿”；识别后商品数量可编辑；历史入库能看到商品清单；商品总量 Tab 增加出库购物车并生成出库单；出库支持多张照片记录；“出货查询”改为“历史出库”。
* 用户反馈 Android OCR 存在不同行文字被合并到同一行的问题，需要调整行分组参数。
* 用户澄清需要生成出库单；出库照片只用于从多个角度记录出库货品，不做 OCR，不参与生成商品或扣库存。
* `快递码.jpg` 显示快递面单可能存在旋转、破损、遮挡，且条码/二维码/人工手写信息并存，需要人工兜底与重复校验。
* `商品清单.jpg` 显示商品清单是表格形态，核心字段至少包括产品编号、产品名称、数量，适合 OCR + 表格解析 + 人工确认。
* 当前项目目录还没有业务源码，仅有 Trellis/Agent 配置与两张示例图片，本次按绿地系统进行架构设计。

## Assumptions (temporary)

* MVP 先支持单仓库；数据模型保留 `warehouse_id`，但不先做复杂多仓调拨。
* OCR/表格行识别结果不作为最终库存依据，必须进入人工确认页，由用户确认后才写库存。
* 快递码、商品编号、商品名称、数量是强字段；进价、卖价、备注、图片是弱字段。
* 出库业务先命名为“出库单”，如果用户业务上坚持叫“采购单”，前端可显示采购单，但底层仍按库存出库流水处理。
* App 采用本地优先架构：离线写入本地数据库，联网后再同步云端或备份端。
* PC 端、复杂后台管理台和多用户审批暂不进入 MVP。
* 单机本地数据库是 MVP 的权威数据源；云端同步如后续加入，仅作为备份，不参与库存判断。
* 跨平台框架确定为 Flutter；App 层共享业务逻辑和 UI，扫码/OCR 通过 Android/iOS 原生桥接实现。Android OCR 改为使用参考 Demo 的 PP-OCRv5 LiteRT/TFLite 调用链，iOS OCR 后续可继续沿用现有原生方案或另行替换。
* 默认不允许负库存；出货数量不能超过当前库存。
* 保留现有 Flutter 库存管理 App 与 MethodChannel 合同，只重写 Android OCR 引擎；不改成纯 Android Compose App。

## Open Questions

* 暂无。

## Requirements (evolving)

* App 支持创建入库单、通过原生扫码录入快递单号二维码、拍商品清单、查看 OCR 草稿、人工修正明细、确认入库。
* App 必须支持快递码识别失败后的手工输入。
* App 必须支持离线草稿、离线确认入库、离线出货记录和离线查询。
* App 拍摄商品清单后必须将图片原件保存到本地 App 沙盒，并在历史入库中可查看，便于 OCR 未识别时回看人工核对。
* App Android 端使用参考 Demo 的 PP-OCRv5 LiteRT/TFLite OCR 调用链在端侧识别商品清单文本，并按文字坐标分组成可编辑的行/单元格草稿，识别结果必须进入人工确认页。
* App Android 端需要替换现有 Paddle Lite `.nb` OCR 运行链；是否保留 ML Kit 作为 fallback 待实现时按风险评估。
* Android `inventory_app/paddle_ocr.recognizeTable` 对 Flutter 的返回合同保持 `{ rows, rawText }`，避免影响库存业务页面。
* Android OCR 仍运行在独立服务/隔离流程中，失败或超时时主 Flutter 页面必须继续返回可编辑草稿。
* Android OCR 行分组需要避免把不同商品行合并到同一行；优先收紧 native `centerY`/文本框高度阈值，并用后处理测试兜底。
* App 必须提供自定义后处理规则：清洗 OCR 文本、修正数量列、合并换行商品名、过滤页眉页脚、按产品编号/名称/数量映射成入库明细草稿。
* App 入库 OCR 完成后应自动生成商品草稿；“生成商品草稿”按钮应改成用于用户编辑 OCR 文本后的重新解析动作。
* App 识别后的商品草稿必须支持编辑商品编号、商品名称和数量。
* App 支持对每一张入库单自由标记“已结算/未结算”，该标记在历史入库中也可以修改，且不影响库存数量。
* App 支持历史入库按入库单号或快递单号快捷搜索，并在历史入库单内查看已确认商品清单明细。
* App 商品总量 Tab 支持把库存商品加入出库购物车，编辑出库数量后生成出库单并扣减库存。
* App 出库单支持多张照片附件作为货品多角度记录；这些照片不做 OCR。
* App 将“出货查询”调整为“历史出库”，用于查询历史出库单、商品明细和照片附件。
* App 快递码扫码入口优先只识别一维条形码，不识别二维码，避免快递面单上的二维码干扰条码单号录入。
* App 支持通过系统文件选择器导出本机备份到用户指定位置，并通过系统文件选择器选择备份文件导入。
* 备份必须包含本地库存数据库记录和入库图片；导入按覆盖恢复处理，导入前必须提示用户确认。
* 库存必须以本地 `stock_ledger` 为真实账本，聚合库存表只作为查询加速。
* 入库确认、出库确认必须在本地事务内完成，避免重复提交导致库存错误。
* 图片原件应保存到本地 App 沙盒；联网同步时再上传云端或备份端。
* OCR 解析优先本机执行，状态包括 `pending`、`processing`、`needs_review`、`confirmed`、`failed`。

## Acceptance Criteria (evolving)

* [ ] 用户可在手机上扫描或手输快递单号，并创建入库草稿。
* [ ] 用户可拍摄商品清单，系统生成可编辑的商品明细草稿。
* [ ] Android 端基于 PP-OCRv5 LiteRT/TFLite 对中文商品清单输出可用 rawText 和行级 OCR 结果。
* [ ] Android 端相邻商品行不会因为行分组阈值过宽被合并成一行；合并场景也能被 Dart 后处理尽量拆回商品草稿。
* [ ] `商品清单.jpg` 或等价中文商品清单样例能解析出产品编号、中文商品名称和数量草稿。
* [ ] 用户拍摄后的商品清单图片能随入库单保存，并能在历史入库中查看。
* [ ] 用户离线确认入库后，库存数量准确增加，并记录库存流水。
* [ ] 用户可在 App 内按入库单号或快递单号查询历史入库记录，并查询商品总量和商品出货记录。
* [ ] 用户可在历史入库中查看该入库单的商品清单明细。
* [ ] 用户可在商品总量中将商品加入出库购物车，并从购物车生成出库单。
* [ ] 用户可给一张出库单保存多张照片附件，并在历史出库中查看。
* [ ] 用户可在 App 内标记某一单是否已结算，并能在历史入库中更改该状态。
* [ ] 用户可将库存数据和图片导出为备份文件，并可从备份文件覆盖恢复本机数据。
* [ ] 用户可在 App 内创建出货记录，确认后库存准确扣减。
* [ ] 进价和卖价为空时不阻塞入库或出库。
* [ ] 同一个快递单号重复提交时，系统能提示并阻止重复入库。
* [ ] 出货数量超过当前库存时，系统阻止确认并提示库存不足。

## Definition of Done (team quality bar)

* 架构方案已确认，MVP 范围已明确。
* Tests added/updated where implementation touches backend inventory transactions or frontend scanner/OCR review workflows.
* Lint / typecheck / CI green after implementation.
* Docs/notes updated if behavior changes.
* Rollout/rollback considered if risky.

## Out of Scope (explicit)

* 暂不接电商平台自动订单同步。
* 暂不接快递公司实时物流查询。
* 暂不做 PC 端管理台。
* 暂不做财务利润报表、采购对账、供应商结算。
* 暂不做复杂多仓调拨、盘点盈亏审批流。
* 暂不承诺 OCR 自动 100% 入库，人工确认是 MVP 必须步骤。

## Technical Notes

* Task directory: `.trellis/tasks/05-15-mobile-inbound-inventory-architecture/`
* Architecture plan: `plans/移动扫码入库库存架构_20260515.md`
* Rewrite plan: `plans/PPOCRv5中文商品清单识别重写_20260518.md`
* Research notes: `.trellis/tasks/05-15-mobile-inbound-inventory-architecture/research/scanning-ocr-options.md`
* PPOCRv5 Android LiteRT demo notes: `.trellis/tasks/05-15-mobile-inbound-inventory-architecture/research/ppocrv5-android-litert-demo.md`
