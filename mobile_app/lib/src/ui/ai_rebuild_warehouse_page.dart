import 'dart:io';
import 'package:flutter/material.dart';
import '../data/local_inventory_database.dart';
import '../domain/models.dart';
import '../ocr/ai_inbound_extractor.dart';

class AiRebuildWarehousePage extends StatefulWidget {
  final LocalInventoryDatabase database;
  final AiInboundExtractor? extractor;

  const AiRebuildWarehousePage({
    super.key,
    required this.database,
    this.extractor,
  });

  @override
  State<AiRebuildWarehousePage> createState() => _AiRebuildWarehousePageState();
}

class _AiRebuildWarehousePageState extends State<AiRebuildWarehousePage> {
  late final AiInboundExtractor _aiInboundExtractor =
      widget.extractor ?? AiInboundExtractor(widget.database);

  List<InboundReceipt> _receipts = [];
  bool _isLoading = true;
  bool _remoteAvailable = false;

  // 批量/单体分析状态
  bool _isProcessing = false;
  String? _currentlyProcessingId; // 当前正在分析的单据 ID
  int _currentIndex = 0;
  int _totalCount = 0;
  int _successCount = 0;
  int _failCount = 0;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _loadReceipts();
  }

  Future<void> _loadReceipts() async {
    setState(() => _isLoading = true);
    try {
      final remoteAvailable = await widget.database.loadSyncContext() != null;
      final allReceipts = await widget.database.loadInboundHistory();
      // 仅筛选带物理图片的单据
      final targetReceipts = allReceipts.where((r) {
        if (r.imagePath == null || r.imagePath!.isEmpty) return false;
        return File(r.imagePath!).existsSync();
      }).toList();

      // 按时间倒序排列
      targetReceipts.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (!mounted) return;
      setState(() {
        _remoteAvailable = remoteAvailable;
        _receipts = targetReceipts;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载单据列表失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _canAnalyze() async {
    try {
      await _aiInboundExtractor.ensureRemoteAvailable();
      return mounted;
    } on RemoteAiUnavailable catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
      return false;
    }
  }

  // 运行单个单据的重新分析
  Future<void> _analyzeSingle(InboundReceipt receipt) async {
    if (_isProcessing || !await _canAnalyze()) return;
    if (!mounted) return;

    setState(() {
      _isProcessing = true;
      _currentlyProcessingId = receipt.id;
      _statusMessage =
          '正在分析单据: ${receipt.trackingNumber.isEmpty ? '无单号' : receipt.trackingNumber}...';
    });

    try {
      final result =
          await _aiInboundExtractor.extractFromImage(receipt.imagePath!);
      if (!mounted) return;
      await widget.database.overwriteInboundItems(
        receiptId: receipt.id,
        items: result.items,
        sellerOrderNumber: result.sellerOrderNumber,
        schemeNumber: result.schemeNumber,
        ocrStatus: OcrStatus.confirmed,
      );

      // 局部事务已在内部完成库存冲销与重算，无需全局重算

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该图片重新分析完成，已局部更新对应库存与台账！')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分析失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _currentlyProcessingId = null;
          _statusMessage = '';
        });
        _loadReceipts(); // 重新加载状态
      }
    }
  }

  // 运行批量重整
  Future<void> _runBatch({required bool onlyUnsettled}) async {
    if (_isProcessing || !await _canAnalyze()) return;
    if (!mounted) return;

    final targets = onlyUnsettled
        ? _receipts.where((r) => !r.isSettled).toList()
        : _receipts;

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(onlyUnsettled ? '未找到任何未结算且带图片的单据。' : '没有可分析的单据。')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
      _totalCount = targets.length;
      _currentIndex = 0;
      _successCount = 0;
      _failCount = 0;
      _statusMessage = '准备开始批量分析图片...';
    });

    for (int i = 0; i < targets.length; i++) {
      if (!mounted) break;
      final receipt = targets[i];
      setState(() {
        _currentIndex = i;
        _currentlyProcessingId = receipt.id;
        _statusMessage =
            '正在处理第 ${i + 1}/$_totalCount 张图片...\n快递单号: ${receipt.trackingNumber}';
      });

      try {
        final result =
            await _aiInboundExtractor.extractFromImage(receipt.imagePath!);
        if (!mounted) break;
        await widget.database.overwriteInboundItems(
          receiptId: receipt.id,
          items: result.items,
          sellerOrderNumber: result.sellerOrderNumber,
          schemeNumber: result.schemeNumber,
          ocrStatus: OcrStatus.confirmed,
        );
        if (mounted) {
          setState(() {
            _successCount++;
          });
        }
      } catch (e) {
        if (!mounted) break;
        if (mounted) {
          setState(() {
            _failCount++;
          });
        }
        debugPrint('AI 图片重整单据 ${receipt.id} 异常: $e');
      }
    }

    if (!mounted) return;

    // 局部更新已在循环内完成，直接完成状态提示
    setState(() {
      _currentlyProcessingId = null;
      _statusMessage = '处理完成：成功 $_successCount 笔，失败 $_failCount 笔。失败单据保留原内容。';
    });

    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      setState(() {
        _isProcessing = false;
      });
      _loadReceipts();
    }
  }

  String _getOcrStatusLabel(OcrStatus status) {
    switch (status) {
      case OcrStatus.pending:
        return '待分析';
      case OcrStatus.processing:
        return '分析中';
      case OcrStatus.needsReview:
        return '需审核';
      case OcrStatus.confirmed:
        return '成功';
      case OcrStatus.failed:
        return '失败';
    }
  }

  Color _getOcrStatusColor(OcrStatus status) {
    switch (status) {
      case OcrStatus.confirmed:
        return const Color(0xFF10B981); // 翠绿色
      case OcrStatus.failed:
        return const Color(0xFFEF4444); // 鲜红色
      case OcrStatus.pending:
        return const Color(0xFF64748B); // 灰石色
      case OcrStatus.processing:
        return const Color(0xFF3B82F6); // 蓝色
      case OcrStatus.needsReview:
        return const Color(0xFFF59E0B); // 琥珀色
    }
  }

  void _showReceiptDetailDialog(InboundReceipt receipt) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          title: Text(
            receipt.trackingNumber.isEmpty
                ? '商品明细 (无单号)'
                : '商品明细 (${receipt.trackingNumber})',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: receipt.items.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '该单据暂无识别到的商品明细',
                        style:
                            TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: receipt.items.length,
                    separatorBuilder: (context, index) =>
                        const Divider(color: Color(0xFFF1F5F9), height: 1),
                    itemBuilder: (context, index) {
                      final item = receipt.items[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.productName,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1E293B),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '编码: ${item.productCode ?? '无'}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                Text(
                                  '数量: ${item.quantity}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF1E293B),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF64748B),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭', style: TextStyle(fontSize: 12)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFCFCFC), // 极简偏灰色背景
      appBar: AppBar(
        title: const Text(
          'AI 图片重整库房',
          style: TextStyle(
            fontWeight: FontWeight.w400,
            fontSize: 16,
            letterSpacing: 1.5,
            color: Color(0xFF1E293B),
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: const Color(0xFF1E293B),
        centerTitle: true,
      ),
      body: Column(
        children: [
          if (!_isLoading && !_remoteAvailable)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  '完全本地模式不连接服务器，云端 AI 图片重整不可用。请返回入库页面使用本机 OCR；原单据与库存保持不变。'),
            ),
          // 1. 顶部进度/状态展示看板 (仅在处理中或刚处理完时显示)
          if (_isProcessing || _statusMessage.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xFFE2E8F0), width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _isProcessing ? '图片分析处理中...' : '处理完毕',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                      if (_isProcessing && _totalCount > 0)
                        Text(
                          '${_currentIndex + 1}/$_totalCount',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF64748B),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isProcessing && _totalCount > 0) ...[
                    LinearProgressIndicator(
                      value: _currentIndex / _totalCount,
                      backgroundColor: const Color(0xFFF1F5F9),
                      color: const Color(0xFF1E293B),
                      minHeight: 3,
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    _statusMessage,
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                  if (_totalCount > 0) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          '成功: $_successCount',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF10B981)),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          '失败: $_failCount',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFFEF4444)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),

          // 2. 主列表区域
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF1E293B),
                    ),
                  )
                : _receipts.isEmpty
                    ? const Center(
                        child: Text(
                          '未找到任何带照片的入库单单据。',
                          style:
                              TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: _receipts.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final receipt = _receipts[index];
                          final isItemProcessing =
                              _currentlyProcessingId == receipt.id;

                          return GestureDetector(
                            onTap: () => _showReceiptDetailDialog(receipt),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(
                                  color: isItemProcessing
                                      ? const Color(0xFF1E293B)
                                      : const Color(0xFFE2E8F0),
                                  width: isItemProcessing ? 1.2 : 0.8,
                                ),
                              ),
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  // 缩略图
                                  Container(
                                    width: 60,
                                    height: 60,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF8FAFC),
                                      border: Border.all(
                                          color: const Color(0xFFE2E8F0),
                                          width: 0.5),
                                    ),
                                    child: Image.file(
                                      File(receipt.imagePath!),
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                        return const Center(
                                          child: Icon(
                                              Icons.broken_image_outlined,
                                              size: 20,
                                              color: Color(0xFF94A3B8)),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // 单据信息
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          receipt.trackingNumber.isEmpty
                                              ? '无快递单号 (单号由系统自动生成)'
                                              : receipt.trackingNumber,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color:
                                                receipt.trackingNumber.isEmpty
                                                    ? const Color(0xFF94A3B8)
                                                    : const Color(0xFF1E293B),
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            // 结算状态
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2),
                                              color: receipt.isSettled
                                                  ? const Color(0xFFF1F5F9)
                                                  : const Color(0xFFEFF6FF),
                                              child: Text(
                                                receipt.isSettled
                                                    ? '已结算'
                                                    : '未结算',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w500,
                                                  color: receipt.isSettled
                                                      ? const Color(0xFF64748B)
                                                      : const Color(0xFF2563EB),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            // OCR 状态
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2),
                                              color: _getOcrStatusColor(
                                                      receipt.ocrStatus)
                                                  .withAlpha(25),
                                              child: Text(
                                                _getOcrStatusLabel(
                                                    receipt.ocrStatus),
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w600,
                                                  color: _getOcrStatusColor(
                                                      receipt.ocrStatus),
                                                ),
                                              ),
                                            ),
                                            // 是否已压缩图片
                                            if (receipt.imagePath != null &&
                                                receipt.imagePath!.contains(
                                                    '_compressed')) ...[
                                              const SizedBox(width: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2),
                                                color: const Color(0xFFF1F5F9),
                                                child: const Text(
                                                  '已压缩',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w500,
                                                    color: Color(0xFF475569),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // 独立分析按钮
                                  SizedBox(
                                    height: 32,
                                    child: isItemProcessing
                                        ? const Padding(
                                            padding: EdgeInsets.symmetric(
                                                horizontal: 16),
                                            child: SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.5,
                                                color: Color(0xFF1E293B),
                                              ),
                                            ),
                                          )
                                        : OutlinedButton(
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor:
                                                  const Color(0xFF1E293B),
                                              side: const BorderSide(
                                                  color: Color(0xFFE2E8F0),
                                                  width: 0.8),
                                              shape:
                                                  const RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.zero),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10),
                                            ),
                                            onPressed: _isProcessing ||
                                                    !_remoteAvailable
                                                ? null
                                                : () => _analyzeSingle(receipt),
                                            child: const Text('重新分析',
                                                style: TextStyle(fontSize: 11)),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),

          // 3. 底栏操作按钮
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(color: Color(0xFFF1F5F9), width: 0.8),
              ),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1E293B),
                          side: const BorderSide(
                              color: Color(0xFFE2E8F0), width: 0.8),
                          shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.zero),
                        ),
                        onPressed: _isProcessing || !_remoteAvailable
                            ? null
                            : () => _runBatch(onlyUnsettled: true),
                        child: const Text(
                          '只分析未结算部分',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1E293B),
                          foregroundColor: Colors.white,
                          shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.zero),
                          elevation: 0,
                        ),
                        onPressed: _isProcessing || !_remoteAvailable
                            ? null
                            : () => _runBatch(onlyUnsettled: false),
                        child: const Text(
                          '全部分析',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
