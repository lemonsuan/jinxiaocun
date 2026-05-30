import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
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

  final ImagePicker _imagePicker = ImagePicker();

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
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
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

  // 自动调起拍照并执行异步默认入库
  Future<void> _captureAndInbound() async {
    if (_currentTrackingNumber == null) return;

    setState(() {
      _isProcessing = true;
      _message = '扫码成功，正在为您自动调起相机...';
    });

    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      
      // 用户取消了拍摄
      if (image == null) {
        setState(() {
          _isProcessing = false;
          _currentTrackingNumber = null;
          _isScanningLocked = false;
          _message = '拍照取消，扫码器已重新激活';
        });
        return;
      }

      setState(() {
        _message = '正在保存图片并生成待处理入库单...';
      });

      // 1. 克隆图片到内部沙盒目录
      final storedImagePath = await _storeInboundImage(image);
      await _ensureVerticalImage(storedImagePath);

      // 2. 本地数据库以 pending 模式创建待处理单据（商品明细初始化为空）
      final receipt = await widget.database.confirmInbound(
        trackingNumber: _currentTrackingNumber!,
        items: const [],
        imagePath: storedImagePath,
        ocrStatus: OcrStatus.pending,
      );

      // 3. 异步非阻塞启动 PaddleOCR 商品结构化信息提取
      unawaited(_runAsyncOcr(receipt.id, storedImagePath));

      // 4. 重置状态 & 刷新列表
      final savedNum = _currentTrackingNumber!;
      setState(() {
        _message = '快递 $savedNum 入库成功，正在提取明细';
        _currentTrackingNumber = null;
        _isScanningLocked = false;
        _isProcessing = false;
      });

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

      // 如果宽度大于高度，则是横屏图，强制顺时针旋转90度
      if (width > height) {
        final double angle = 90 * 3.141592653589793 / 180;
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
                  height: 200,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 1.2),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: MobileScanner(
                          controller: _controller,
                          onDetect: (capture) {
                            if (_isScanningLocked || _isProcessing) return;
                            final barcodes = capture.barcodes;
                            for (final barcode in barcodes) {
                              final raw = barcode.rawValue;
                              if (raw != null && raw.isNotEmpty) {
                                setState(() {
                                  _currentTrackingNumber = raw;
                                  _isScanningLocked = true;
                                  _message = '扫码成功，正在为您唤起相机...';
                                });
                                _captureAndInbound();
                                break;
                              }
                            }
                          },
                        ),
                      ),
                      // 取景遮罩与锁定提示
                      if (_isScanningLocked)
                        Positioned.fill(
                          child: Container(
                            color: Colors.black.withOpacity(0.65),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.lock_outline, color: Colors.white, size: 24),
                                const SizedBox(height: 8),
                                Text(
                                  '已锁定：${_currentTrackingNumber ?? ''}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed: _resetCurrentScan,
                                  icon: const Icon(Icons.refresh, color: Colors.white, size: 14),
                                  label: const Text(
                                    '重置',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    side: const BorderSide(color: Colors.white, width: 0.8),
                                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
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

          // 分隔
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(height: 24, color: _notionBorder),
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
