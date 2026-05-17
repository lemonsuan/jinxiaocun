import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../application/inventory_service.dart';
import '../data/local_inventory_database.dart';
import '../domain/models.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/paddle_ocr_channel.dart';
import 'scanner_page.dart';

enum _BackupAction { exportData, importData }

enum _HistorySettlementFilter { all, settled, unsettled }

class _OutboundCartEntry {
  const _OutboundCartEntry({
    required this.productCode,
    required this.productName,
    required this.quantity,
  });

  final String productCode;
  final String productName;
  final int quantity;

  _OutboundCartEntry copyWith({int? quantity}) {
    return _OutboundCartEntry(
      productCode: productCode,
      productName: productName,
      quantity: quantity ?? this.quantity,
    );
  }
}

class AppHome extends StatefulWidget {
  const AppHome({super.key});

  @override
  State<AppHome> createState() => _AppHomeState();
}

class _AppHomeState extends State<AppHome> {
  final LocalInventoryDatabase _database = LocalInventoryDatabase();
  final PpStructurePostProcessor _postProcessor = PpStructurePostProcessor();
  final PaddleOcrChannel _paddleOcr = PaddleOcrChannel();
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _trackingController = TextEditingController();
  final TextEditingController _historySearchController =
      TextEditingController();
  final TextEditingController _ocrTextController = TextEditingController();
  final List<InboundDraftItem> _draftItems = [];
  final List<_OutboundCartEntry> _outboundCart = [];
  final List<String> _outboundImagePaths = [];
  List<WarehouseStock> _stockTotals = const [];
  List<InboundReceipt> _inboundHistory = const [];
  List<OutboundOrder> _outboundHistory = const [];
  String? _currentInboundImagePath;
  String? _message;
  bool _isSettled = false;
  bool _isReady = false;
  bool _isBackupBusy = false;
  int _selectedTabIndex = 0;
  _HistorySettlementFilter _historySettlementFilter =
      _HistorySettlementFilter.all;

  @override
  void initState() {
    super.initState();
    _openDatabase();
  }

