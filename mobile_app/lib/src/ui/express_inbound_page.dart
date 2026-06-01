import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../data/local_inventory_database.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/paddle_ocr_channel.dart';

class ExpressInboundPage extends StatefulWidget {
  const ExpressInboundPage({
    super.key,
    required this.database,
    required this.paddleOcr,
    required this.postProcessor,
    required this.ocrRowMergeTolerance,
    required this.onRefreshHomeData,
  });

  final LocalInventoryDatabase database;
  final PaddleOcrChannel paddleOcr;
  final PpStructurePostProcessor postProcessor;
  final double ocrRowMergeTolerance;
  final VoidCallback onRefreshHomeData;

  @override
  State<ExpressInboundPage> createState() => _ExpressInboundPageState();
}

class _ExpressInboundPageState extends State<ExpressInboundPage> {
  static const _notionText = Color(0xFF37352F);
  static const _notionBorder = Color(0xFFEDEDEB);
  static const _notionGreyText = Color(0xFF7C7B77);

  static const List<BarcodeFormat> _linearBarcodeFormats = [
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.codabar,
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.itf2of5,
    BarcodeFormat.itf2of5WithChecksum,
    BarcodeFormat.itf14,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
  ];

  final MobileScannerController _controller = MobileScannerController(
    formats: _linearBarcodeFormats,
  );

  // 自定义相机管理变量
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  bool _isCameraInitialized = false;
  bool _isCameraLoading = false;

