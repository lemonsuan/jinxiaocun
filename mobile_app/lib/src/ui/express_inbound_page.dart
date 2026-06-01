import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../data/local_inventory_database.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/paddle_ocr_channel.dart';
import 'custom_camera_page.dart';

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

  List<InboundReceipt> _recentReceipts = [];
  String? _currentTrackingNumber;
  bool _isScanningLocked = false;
  bool _isProcessing = false;
  String? _message = '扫码器已就绪，请对准快递单条码';

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
      await _loadRecentReceipts();
    } catch (_) {
      // 降级标记为识别失败
      await widget.database.updateInboundOcrResult(
        receiptId: receiptId,
        items: const [],
        ocrStatus: OcrStatus.failed,
      );
      widget.onRefreshHomeData();
      await _loadRecentReceipts();
    }
  }

  // 物理重置锁定状态
  Future<void> _resetCurrentScan() async {
    setState(() {
      _currentTrackingNumber = null;
      _isScanningLocked = false;
      _isProcessing = false;
      _message = '已重置扫码状态，扫码器已就绪';
    });
    try {
      await _controller.start();
    } catch (e) {
      debugPrint('扫码器重置启动失败: $e');
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
              title: const Text('商品清单原图预览', style: TextStyle(fontSize: 14)),
              elevation: 0,
            ),
            body: Center(
              child: InteractiveViewer(
                maxScale: 4.0,
                child: Image.file(file),
              ),
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
          '扫码入库 (极速模式)',
          style: TextStyle(
            fontWeight: FontWeight.w400,
            fontSize: 15,
            letterSpacing: 1.0,
            color: _notionText,
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: _notionText,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // 头部说明指示区
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFFF7F7F5),
                border: Border.all(color: _notionBorder, width: 0.8),
              ),
              padding: const EdgeInsets.all(12),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚡ 极速连续对账流水线说明：',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _notionText,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '1. 对准快递单条码扫码，系统自动识别单号并锁定。\n'
                    '2. 锁死后自动跳转全屏内置相机，自动裁剪取景框内照片。\n'
                    '3. 拍照完毕自动后台建立单据，并在 1 秒内重启扫码，直接扫描下一个。',
                    style: TextStyle(
                      fontSize: 11,
                      color: _notionGreyText,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 扫码取景框 (高 240)
          Container(
            height: 240,
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.black, width: 1.2),
              color: Colors.black,
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: MobileScanner(
                    controller: _controller,
                    onDetect: (capture) async {
                      if (_isScanningLocked || _isProcessing) return;
                      final barcodes = capture.barcodes;
                      for (final barcode in barcodes) {
                        final raw = barcode.rawValue;
                        if (raw != null && raw.isNotEmpty) {
                          setState(() {
                            _currentTrackingNumber = raw;
                            _isScanningLocked = true;
                            _message = '已识别单号：$raw，正在拉起拍照...';
                          });

                          // 立即暂停扫码器，腾出摄像头控制权给新相机页面
                          await _controller.stop();

                          if (!mounted) return;
                          // 跳转到统一的 CustomCameraPage 拍照识别，享受取景框物理图像裁剪
                          final image = await Navigator.of(context).push<XFile>(
                            MaterialPageRoute(
                              builder: (context) => const CustomCameraPage(title: '极速模式拍照识别'),
                            ),
                          );

                          if (image == null) {
                            // 用户中途取消了拍摄，重置状态
                            if (mounted) {
                              setState(() {
                                _isScanningLocked = false;
                                _currentTrackingNumber = null;
                                _message = '已取消拍照，扫码已重启';
                              });
                            }
                            // 给相机硬件转场释放留出足够物理缓冲时间
                            await Future.delayed(const Duration(milliseconds: 500));
                            await _controller.start();
                            break;
                          }

                          // 拍照成功，进入入库处理与后台异步大模型流程
                          if (mounted) {
                            setState(() {
                              _isProcessing = true;
                              _message = '正在保存图片并记录入库...';
                            });
                          }

                          try {
                            final storedImagePath = await _storeInboundImage(image);

                            // 本地快速创建待处理单据
                            final receipt = await widget.database.confirmInbound(
                              trackingNumber: raw,
                              items: const [],
                              imagePath: storedImagePath,
                              ocrStatus: OcrStatus.pending,
                            );

                            // 后台开启异步大模型提取，完全不阻塞当前扫码流水线
                            unawaited(_runAsyncOcr(receipt.id, storedImagePath));

                            // 加载最近入库列表
                            await _loadRecentReceipts();
                            widget.onRefreshHomeData();

                            if (mounted) {
                              setState(() {
                                _message = '快递 $raw 已录入，后台正在分析明细';
                                _currentTrackingNumber = null;
                                _isScanningLocked = false;
                                _isProcessing = false;
                              });
                            }
                          } catch (e) {
                            if (mounted) {
                              setState(() {
                                _message = '入库记录失败: $e';
                                _currentTrackingNumber = null;
                                _isScanningLocked = false;
                                _isProcessing = false;
                              });
                            }
                          }

                          // 等待页面滑出转场完全结束，相机硬件彻底释放后，再重启扫码
                          await Future.delayed(const Duration(milliseconds: 500));
                          await _controller.start();
                          break;
                        }
                      }
                    },
                  ),
                ),
                // 仅在扫码锁定状态下，在顶部覆上一层黑色的锁定遮罩，不销毁扫码器本身
                if (_isScanningLocked)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withOpacity(0.9),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                          const SizedBox(height: 16),
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
                          const SizedBox(height: 6),
                          const Text(
                            '正在跳转到相机页面...',
                            style: TextStyle(
                              color: _notionGreyText,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // 提示消息栏
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                _message!,
                style: const TextStyle(
                  color: _notionText,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),

          // 物理重置按钮（仅在发生不可控阻塞或异常锁定时供人工救急）
          if (_isScanningLocked)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton.icon(
                onPressed: _resetCurrentScan,
                icon: const Icon(Icons.refresh, color: Colors.red, size: 13),
                label: const Text(
                  '放弃当前锁定并重置扫码',
                  style: TextStyle(
                    color: Colors.red,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
              ),
            ),

          // 分隔线
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(height: 10, color: _notionBorder),
          ),

          // 最近入库列表标题
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const Text(
                  '最近入库记录',
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
                    fontSize: 11,
                    color: _notionGreyText,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // 最近 5 条入库列表
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
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
    );
  }
}