  @override
  void dispose() {
    _trackingController.dispose();
    _historySearchController.dispose();
    _ocrTextController.dispose();
    unawaited(_database.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('云推推库存管理'),
        actions: [
          PopupMenuButton<_BackupAction>(
            enabled: _isReady && !_isBackupBusy,
            icon: const Icon(Icons.more_vert),
            onSelected: _onBackupActionSelected,
            itemBuilder: (context) {
              return const [
                PopupMenuItem(
                  value: _BackupAction.exportData,
                  child: Row(
                    children: [
                      Icon(Icons.upload_file_outlined),
                      SizedBox(width: 8),
                      Text('导出备份'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: _BackupAction.importData,
                  child: Row(
                    children: [
                      Icon(Icons.download_for_offline_outlined),
                      SizedBox(width: 8),
                      Text('导入备份'),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: !_isReady
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _selectedTabIndex,
              children: [
                _scanInboundTab(),
                _historyInboundTab(),
                _stockTotalsTab(),
                _historyOutboundTab(),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.qr_code_scanner),
            label: '扫码入库',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: '历史入库',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            label: '商品总量',
          ),
          NavigationDestination(
            icon: Icon(Icons.local_shipping_outlined),
            label: '历史出库',
          ),
        ],
      ),
    );
  }

  Widget _page(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ...children,
        if (_message != null) ...[
          const SizedBox(height: 16),
          Text(
            _message!,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ],
    );
  }

  Widget _scanInboundTab() {
    return _page([
      _scanInboundHeader(),
      _trackingRow(),
      const SizedBox(height: 12),
      TextField(
        controller: _ocrTextController,
        minLines: 3,
        maxLines: 6,
        decoration: const InputDecoration(
          labelText: '商品清单识别文本',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _captureAndRecognizeList,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('拍照识别'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              onPressed: _pickAndRecognizeList,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('相册识别'),
            ),
          ),
        ],
      ),
      if (_currentInboundImagePath != null) ...[
        const SizedBox(height: 8),
        _inboundImageTile(_currentInboundImagePath!),
      ],
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: _parseOcrText,
        icon: const Icon(Icons.document_scanner_outlined),
        label: const Text('从文本重新生成'),
      ),
      for (var index = 0; index < _draftItems.length; index += 1)
        _draftTile(index, _draftItems[index]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _isSettled,
        onChanged: (value) {
          setState(() {
            _isSettled = value;
          });
        },
        title: const Text('本单已结算'),
      ),
      FilledButton.icon(
        onPressed: _confirmInbound,
        icon: const Icon(Icons.archive_outlined),
        label: const Text('确认入库'),
      ),
    ]);
  }

  Widget _historyInboundTab() {
    final receipts = _filteredInboundHistory();
    return _page([
      _sectionTitle('历史入库'),
      TextField(
        controller: _historySearchController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: '搜索订单号或快递号',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: _historySearchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  onPressed: () {
                    setState(() {
                      _historySearchController.clear();
                    });
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
      ),
      const SizedBox(height: 8),
      _historySettlementFilterControl(),
      const SizedBox(height: 8),
      if (_inboundHistory.isEmpty)
        const ListTile(title: Text('暂无入库记录'))
      else if (receipts.isEmpty)
        const ListTile(title: Text('没有匹配的入库记录')),
      ...receipts.map(_receiptTile),
    ]);
  }

  Widget _stockTotalsTab() {
    return _page([
      _sectionTitle('商品总量'),
      _outboundCartPanel(),
      const Divider(height: 32),
      if (_stockTotals.isEmpty) const ListTile(title: Text('暂无库存')),
      ..._stockTotals.map(_stockTile),
    ]);
  }

  Widget _historyOutboundTab() {
    return _page([
      _sectionTitle('历史出库'),
      if (_outboundHistory.isEmpty) const ListTile(title: Text('暂无出货记录')),
      ..._outboundHistory.map(_outboundTile),
    ]);
  }

  Widget _sectionTitle(String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(value, style: Theme.of(context).textTheme.titleLarge),
    );
  }

  Widget _scanInboundHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '扫码入库',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          OutlinedButton.icon(
            onPressed: _clearCurrentInboundDraft,
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('清空当前单'),
          ),
        ],
      ),
    );
  }

  Widget _trackingRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _trackingController,
            decoration: const InputDecoration(
              labelText: '快递单号',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          tooltip: '扫码',
          onPressed: _scanTrackingNumber,
          icon: const Icon(Icons.qr_code_scanner),
        ),
      ],
    );
  }

  Widget _historySettlementFilterControl() {
    return SegmentedButton<_HistorySettlementFilter>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: _HistorySettlementFilter.all,
          label: Text('全部'),
        ),
        ButtonSegment(
          value: _HistorySettlementFilter.settled,
          label: Text('已结算'),
        ),
        ButtonSegment(
          value: _HistorySettlementFilter.unsettled,
          label: Text('未结算'),
        ),
      ],
      selected: {_historySettlementFilter},
      onSelectionChanged: (selected) {
        setState(() {
          _historySettlementFilter = selected.single;
        });
      },
    );
  }

  Widget _draftTile(int index, InboundDraftItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('draft-code-$index-${item.sourceText}'),
                  initialValue: item.productCode ?? '',
                  onChanged: (value) {
                    if (index >= _draftItems.length) {
                      return;
                    }
                    final current = _draftItems[index];
                    _replaceDraftItem(
                      index,
                      current.copyWith(productCode: value),
                    );
                  },
                  decoration: const InputDecoration(
                    labelText: '商品编号',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: TextFormField(
                  key: ValueKey('draft-qty-$index-${item.sourceText}'),
                  initialValue: item.quantity.toString(),
                  keyboardType: TextInputType.number,
                  onChanged: (value) {
                    if (index >= _draftItems.length) {
                      return;
                    }
                    final current = _draftItems[index];
                    _replaceDraftItem(
                      index,
                      current.copyWith(
                        quantity: int.tryParse(value.trim()) ?? 0,
                      ),
                    );
                  },
                  decoration: const InputDecoration(
                    labelText: '数量',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton(
                tooltip: '删除商品草稿',
                onPressed: () => _removeDraftItem(index),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            key: ValueKey('draft-name-$index-${item.sourceText}'),
            initialValue: item.productName,
            onChanged: (value) {
              if (index >= _draftItems.length) {
                return;
              }
              final current = _draftItems[index];
              _replaceDraftItem(index, current.copyWith(productName: value));
            },
            decoration: const InputDecoration(
              labelText: '商品名称',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stockTile(WarehouseStock stock) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(stock.productName),
      subtitle: Text(stock.productCode),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${stock.quantity}'),
          IconButton(
            tooltip: '加入出库车',
            onPressed: stock.quantity <= 0
                ? null
                : () => _addStockToOutboundCart(stock),
            icon: const Icon(Icons.add_shopping_cart_outlined),
          ),
        ],
      ),
    );
  }

  Widget _receiptTile(InboundReceipt receipt) {
    final primaryStyle = Theme.of(context).textTheme.bodyLarge;
    final secondaryStyle = Theme.of(context).textTheme.bodyMedium;
    final imagePreview = _receiptImagePreview(receipt.imagePath);
    return InkWell(
      onLongPress: () => _confirmDeleteInboundReceipt(receipt),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('快递单号：${receipt.trackingNumber}',
                          style: primaryStyle),
                      Text('订单号：${receipt.id}', style: primaryStyle),
                      Text(
                        '入库时间：${_formatReceiptTime(receipt.createdAt)}',
                        style: secondaryStyle,
                      ),
                      Text(
                        '${receipt.items.length} 个商品 · ${receipt.isSettled ? '已结算' : '未结算'}',
                        style: secondaryStyle,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: receipt.isSettled,
                  onChanged: (selected) =>
                      _setReceiptSettled(receipt.id, selected),
                ),
              ],
            ),
            if (receipt.items.isNotEmpty) ...[
              const SizedBox(height: 6),
              ...receipt.items.map(_inboundReceiptItemLine),
            ],
            if (imagePreview != null) ...[
              const SizedBox(height: 8),
              imagePreview,
            ],
          ],
        ),
      ),
    );
  }

  Widget _inboundReceiptItemLine(InboundDraftItem item) {
    final code = item.productCode == null || item.productCode!.trim().isEmpty
        ? ''
        : '${item.productCode} · ';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text('$code${item.productName} x${item.quantity}'),
    );
  }

  String _formatReceiptTime(DateTime value) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '${value.year}年${twoDigits(value.month)}月${twoDigits(value.day)}日 '
        '${twoDigits(value.hour)}时${twoDigits(value.minute)}分';
  }

  Widget _inboundImageTile(String imagePath) {
    final file = File(imagePath);
    final exists = file.existsSync();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _imageThumbnail(file),
      title: const Text('已保存商品清单图片'),
      subtitle: Text(exists ? p.basename(imagePath) : '图片文件不存在'),
      trailing: exists ? const Icon(Icons.visibility_outlined) : null,
      onTap: exists ? () => _showReceiptImage(imagePath) : null,
    );
  }

  Widget? _receiptImagePreview(String? imagePath) {
    if (imagePath == null || imagePath.isEmpty) {
      return null;
    }
    final file = File(imagePath);
    final exists = file.existsSync();
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: exists ? () => _showReceiptImage(imagePath) : null,
      child: _imageThumbnail(file),
    );
  }

  Widget _imageThumbnail(File file) {
    if (!file.existsSync()) {
      return const SizedBox(
        width: 56,
        height: 56,
        child: Icon(Icons.broken_image_outlined),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        file,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
      ),
    );
  }

  void _showReceiptImage(String imagePath) {
    final file = File(imagePath);
    if (!file.existsSync()) {
      setState(() {
        _message = '图片文件不存在：${p.basename(imagePath)}';
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
              title: Text(p.basename(imagePath)),
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

  Widget _outboundTile(OutboundOrder order) {
    final quantity =
        order.items.fold<int>(0, (sum, item) => sum + item.quantity);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(order.id, style: Theme.of(context).textTheme.bodyLarge),
          Text(
            '出库时间：${_formatReceiptTime(order.createdAt)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            '${order.items.length} 个商品 · 共 $quantity 件',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          ...order.items.map(_outboundOrderItemLine),
          if (order.imagePaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            _imagePathWrap(order.imagePaths),
          ],
        ],
      ),
    );
  }

  Widget _outboundOrderItemLine(OutboundItem item) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child:
          Text('${item.productCode} · ${item.productName} x${item.quantity}'),
    );
  }

  Widget _outboundCartPanel() {
    final totalQuantity =
        _outboundCart.fold<int>(0, (sum, item) => sum + item.quantity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '出库购物车',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_outboundCart.isNotEmpty || _outboundImagePaths.isNotEmpty)
              TextButton.icon(
                onPressed: () => _clearOutboundCart(),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清空'),
              ),
          ],
        ),
        if (_outboundCart.isEmpty)
          const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('从下方库存商品加入出库车'),
          )
        else ...[
          ..._outboundCart.map(_outboundCartTile),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('合计出库 $totalQuantity 件'),
          ),
        ],
        if (_outboundImagePaths.isNotEmpty) ...[
          const SizedBox(height: 8),
          _imagePathWrap(_outboundImagePaths, editable: true),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _captureOutboundImage,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('拍出库照片'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    _outboundCart.isEmpty ? null : _confirmOutboundFromCart,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('生成出库单'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _outboundCartTile(_OutboundCartEntry entry) {
    final available = _stockQuantityFor(entry.productCode);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.productName),
                    Text(
                      '${entry.productCode} · 库存 $available',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '移出出库车',
                onPressed: () => _removeOutboundCartItem(entry.productCode),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: '减少数量',
                onPressed: entry.quantity <= 1
                    ? null
                    : () => _setOutboundCartQuantity(
                          entry.productCode,
                          entry.quantity - 1,
                        ),
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 56,
                child: Center(child: Text('${entry.quantity}')),
              ),
              IconButton.filledTonal(
                tooltip: '增加数量',
                onPressed: entry.quantity >= available
                    ? null
                    : () => _setOutboundCartQuantity(
                          entry.productCode,
                          entry.quantity + 1,
                        ),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _imagePathWrap(List<String> imagePaths, {bool editable = false}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final imagePath in imagePaths)
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              children: [
                Positioned.fill(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _showReceiptImage(imagePath),
                    child: _imageThumbnail(File(imagePath)),
                  ),
                ),
                if (editable)
                  Align(
                    alignment: Alignment.topRight,
                    child: IconButton.filledTonal(
                      tooltip: '移除照片',
                      onPressed: () => _removeOutboundImage(imagePath),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _scanTrackingNumber() async {
    try {
      final value = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ScannerPage()),
      );
      if (value == null || value.isEmpty) {
        return;
      }
      setState(() {
        _trackingController.text = value;
      });
    } on Object catch (error) {
      setState(() {
        _message = '扫码不可用：$error';
      });
    }
  }

  Future<void> _onBackupActionSelected(_BackupAction action) async {
    switch (action) {
      case _BackupAction.exportData:
        await _exportBackup();
        return;
      case _BackupAction.importData:
        await _confirmAndImportBackup();
        return;
    }
  }

  Future<void> _exportBackup() async {
    if (_isBackupBusy) {
      return;
    }
    setState(() {
      _isBackupBusy = true;
      _message = '正在生成备份';
    });
    try {
      final bytes = await _database.exportBackupBytes();
      final savedPath = await FilePicker.saveFile(
        dialogTitle: '导出库存备份',
        fileName: _backupFileName(),
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _message = savedPath == null ? '已取消导出' : '备份已导出';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '导出失败：$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBackupBusy = false;
        });
      }
    }
  }

  Future<void> _confirmAndImportBackup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('导入备份'),
          content: const Text('导入会覆盖本机当前库存、入库、出货记录和图片关联。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _importBackup();
  }

  Future<void> _importBackup() async {
    if (_isBackupBusy) {
      return;
    }
    setState(() {
      _isBackupBusy = true;
      _message = '请选择备份文件';
    });
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择库存备份文件',
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        if (!mounted) {
          return;
        }
        setState(() {
          _message = '已取消导入';
        });
        return;
      }
      final file = result.files.single;
      final bytes = file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) {
        throw InventoryException('Backup file cannot be read.');
      }
      await _database.importBackupBytes(bytes);
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '备份已导入';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '导入失败：$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBackupBusy = false;
        });
      }
    }
  }

  String _backupFileName() {
    final now = DateTime.now();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return 'inventory_backup_'
        '${now.year}${twoDigits(now.month)}${twoDigits(now.day)}_'
        '${twoDigits(now.hour)}${twoDigits(now.minute)}${twoDigits(now.second)}'
        '.json';
  }

  List<InboundReceipt> _filteredInboundHistory() {
    final keyword = _historySearchController.text.trim().toLowerCase();
    return _inboundHistory.where((receipt) {
      final matchesKeyword = keyword.isEmpty ||
          receipt.id.toLowerCase().contains(keyword) ||
          receipt.trackingNumber.toLowerCase().contains(keyword);
      final matchesSettlement = switch (_historySettlementFilter) {
        _HistorySettlementFilter.all => true,
        _HistorySettlementFilter.settled => receipt.isSettled,
        _HistorySettlementFilter.unsettled => !receipt.isSettled,
      };
      return matchesKeyword && matchesSettlement;
    }).toList(growable: false);
  }

  Future<void> _captureAndRecognizeList() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) {
        return;
      }
      await _processImage(image);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '拍照识别失败：$error';
      });
    }
  }

  Future<void> _pickAndRecognizeList() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) {
        return;
      }
      await _processImage(image);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '相册选图识别失败：$error';
      });
    }
  }

  Future<void> _processImage(XFile image) async {
    try {
      final storedImagePath = await _storeInboundImage(image);
      if (!mounted) {
        return;
      }
      setState(() {
        _currentInboundImagePath = storedImagePath;
        _message = '已保存商品清单图片，正在识别';
      });
      final recognition = await _paddleOcr.recognizeTable(storedImagePath);
      final rows = recognition.rows;
      final editableText = recognition.editableText;

      var items = _postProcessor.processRows(rows);
      if (items.isEmpty && editableText.isNotEmpty) {
        items = _postProcessor.processPlainText(editableText);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _ocrTextController.text = editableText;
        _draftItems
          ..clear()
          ..addAll(items);
        if (items.isNotEmpty) {
          _message = '已识别 ${items.length} 条商品草稿，图片已保存';
        } else if (editableText.isNotEmpty) {
          _message = '已识别文字但未生成商品草稿，可编辑文本后点从文本重新生成';
        } else {
          _message = '未识别到文字，图片已保存，有顺丰单号也可先确认入库';
        }
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '商品清单识别处理失败：$error';
      });
    }
  }

  Future<String> _storeInboundImage(XFile image) async {
    final directory = await getApplicationDocumentsDirectory();
    final imageDirectory = Directory(p.join(directory.path, 'inbound_images'));
    await imageDirectory.create(recursive: true);
    final extension = p.extension(image.path).isEmpty
        ? '.jpg'
        : p.extension(image.path).toLowerCase();
    final filename = '${DateTime.now().microsecondsSinceEpoch}$extension';
    final storedFile = await File(image.path).copy(
      p.join(imageDirectory.path, filename),
    );
    return storedFile.path;
  }

  Future<void> _openDatabase() async {
    try {
      await _database.open();
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _isReady = true;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '数据库初始化失败：$error';
      });
    }
  }

  Future<void> _refreshData() async {
    final stockTotals = await _database.loadStockTotals();
    final inboundHistory = await _database.loadInboundHistory();
    final outboundHistory = await _database.loadOutboundHistory();
    if (!mounted) {
      return;
    }
    setState(() {
      _stockTotals = stockTotals;
      _inboundHistory = inboundHistory;
      _outboundHistory = outboundHistory;
    });
  }

  void _parseOcrText() {
    final items = _postProcessor.processPlainText(_ocrTextController.text);
    setState(() {
      _draftItems
        ..clear()
        ..addAll(items);
      _message = items.isEmpty
          ? '未生成商品草稿，有顺丰单号也可先确认入库'
          : '已重新生成 ${items.length} 条商品草稿';
    });
  }

  void _replaceDraftItem(int index, InboundDraftItem item) {
    if (index < 0 || index >= _draftItems.length) {
      return;
    }
    _draftItems[index] = item;
  }

  void _removeDraftItem(int index) {
    if (index < 0 || index >= _draftItems.length) {
      return;
    }
    setState(() {
      _draftItems.removeAt(index);
      _message = '已删除 1 条商品草稿';
    });
  }

  Future<void> _clearCurrentInboundDraft() async {
    final imagePath = _currentInboundImagePath;
    _trackingController.clear();
    _ocrTextController.clear();
    _draftItems.clear();
    setState(() {
      _currentInboundImagePath = null;
      _isSettled = false;
      _message = '已清空当前单';
    });
    await _deleteStoredImage(imagePath);
  }

  Future<void> _confirmInbound() async {
    try {
      final receipt = await _database.confirmInbound(
        trackingNumber: _trackingController.text,
        items: _draftItems,
        imagePath: _currentInboundImagePath,
        isSettled: _isSettled,
      );
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _trackingController.clear();
        _ocrTextController.clear();
        _draftItems.clear();
        _currentInboundImagePath = null;
        _isSettled = false;
        _message = '入库成功：${receipt.trackingNumber}';
      });
    } on InventoryException catch (error) {
      setState(() {
        _message = error.message;
      });
    }
  }

  Future<void> _setReceiptSettled(String receiptId, bool isSettled) async {
    try {
      await _database.setReceiptSettled(receiptId, isSettled);
      await _refreshData();
    } on InventoryException catch (error) {
      setState(() {
        _message = error.message;
      });
    }
  }

  Future<void> _confirmDeleteInboundReceipt(InboundReceipt receipt) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('删除入库单'),
          content: Text('删除 ${receipt.id} 后会回滚这单商品库存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _deleteInboundReceipt(receipt);
  }

  Future<void> _deleteInboundReceipt(InboundReceipt receipt) async {
    try {
      await _database.deleteInboundReceipt(receipt.id);
      await _deleteStoredImage(receipt.imagePath);
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '已删除入库单：${receipt.id}';
      });
    } on InventoryException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = error.message;
      });
    }
  }

  Future<void> _deleteStoredImage(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) {
      return;
    }
    final file = File(imagePath);
    if (!file.existsSync()) {
      return;
    }
    try {
      await file.delete();
    } on FileSystemException {
      return;
    }
  }

  void _addStockToOutboundCart(WarehouseStock stock) {
    final index = _outboundCart
        .indexWhere((item) => item.productCode == stock.productCode);
    setState(() {
      if (index < 0) {
        _outboundCart.add(
          _OutboundCartEntry(
            productCode: stock.productCode,
            productName: stock.productName,
            quantity: 1,
          ),
        );
        _message = '已加入出库车：${stock.productName}';
        return;
      }
      final current = _outboundCart[index];
      if (current.quantity >= stock.quantity) {
        _message = '出库数量不能超过当前库存';
        return;
      }
      _outboundCart[index] = current.copyWith(quantity: current.quantity + 1);
      _message = '已增加出库数量：${stock.productName}';
    });
  }

  void _setOutboundCartQuantity(String productCode, int quantity) {
    final index =
        _outboundCart.indexWhere((item) => item.productCode == productCode);
    if (index < 0) {
      return;
    }
    final available = _stockQuantityFor(productCode);
    if (available <= 0) {
      _removeOutboundCartItem(productCode);
      return;
    }
    final nextQuantity = quantity.clamp(1, available).toInt();
    setState(() {
      _outboundCart[index] =
          _outboundCart[index].copyWith(quantity: nextQuantity);
    });
  }

  void _removeOutboundCartItem(String productCode) {
    setState(() {
      _outboundCart.removeWhere((item) => item.productCode == productCode);
      _message = '已移出出库车';
    });
  }

  int _stockQuantityFor(String productCode) {
    for (final stock in _stockTotals) {
      if (stock.productCode == productCode) {
        return stock.quantity;
      }
    }
    return 0;
  }

  Future<void> _captureOutboundImage() async {
    try {
      final image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 80,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (image == null) {
        return;
      }
      final storedImagePath = await _storeOutboundImage(image);
      if (!mounted) {
        return;
      }
      setState(() {
        _outboundImagePaths.add(storedImagePath);
        _message = '已添加出库照片';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = '拍出库照片失败：$error';
      });
    }
  }

  Future<String> _storeOutboundImage(XFile image) async {
    final directory = await getApplicationDocumentsDirectory();
    final imageDirectory = Directory(p.join(directory.path, 'outbound_images'));
    await imageDirectory.create(recursive: true);
    final extension = p.extension(image.path).isEmpty
        ? '.jpg'
        : p.extension(image.path).toLowerCase();
    final filename = '${DateTime.now().microsecondsSinceEpoch}$extension';
    final storedFile = await File(image.path).copy(
      p.join(imageDirectory.path, filename),
    );
    return storedFile.path;
  }

  Future<void> _removeOutboundImage(String imagePath) async {
    setState(() {
      _outboundImagePaths.remove(imagePath);
      _message = '已移除出库照片';
    });
    await _deleteStoredImage(imagePath);
  }

  Future<void> _clearOutboundCart({bool deleteImages = true}) async {
    final imagePaths = List<String>.from(_outboundImagePaths);
    setState(() {
      _outboundCart.clear();
      _outboundImagePaths.clear();
      _message = '已清空出库车';
    });
    if (!deleteImages) {
      return;
    }
    for (final imagePath in imagePaths) {
      await _deleteStoredImage(imagePath);
    }
  }

  Future<void> _confirmOutboundFromCart() async {
    try {
      final order = await _database.confirmOutbound(
        items: _outboundCart.map((item) {
          return OutboundItem(
            productCode: item.productCode,
            productName: item.productName,
            quantity: item.quantity,
          );
        }).toList(growable: false),
        imagePaths: _outboundImagePaths,
      );
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _outboundCart.clear();
        _outboundImagePaths.clear();
        _message = '出库单已生成：${order.id}';
      });
    } on InventoryException catch (error) {
      setState(() {
        _message = error.message;
      });
    }
  }
}