  // 状态变量
  List<InboundReceipt> _recentReceipts = [];
  String? _currentTrackingNumber;
  bool _isScanningLocked = false;
  bool _isProcessing = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadRecentReceipts();
    _detectAvailableCameras();
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    unawaited(_disposeCustomCamera());
    super.dispose();
  }

  Future<void> _detectAvailableCameras() async {
    try {
      _cameras = await availableCameras();
    } catch (e) {
      debugPrint('获取可用相机列表失败: $e');
    }
  }

  Future<void> _disposeCustomCamera() async {
    if (_cameraController != null) {
      await _cameraController!.dispose();
      _cameraController = null;
    }
    _isCameraInitialized = false;
  }

  // 初始化并独占相机硬件
  Future<void> _initCustomCamera() async {
    if (_cameras.isEmpty) {
      try {
        _cameras = await availableCameras();
      } catch (e) {
        setState(() {
          _message = '无法获取相机硬件: $e';
        });
        return;
      }
    }

    if (_cameras.isEmpty) {
      setState(() {
        _message = '未检测到可用摄像头';
      });
      return;
    }

    setState(() {
      _isCameraLoading = true;
      _message = '正在切换并接管摄像头...';
    });

    try {
      // 优先后置摄像头
      final backCamera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _cameraController = controller;
      await controller.initialize();
      
      // 锁定传感器快门为纵向，实现强制垂直图片
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
          _isCameraLoading = false;
          _message = '请对准商品清单/入库单，并点击下方拍照';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCameraLoading = false;
          _isCameraInitialized = false;
          _message = '相机初始化失败: $e';
        });
      }
    }
  }

  /// 从数据库加载最近5条入库记录
  Future<void> _loadRecentReceipts() async {
    final receipts = await widget.database.loadRecentInboundReceipts(5);
    if (mounted) {
      setState(() {
        _recentReceipts = receipts;
      });
    }
  }

  // 保存图片至本地文档目录
  Future<String> _storeInboundImage(XFile image) async {
    final appDir = await getApplicationDocumentsDirectory();
    final inboundDir = Directory('${appDir.path}/inbound_images');
    if (!inboundDir.existsSync()) {
      inboundDir.createSync(recursive: true);
    }
    final extension = image.path.split('.').last;
    final filename = 'inbound_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final targetPath = '${inboundDir.path}/$filename';
    await File(image.path).copy(targetPath);
    return targetPath;
  }

  // 自定义拍照快门并执行一键异步入库
  Future<void> _takeCustomPhotoAndInbound() async {
    if (_currentTrackingNumber == null || _cameraController == null || !_isCameraInitialized) return;

    setState(() {
      _isProcessing = true;
      _message = '快门已触发，正在捕获清单图像...';
    });

    try {
      // 1. 调用自定义相机控制器拍摄
      final image = await _cameraController!.takePicture();

      setState(() {
        _message = '正在进行图片垂直纠偏与格式化...';
      });

      // 2. 拷贝图片到沙盒并强制进行二次垂直方向校验
      final storedImagePath = await _storeInboundImage(image);
      await _ensureVerticalImage(storedImagePath);

      setState(() {
        _message = '正在写入待处理入库单...';
      });

      // 3. 在本地数据库中以 pending 状态创建入库单
      final receipt = await widget.database.confirmInbound(
        trackingNumber: _currentTrackingNumber!,
        items: const [],
        imagePath: storedImagePath,
        ocrStatus: OcrStatus.pending,
      );

      // 4. 抛出非阻塞 PaddleOCR-VL-1.6 的识别与回写
      unawaited(_runAsyncOcr(receipt.id, storedImagePath));

      // 5. 释放相机控制权以让给扫码器
      await _disposeCustomCamera();

      // 6. 重启扫码摄像头
      await _controller.start();

      final savedNum = _currentTrackingNumber!;
      if (mounted) {
        setState(() {
          _message = '快递 $savedNum 入库成功，正在提取商品明细';
          _currentTrackingNumber = null;
          _isScanningLocked = false;
          _isProcessing = false;
        });
      }

      // 从数据库重新加载最近记录
      await _loadRecentReceipts();

      // 回调刷新主页面数据
      widget.onRefreshHomeData();

    } catch (e) {
      setState(() {
        _isProcessing = false;
        _message = '入库处理失败：$e';
        _currentTrackingNumber = null;
        _isScanningLocked = false;
      });
    }
  }

  // 异步非阻塞商品清单识别与状态回填
  Future<void> _runAsyncOcr(String receiptId, String imagePath) async {
    try {
      final recognition = await widget.paddleOcr.recognizeTable(
        imagePath,
        rowMergeTolerance: widget.ocrRowMergeTolerance,
      );
      final rows = recognition.rows;
      final editableText = recognition.editableText;
      final orderNumber = widget.postProcessor.extractSellerOrderNumber(editableText);

      var items = widget.postProcessor.processRows(rows);
      if (items.isEmpty && editableText.isNotEmpty) {
        items = widget.postProcessor.processPlainText(editableText);
      }

      // 事务回填数据
      await widget.database.updateInboundOcrResult(
        receiptId: receiptId,
        items: items,
        ocrStatus: OcrStatus.confirmed,
        sellerOrderNumber: orderNumber,
      );

      widget.onRefreshHomeData();
    } catch (_) {
      // 降级标记为识别失败
      await widget.database.updateInboundOcrResult(
        receiptId: receiptId,
        items: const [],
        ocrStatus: OcrStatus.failed,
      );
      widget.onRefreshHomeData();
    }
  }

  // 物理重置锁定状态
  void _resetCurrentScan() {
    setState(() {
      _currentTrackingNumber = null;
      _isScanningLocked = false;
      _message = '已重置扫码状态，扫码器已就绪';
    });
  }

  /// 如果图片是横屏（宽度 > 高度），将其物理旋转 90 度为竖屏
  Future<void> _ensureVerticalImage(String path) async {
    try {
      final File file = File(path);
      if (!file.existsSync()) return;

      final Uint8List bytes = await file.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      final int width = image.width;
      final int height = image.height;

      // 如果宽度大于高度，则是横屏图，强制逆时针旋转90度（即顺时针旋转270度）
      if (width > height) {
        final double angle = 270 * 3.141592653589793 / 180;
        final int targetWidth = height;
        final int targetHeight = width;

        final ui.PictureRecorder recorder = ui.PictureRecorder();
        final ui.Canvas canvas = ui.Canvas(recorder);

        canvas.translate(targetWidth / 2, targetHeight / 2);
        canvas.rotate(angle);
        canvas.translate(-width / 2, -height / 2);
        canvas.drawImage(image, Offset.zero, ui.Paint());

        final ui.Picture picture = recorder.endRecording();
        final ui.Image rotatedImage = await picture.toImage(targetWidth, targetHeight);
        final ByteData? byteData = await rotatedImage.toByteData(format: ui.ImageByteFormat.png);

        if (byteData != null) {
          await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
        }
        rotatedImage.dispose();
      }
      image.dispose();

      // 清理 Flutter ImageCache 缓存，防止缩略图缓存不刷新
      PaintingBinding.instance.imageCache.evict(FileImage(file));
    } catch (e) {
      debugPrint('图片纠偏异常: $e');
    }
  }

  // 大图预览照片
  void _showReceiptImage(String imagePath) {
    final file = File(imagePath);
    if (!file.existsSync()) {
      setState(() {
        _message = '照片文件不存在';
      });
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) {
          return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: const Text('照片预览', style: TextStyle(fontFamily: 'monospace', fontSize: 15)),
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                return InteractiveViewer(
                  maxScale: 5,
                  child: SizedBox(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    child: Image.file(file, fit: BoxFit.contain),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          '极速模式',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            fontSize: 16,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(
            color: _notionBorder,
            height: 0.8,
          ),
        ),
      ),
      body: Column(
        children: [
          // 1. 顶部扫码区域
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '扫描快递单号：',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _notionGreyText,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: 240, // 取景器适当拉高，更符合拍照比例
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 1.2),
                    color: Colors.black,
                  ),
                  child: Stack(
                    children: [
                      // 1. 独占控制：就绪展示自定义相机预览，否则展示扫码
                      Positioned.fill(
                        child: _isScanningLocked && _isCameraInitialized && _cameraController != null
                            ? CameraPreview(_cameraController!)
                            : MobileScanner(
                                controller: _controller,
                                onDetect: (capture) async {
                                  if (_isScanningLocked || _isProcessing || _isCameraLoading) return;
                                  final barcodes = capture.barcodes;
                                  for (final barcode in barcodes) {
                                    final raw = barcode.rawValue;
                                    if (raw != null && raw.isNotEmpty) {
                                      setState(() {
                                        _currentTrackingNumber = raw;
                                        _isScanningLocked = true;
                                      });
                                      await _controller.stop();
                                      await _initCustomCamera();
                                      break;
                                    }
                                  }
                                },
                              ),
                      ),

                      // 2. 加载相机的 Notion 黑遮罩进度
                      if (_isCameraLoading)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withOpacity(0.85),
                            alignment: Alignment.center,
                            child: const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                ),
                                SizedBox(height: 12),
                                Text(
                                  '正在开启拍照模式...',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // 3. 锁定但相机因异常未初始化成功时的提示
                      if (_isScanningLocked && !_isCameraInitialized && !_isCameraLoading)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withOpacity(0.85),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.lock_outline, color: Colors.white, size: 24),
                                const SizedBox(height: 8),
                                Text(
                                  '已锁定单号：$_currentTrackingNumber',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed: _resetCurrentScan,
                                  icon: const Icon(Icons.refresh, color: Colors.white, size: 13),
                                  label: const Text(
                                    '重置重新扫码',
                                    style: TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    side: const BorderSide(color: Colors.white, width: 0.8),
                                    shape: const RoundedRectangleBorder(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 状态消息
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _message!,
                style: const TextStyle(
                  color: _notionGreyText,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),

          // 📸 精致直角 Notion 风格拍照快门大按钮
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              height: 46,
              child: OutlinedButton.icon(
                onPressed: (_isScanningLocked && _isCameraInitialized && !_isProcessing)
                    ? _takeCustomPhotoAndInbound
                    : null,
                icon: const Icon(Icons.camera_alt_outlined, size: 18),
                label: Text(
                  _isProcessing
                      ? '正在处理入库数据...'
                      : (_isScanningLocked ? '📸 拍照并直接入库' : '请对准快递单扫码'),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: (_isScanningLocked && _isCameraInitialized && !_isProcessing)
                      ? Colors.black
                      : Colors.grey.shade100,
                  disabledForegroundColor: Colors.grey.shade400,
                  disabledBackgroundColor: Colors.grey.shade100,
                  side: BorderSide(
                    color: (_isScanningLocked && _isCameraInitialized && !_isProcessing)
                        ? Colors.black
                        : Colors.grey.shade300,
                    width: 1.0,
                  ),
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                ),
              ),
            ),
          ),

          // 扫码锁定时提供重置快捷按钮
          if (_isScanningLocked && _isCameraInitialized && !_isProcessing)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: SizedBox(
                width: double.infinity,
                height: 36,
                child: TextButton.icon(
                  onPressed: _resetCurrentScan,
                  icon: const Icon(Icons.refresh, color: Colors.red, size: 14),
                  label: const Text(
                    '放弃当前单，重置重新扫码',
                    style: TextStyle(
                      color: Colors.red,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  ),
                ),
              ),
            ),

          // 分隔
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(height: 20, color: _notionBorder),
          ),

          // 2. 最近入库列表标题
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '最近入库',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _notionText,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${_recentReceipts.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    color: _notionGreyText,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // 3. 最近5条入库记录列表
          Expanded(
            child: _recentReceipts.isEmpty
                ? const Center(
                    child: Text(
                      '暂无入库记录',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: _notionGreyText,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _recentReceipts.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: _notionBorder),
                    itemBuilder: (context, index) {
                      final receipt = _recentReceipts[index];
                      return _receiptTile(receipt, isFirst: index == 0);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _receiptTile(InboundReceipt receipt, {bool isFirst = false}) {
    final timeStr = DateFormat('MM-dd HH:mm').format(receipt.createdAt);
    final ocrLabel = switch (receipt.ocrStatus) {
      OcrStatus.pending => '识别中',
      OcrStatus.processing => '处理中',
      OcrStatus.needsReview => '待审核',
      OcrStatus.confirmed => '已识别',
      OcrStatus.failed => '识别失败',
    };
    final ocrColor = switch (receipt.ocrStatus) {
      OcrStatus.pending => const Color(0xFFFF9800),
      OcrStatus.processing => const Color(0xFFFF9800),
      OcrStatus.needsReview => const Color(0xFF2196F3),
      OcrStatus.confirmed => const Color(0xFF4CAF50),
      OcrStatus.failed => const Color(0xFFE53935),
    };

    final hasImage = receipt.imagePath != null && receipt.imagePath!.isNotEmpty;

    return GestureDetector(
      onTap: hasImage ? () => _showReceiptImage(receipt.imagePath!) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: isFirst ? const Color(0xFFE8F5E9) : null,
          border: isFirst
              ? const Border(left: BorderSide(color: Color(0xFF4CAF50), width: 2.5))
              : null,
        ),
        child: Padding(
          padding: EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 快递单号
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      receipt.trackingNumber,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        fontWeight: isFirst ? FontWeight.bold : FontWeight.w500,
                        color: _notionText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: _notionGreyText,
                      ),
                    ),
                  ],
                ),
              ),
              // OCR 状态
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: ocrColor.withOpacity(0.1),
                  border: Border.all(color: ocrColor.withOpacity(0.4), width: 0.8),
                ),
                child: Text(
                  ocrLabel,
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: ocrColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 结算状态
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: receipt.isSettled
                      ? const Color(0xFFDCF5DC)
                      : const Color(0xFFFDE8E8),
                  border: Border.all(
                    color: receipt.isSettled
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFFE53935),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  receipt.isSettled ? '已结' : '未结',
                  style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    color: receipt.isSettled
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFC62828),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
