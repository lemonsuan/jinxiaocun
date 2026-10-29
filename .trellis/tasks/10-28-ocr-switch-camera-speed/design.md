# 技术设计

## 边界

仅调整Flutter配置/识别门禁、入库图片交接、后台调度和现有Android相机。不动服务器/Web、OCR模型、库存计算和内部店铺UUID。用户追加取消拍照闪烁，普通和极速路径统一落实。

## OCR设置与许可

`LocalInventoryDatabase.loadOcrEnabled()/saveOcrEnabled(bool)`使用配置库app_settings的ocr_enabled，缺省true，无schema迁移；不复用ocr_mode，不随业务备份迁入迁出。共享、可测试的`OcrAccessPolicy`按配置库作用域共享enabled和generation；设置变化使旧许可失效，读写失败明确反馈。

所有生产PaddleOcrChannel接入同一策略。本地调用前后、业务写入之前验证许可；关闭再开启也拒绝旧代结果。2026-10-29以用户已提交的纯本地化决定为准：AiInboundExtractor、远程AI、自建OCR和AI重整仓库均已移除，不恢复这些入口。已有工作区代际、图片路径和持久job token保护继续保留。取消不能写failed或清旧明细。数据库原子更新须在事务内核对许可并在最后提交前复验，途中取消回滚全部商品/库存写入。不得在native Run中强制释放模型；沿用安全空闲释放边界。

关闭时普通/极速新单仅图和单号，needsReview且无自动识别任务；旧pending任务及原图保留。再开启只恢复原pending；手动图片识别需先开启。界面分别显示待补录、识别已暂停、退出拍摄后识别，不能统称后台识别中。开关保留用户最新放在“我的”OCR行距下方的位置及统一样式。

## 相机优先调度

`CaptureWorkCoordinator`为应用级轻量租约，`acquire()`返回幂等release。普通和极速相机页进入获取、dispose释放；队列取下一任务前检查总开关与租约，离开相机后自动kick。只暂停启动后续任务，不阻塞相机等待当前OCR结束。无额外后台轮询或队列复制。

## 普通照片交接

新增不可变`CapturedPhoto(imagePath,crop,previewAspect)`领域对象。CustomCameraPage只等待正式照片保存，轻反馈后返回，不在页面中解码/裁剪。app_home唯一调用方先可靠保存并展示原图，OCR开时通过CaptureImageProcessor在后台一次方向归一、裁剪及JPEG编码，再识别；关闭时零像素处理。移除本链路宽图擅转及PNG覆写JPEG的旧处理，不无关重写其他调用方。

原图先拥有业务引用；处理失败保留，派生图仅在写完后替换；新草稿、页面销毁、切店使旧结果无效，未引用文件可清理。

## Android拍摄

保留持续Preview+ImageCapture+扫码三流、JPEG95和原最低清单分辨率。选定相机支持isZslSupported且非低RAM时尝试CAPTURE_MODE_ZERO_SHUTTER_LAG；绑定失败清本视图资源后同画质回退MINIMIZE_LATENCY一次，不无限重绑。补光/闪光等条件以实际CameraX限制及设备结果为准，不承诺设置即生效。

保留照片有效性、文件同步及裁剪映射后的onCaptured成功事件；onCaptureStarted仅计时。日志区分请求到captureStarted、到onImageSaved、同步、映射和事件时间，Flutter补建单及下一单就绪；不得写单号、图像、OCR文本。

## 无闪烁交互

移除普通/极速全屏白色覆盖、亮度闪烁。拍摄中按钮忙碌防重入；照片保存后轻触觉一次，快门局部短暂勾和小字“已拍好，可以移开”；SQLite成功后才显示“已录入”。不加快门声，不延迟下一单只为播放动画。

## 兼容、回退与限制

设置默认on保持旧行为，原状态枚举、同步和数据路径不变；原图保留为后处理失败恢复源。ZSL可自动回退，低RAM不增加ZSL缓存。不更换相机库或SDK。无真机时只能证明路径及测试通过，实际延迟、模糊、温度和内存待同机实测。

## 2026-10-29极速视觉追加

用户认为当前极速扫码界面不如原版，要求接近旧极速页面，同时明确当前逻辑无问题。按旧源码恢复白底简洁外壳、居中标题和黑色扫码窗，配细角标/轻遮罩及整合操作区，不用持续模糊或扫描动画。扫码、锁号及拍照切换保持AndroidView树位置、Key和尺寸，避免重建相机；框线与实际拍摄crop保持一致。拍摄顶部完整快递单号居中显示，可换行，不截断，拍摄/保存期间一直可见。原有OCR状态、近期照片和失败重试仍保留。
