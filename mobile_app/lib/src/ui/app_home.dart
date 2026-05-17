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
import '../domain/ocr_settings.dart';
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
  final TextEditingController _sellerOrderController = TextEditingController();
  final TextEditingController _rebateOrderController = TextEditingController();
  final TextEditingController _historySearchController =
      TextEditingController();
  final TextEditingController _stockSearchController = TextEditingController();
  final TextEditingController _outboundHistorySearchController =
      TextEditingController();
  final TextEditingController _outboundLogisticsController =
      TextEditingController();
  final TextEditingController _ocrTextController = TextEditingController();
  final List<InboundDraftItem> _draftItems = [];
  final List<_OutboundCartEntry> _outboundCart = [];
  final List<String> _outboundImagePaths = [];
  final Map<String, int> _stockAddQuantities = {};
  List<WarehouseStock> _stockTotals = const [];
  List<InboundReceipt> _inboundHistory = const [];
  List<OutboundOrder> _outboundHistory = const [];
  String? _currentInboundImagePath;
  String? _message;
  double _ocrRowMergeTolerance = OcrSettings.defaultRowMergeTolerance;
  bool _isSettled = false;
  bool _isReady = false;
  bool _isBackupBusy = false;
  int _selectedTabIndex = 0;
  int? _revealedDraftDeleteIndex;
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
    _sellerOrderController.dispose();
    _rebateOrderController.dispose();
    _historySearchController.dispose();
    _stockSearchController.dispose();
    _outboundHistorySearchController.dispose();
    _outboundLogisticsController.dispose();
    _ocrTextController.dispose();
    unawaited(_database.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        minimum: const EdgeInsets.only(top: 12),
        child: !_isReady
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: _selectedTabIndex,
                children: [
                  _scanInboundTab(),
                  _historyInboundTab(),
                  _stockTotalsTab(),
                  _historyOutboundTab(),
                  _profileTab(),
                ],
              ),
      ),
      floatingActionButton: _isReady && _selectedTabIndex == 2
          ? _outboundCartFloatingEntry()
          : null,
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
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: '我的',
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
      const SizedBox(height: 8),
      _sellerOrderRow(),
      const SizedBox(height: 8),
      _rebateOrderRow(),
      const SizedBox(height: 12),
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
      _inboundDraftToolbar(),
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
          labelText: '搜索入库单、快递、商家或返利单号',
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
    final stocks = _filteredStockTotals();
    return _page([
      _sectionTitle('商品总量'),
      TextField(
        controller: _stockSearchController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: '搜索商品名称或编码',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: _stockSearchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  onPressed: () {
                    setState(() {
                      _stockSearchController.clear();
                    });
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
      ),
      const SizedBox(height: 8),
      if (_stockTotals.isEmpty)
        const ListTile(title: Text('暂无库存'))
      else if (stocks.isEmpty)
        const ListTile(title: Text('没有匹配的商品')),
      ...stocks.map(_stockTile),
    ]);
  }

  Widget _historyOutboundTab() {
    final orders = _filteredOutboundHistory();
    return _page([
      _sectionTitle('历史出库'),
      TextField(
        controller: _outboundHistorySearchController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: '搜索出库单号、物流单号或商品',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: _outboundHistorySearchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  onPressed: () {
                    setState(() {
                      _outboundHistorySearchController.clear();
                    });
                  },
                  icon: const Icon(Icons.close),
                ),
        ),
      ),
      const SizedBox(height: 8),
      if (_outboundHistory.isEmpty)
        const ListTile(title: Text('暂无出货记录'))
      else if (orders.isEmpty)
        const ListTile(title: Text('没有匹配的出库记录')),
      ...orders.map(_outboundTile),
    ]);
  }

  Widget _profileTab() {
    return _page([
      _sectionTitle('我的'),
      _ocrRowMergeToleranceControl(),
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.upload_file_outlined),
        title: const Text('导出备份'),
        subtitle: const Text('导出本机库存、入库、出库和图片关联'),
        enabled: !_isBackupBusy,
        onTap: _isBackupBusy
            ? null
            : () => _onBackupActionSelected(_BackupAction.exportData),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.download_for_offline_outlined),
        title: const Text('导入备份'),
        subtitle: const Text('选择备份文件并覆盖恢复本机数据'),
        enabled: !_isBackupBusy,
        onTap: _isBackupBusy
            ? null
            : () => _onBackupActionSelected(_BackupAction.importData),
      ),
    ]);
  }

  Widget _ocrRowMergeToleranceControl() {
    final valueText = _ocrRowMergeTolerance.toStringAsFixed(2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.tune_outlined),
          title: Text('OCR 行距参数 $valueText'),
          subtitle: const Text('严格 - 宽松'),
        ),
        Slider(
          min: OcrSettings.minRowMergeTolerance,
          max: OcrSettings.maxRowMergeTolerance,
          divisions: 8,
          label: valueText,
          value: _ocrRowMergeTolerance,
          onChanged: (value) {
            setState(() {
              _ocrRowMergeTolerance =
                  OcrSettings.normalizeRowMergeTolerance(value);
            });
          },
          onChangeEnd: _saveOcrRowMergeTolerance,
        ),
      ],
    );
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

  Widget _sellerOrderRow() {
    return TextField(
      controller: _sellerOrderController,
      decoration: const InputDecoration(
        labelText: '商家单号',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _rebateOrderRow() {
    return TextField(
      controller: _rebateOrderController,
      decoration: const InputDecoration(
        labelText: '返利单号',
        border: OutlineInputBorder(),
      ),
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

  Widget _inboundDraftToolbar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '商品草稿 ${_draftItems.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          TextButton.icon(
            onPressed: _addManualDraftItem,
            icon: const Icon(Icons.add),
            label: const Text('添加商品'),
          ),
          IconButton.filledTonal(
            tooltip: '识别文本',
            onPressed: _showOcrTextDialog,
            icon: const Icon(Icons.subject_outlined),
          ),
        ],
      ),
    );
  }

  Widget _draftTile(int index, InboundDraftItem item) {
    final sourceKey = item.sourceText ?? 'manual';
    final isDeleteRevealed = _revealedDraftDeleteIndex == index;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          children: [
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 76,
                  child: ColoredBox(
                    color: colorScheme.error,
                    child: IconButton(
                      tooltip: '删除商品草稿',
                      onPressed: () => _removeDraftItem(index),
                      icon: Icon(
                        Icons.delete_outline,
                        color: colorScheme.onError,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(isDeleteRevealed ? -76 : 0, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (isDeleteRevealed) {
                    setState(() {
                      _revealedDraftDeleteIndex = null;
                    });
                  }
                },
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -80) {
                    setState(() {
                      _revealedDraftDeleteIndex = index;
                    });
                  } else if (velocity > 80) {
                    setState(() {
                      _revealedDraftDeleteIndex = null;
                    });
                  }
                },
                child: ColoredBox(
                  color: colorScheme.surface,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: colorScheme.outlineVariant),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Column(
                        children: [
                          TextFormField(
                            key: ValueKey('draft-name-$index-$sourceKey'),
                            initialValue: item.productName,
                            style: Theme.of(context).textTheme.bodyLarge,
                            maxLines: 1,
                            textInputAction: TextInputAction.next,
                            onChanged: (value) {
                              if (index >= _draftItems.length) {
                                return;
                              }
                              final current = _draftItems[index];
                              _replaceDraftItem(
                                index,
                                current.copyWith(productName: value),
                              );
                            },
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              prefixText: '名称：',
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  key: ValueKey('draft-code-$index-$sourceKey'),
                                  initialValue: item.productCode ?? '',
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  textInputAction: TextInputAction.next,
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
                                    isDense: true,
                                    border: InputBorder.none,
                                    prefixText: '商品编号：',
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 72,
                                child: TextFormField(
                                  key: ValueKey(
                                    'draft-qty-$index-${item.quantity}',
                                  ),
                                  initialValue: item.quantity.toString(),
                                  style: Theme.of(context).textTheme.bodySmall,
                                  textAlign: TextAlign.end,
                                  keyboardType: TextInputType.number,
                                  onChanged: (value) {
                                    final nextQuantity =
                                        int.tryParse(value.trim()) ?? 0;
                                    _setDraftQuantity(index, nextQuantity);
                                  },
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: InputBorder.none,
                                    prefixText: '数量：',
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stockTile(WarehouseStock stock) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final nameMaxWidth = constraints.maxWidth * 0.7;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: nameMaxWidth),
                      child: Text(
                        stock.productName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '商品编码：${stock.productCode}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '商品数量：${stock.quantity}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 58,
                child: TextFormField(
                  key: ValueKey('stock-add-${stock.productCode}'),
                  initialValue: _stockAddQuantityFor(stock).toString(),
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                  ),
                  onChanged: (value) {
                    final quantity = int.tryParse(value.trim());
                    if (quantity == null) {
                      return;
                    }
                    _stockAddQuantities[stock.productCode] = quantity;
                  },
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '加入出库车',
                onPressed: stock.quantity <= 0
                    ? null
                    : () => _addStockToOutboundCart(
                          stock,
                          _stockAddQuantityFor(stock),
                        ),
                icon: const Icon(Icons.add_shopping_cart_outlined),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _receiptTile(InboundReceipt receipt) {
    final primaryStyle = Theme.of(context).textTheme.bodyLarge;
    final secondaryStyle = Theme.of(context).textTheme.bodyMedium;
    final orderParts = <String>[
      if (receipt.sellerOrderNumber?.isNotEmpty ?? false)
        '商家单号：${receipt.sellerOrderNumber}',
      if (receipt.rebateOrderNumber?.isNotEmpty ?? false)
        '返利单号：${receipt.rebateOrderNumber}',
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => _showInboundReceiptDialog(receipt),
      title: Text('快递单号：${receipt.trackingNumber}', style: primaryStyle),
      subtitle: Text(
        [
          _formatReceiptTime(receipt.createdAt),
          '${receipt.items.length} 个商品',
          receipt.isSettled ? '已结算' : '未结算',
          ...orderParts,
        ].join(' · '),
        style: secondaryStyle,
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }

  Widget _inboundReceiptItemList(
    List<InboundDraftItem> items,
    List<TextEditingController> quantityControllers, {
    required VoidCallback onChanged,
  }) {
    if (items.isEmpty) {
      return const ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text('暂无商品清单'),
      );
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text('商品清单 ${items.length}'),
      children: [
        for (var index = 0; index < items.length; index += 1)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(items[index].productName),
            subtitle: Text(items[index].productCode ?? '无商品编号'),
            trailing: SizedBox(
              width: 82,
              child: TextFormField(
                controller: quantityControllers[index],
                textAlign: TextAlign.end,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '数量',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _showInboundReceiptDialog(InboundReceipt receipt) async {
    final quantityControllers = [
      for (final item in receipt.items)
        TextEditingController(text: item.quantity.toString()),
    ];
    var hasQuantityChanges = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              void markChanged() {
                final changed = _receiptQuantitiesChanged(
                  receipt,
                  quantityControllers,
                );
                if (changed == hasQuantityChanges) {
                  return;
                }
                setDialogState(() {
                  hasQuantityChanges = changed;
                });
              }

              return AlertDialog(
                titlePadding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
                contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                title: Row(
                  children: [
                    const Expanded(child: Text('入库单详情')),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 460,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('快递单号：${receipt.trackingNumber}'),
                        if (receipt.sellerOrderNumber?.isNotEmpty ?? false)
                          Text('商家单号：${receipt.sellerOrderNumber}'),
                        if (receipt.rebateOrderNumber?.isNotEmpty ?? false)
                          Text('返利单号：${receipt.rebateOrderNumber}'),
                        Text('入库单号：${receipt.id}'),
                        Text('入库时间：${_formatReceiptTime(receipt.createdAt)}'),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('本单已结算'),
                          value: receipt.isSettled,
                          onChanged: (selected) async {
                            await _setReceiptSettled(receipt.id, selected);
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          },
                        ),
                        _inboundReceiptItemList(
                          receipt.items,
                          quantityControllers,
                          onChanged: markChanged,
                        ),
                        if (receipt.imagePath != null &&
                            receipt.imagePath!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            '入库单图片',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          InkWell(
                            onTap: () => _showReceiptImage(receipt.imagePath!),
                            child: _imageThumbnail(File(receipt.imagePath!)),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton.icon(
                    onPressed: () async {
                      final confirmed =
                          await _confirmDeleteInboundReceipt(receipt);
                      if (confirmed == true && dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除入库单'),
                  ),
                  FilledButton.icon(
                    onPressed: hasQuantityChanges
                        ? () async {
                            final saved = await _saveInboundReceiptQuantities(
                              receipt,
                              quantityControllers,
                            );
                            if (saved && dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          }
                        : null,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      for (final controller in quantityControllers) {
        controller.dispose();
      }
    }
  }

  bool _receiptQuantitiesChanged(
    InboundReceipt receipt,
    List<TextEditingController> quantityControllers,
  ) {
    for (var index = 0; index < receipt.items.length; index += 1) {
      final quantity = int.tryParse(quantityControllers[index].text.trim());
      if (quantity != receipt.items[index].quantity) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _saveInboundReceiptQuantities(
    InboundReceipt receipt,
    List<TextEditingController> quantityControllers,
  ) async {
    final updatedItems = <InboundDraftItem>[];
    for (var index = 0; index < receipt.items.length; index += 1) {
      final quantityText = quantityControllers[index].text.trim();
      final quantity = int.tryParse(quantityText);
      if (quantity == null || quantity <= 0) {
        setState(() {
          _message = '商品数量必须大于 0';
        });
        return false;
      }
      updatedItems.add(receipt.items[index].copyWith(quantity: quantity));
    }
    try {
      await _database.updateInboundReceiptItems(receipt.id, updatedItems);
      await _refreshData();
      if (!mounted) {
        return true;
      }
      setState(() {
        _message = '已保存入库单数量：${receipt.id}';
      });
      return true;
    } on InventoryException catch (error) {
      if (!mounted) {
        return false;
      }
      setState(() {
        _message = error.message;
      });
      return false;
    }
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
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(order.id),
      subtitle: Text(
        [
          _formatReceiptTime(order.createdAt),
          '${order.items.length} 个商品',
          '共 $quantity 件',
          if (order.logisticsNumber?.isNotEmpty ?? false)
            '物流单号：${order.logisticsNumber}',
        ].join(' · '),
      ),
      children: [
        for (final item in order.items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(item.productName),
            subtitle: Text(item.productCode),
            trailing: Text('x${item.quantity}'),
          ),
        if (order.imagePaths.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: _imagePathWrap(order.imagePaths),
          ),
      ],
    );
  }

  Widget _outboundCartFloatingEntry() {
    final totalQuantity =
        _outboundCart.fold<int>(0, (sum, item) => sum + item.quantity);
    return FloatingActionButton.extended(
      onPressed: _showOutboundCartDialog,
      icon: const Icon(Icons.shopping_cart_outlined),
      label: Text(totalQuantity == 0 ? '出库车' : '出库车 $totalQuantity'),
    );
  }

  Widget _outboundCartPanel({VoidCallback? onChanged}) {
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
                onPressed: () async {
                  await _clearOutboundCart();
                  onChanged?.call();
                },
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
          for (final entry in _outboundCart)
            _outboundCartTile(entry, onChanged: onChanged),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('合计出库 $totalQuantity 件'),
          ),
        ],
        if (_outboundCart.isNotEmpty) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _outboundLogisticsController,
            onChanged: (_) => onChanged?.call(),
            decoration: const InputDecoration(
              labelText: '物流单号（选填）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (_outboundImagePaths.isNotEmpty) ...[
          const SizedBox(height: 8),
          _imagePathWrap(
            _outboundImagePaths,
            editable: true,
            onChanged: onChanged,
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await _captureOutboundImage();
                  onChanged?.call();
                },
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('拍出库照片'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _outboundCart.isEmpty
                    ? null
                    : () async {
                        final confirmed = await _confirmOutboundOrderDialog();
                        if (confirmed == true) {
                          await _confirmOutboundFromCart();
                        }
                      },
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('生成出库单'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _outboundCartTile(
    _OutboundCartEntry entry, {
    VoidCallback? onChanged,
  }) {
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
                onPressed: () {
                  _removeOutboundCartItem(entry.productCode);
                  onChanged?.call();
                },
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
                    : () {
                        _setOutboundCartQuantity(
                          entry.productCode,
                          entry.quantity - 1,
                        );
                        onChanged?.call();
                      },
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
                    : () {
                        _setOutboundCartQuantity(
                          entry.productCode,
                          entry.quantity + 1,
                        );
                        onChanged?.call();
                      },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _imagePathWrap(
    List<String> imagePaths, {
    bool editable = false,
    VoidCallback? onChanged,
  }) {
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
                      onPressed: () async {
                        await _removeOutboundImage(imagePath);
                        onChanged?.call();
                      },
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _showOutboundCartDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            void refreshDialog() {
              if (mounted) {
                setState(() {});
              }
              setDialogState(() {});
            }

            return AlertDialog(
              titlePadding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
              contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              title: Row(
                children: [
                  const Expanded(child: Text('出库购物车')),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: _outboundCartPanel(onChanged: refreshDialog),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<bool?> _confirmOutboundOrderDialog() {
    final totalQuantity =
        _outboundCart.fold<int>(0, (sum, item) => sum + item.quantity);
    final logisticsNumber = _outboundLogisticsController.text.trim();
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认生成出库单'),
          content: Text(
            [
              '本次将出库 ${_outboundCart.length} 个商品，共 $totalQuantity 件。',
              if (logisticsNumber.isNotEmpty) '物流单号：$logisticsNumber。',
              '确认后会扣减库存。',
            ].join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认出库'),
            ),
          ],
        );
      },
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
          receipt.trackingNumber.toLowerCase().contains(keyword) ||
          (receipt.sellerOrderNumber?.toLowerCase().contains(keyword) ??
              false) ||
          (receipt.rebateOrderNumber?.toLowerCase().contains(keyword) ?? false);
      final matchesSettlement = switch (_historySettlementFilter) {
        _HistorySettlementFilter.all => true,
        _HistorySettlementFilter.settled => receipt.isSettled,
        _HistorySettlementFilter.unsettled => !receipt.isSettled,
      };
      return matchesKeyword && matchesSettlement;
    }).toList(growable: false);
  }

  List<WarehouseStock> _filteredStockTotals() {
    final keyword = _stockSearchController.text.trim().toLowerCase();
    if (keyword.isEmpty) {
      return _stockTotals;
    }
    return _stockTotals.where((stock) {
      return stock.productCode.toLowerCase().contains(keyword) ||
          stock.productName.toLowerCase().contains(keyword);
    }).toList(growable: false);
  }

  List<OutboundOrder> _filteredOutboundHistory() {
    final keyword = _outboundHistorySearchController.text.trim().toLowerCase();
    if (keyword.isEmpty) {
      return _outboundHistory;
    }
    return _outboundHistory.where((order) {
      return order.id.toLowerCase().contains(keyword) ||
          (order.logisticsNumber?.toLowerCase().contains(keyword) ?? false) ||
          order.items.any((item) {
            return item.productCode.toLowerCase().contains(keyword) ||
                item.productName.toLowerCase().contains(keyword);
          });
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
      final recognition = await _paddleOcr.recognizeTable(
        storedImagePath,
        rowMergeTolerance: _ocrRowMergeTolerance,
      );
      final rows = recognition.rows;
      final editableText = recognition.editableText;
      final orderNumber = _postProcessor.extractSellerOrderNumber(editableText);
      final filledSellerOrder =
          _sellerOrderController.text.trim().isEmpty && orderNumber != null;

      var items = _postProcessor.processRows(rows);
      if (items.isEmpty && editableText.isNotEmpty) {
        items = _postProcessor.processPlainText(editableText);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        if (filledSellerOrder) {
          _sellerOrderController.text = orderNumber;
        }
        _ocrTextController.text = editableText;
        _draftItems
          ..clear()
          ..addAll(items);
        final orderMessage = filledSellerOrder ? '，已填入商家单号' : '';
        if (items.isNotEmpty) {
          _message = '已识别 ${items.length} 条商品草稿，图片已保存$orderMessage';
        } else if (editableText.isNotEmpty) {
          _message = '已识别文字但未生成商品草稿，可编辑文本后点从文本重新生成$orderMessage';
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
      final ocrRowMergeTolerance = await _database.loadOcrRowMergeTolerance();
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _ocrRowMergeTolerance = ocrRowMergeTolerance;
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

  Future<void> _saveOcrRowMergeTolerance(double value) async {
    final normalized = OcrSettings.normalizeRowMergeTolerance(value);
    setState(() {
      _ocrRowMergeTolerance = normalized;
    });
    try {
      await _database.saveOcrRowMergeTolerance(normalized);
      if (!mounted) {
        return;
      }
      setState(() {
        _message = 'OCR 行距参数已保存：${normalized.toStringAsFixed(2)}';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _message = 'OCR 行距参数保存失败：$error';
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
    final text = _ocrTextController.text;
    final items = _postProcessor.processPlainText(text);
    final orderNumber = _postProcessor.extractSellerOrderNumber(text);
    final filledSellerOrder =
        _sellerOrderController.text.trim().isEmpty && orderNumber != null;
    setState(() {
      if (filledSellerOrder) {
        _sellerOrderController.text = orderNumber;
      }
      _draftItems
        ..clear()
        ..addAll(items);
      final orderMessage = filledSellerOrder ? '，已填入商家单号' : '';
      _message = items.isEmpty
          ? '未生成商品草稿，有顺丰单号也可先确认入库$orderMessage'
          : '已重新生成 ${items.length} 条商品草稿$orderMessage';
    });
  }

  Future<void> _showOcrTextDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 18, 8, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          title: Row(
            children: [
              const Expanded(child: Text('识别文本')),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: TextField(
              controller: _ocrTextController,
              minLines: 8,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: '商品清单识别文本',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            FilledButton.icon(
              onPressed: () {
                _parseOcrText();
                Navigator.of(dialogContext).pop();
              },
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('从文本重新生成'),
            ),
          ],
        );
      },
    );
  }

  void _addManualDraftItem() {
    setState(() {
      _draftItems.add(
        InboundDraftItem(
          productName: '',
          quantity: 1,
          sourceText: 'manual-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      _message = '已添加 1 条空白商品草稿';
    });
  }

  void _replaceDraftItem(int index, InboundDraftItem item) {
    if (index < 0 || index >= _draftItems.length) {
      return;
    }
    _draftItems[index] = item;
  }

  void _setDraftQuantity(int index, int quantity) {
    if (index < 0 || index >= _draftItems.length) {
      return;
    }
    final nextQuantity = quantity < 1 ? 1 : quantity;
    setState(() {
      _draftItems[index] = _draftItems[index].copyWith(quantity: nextQuantity);
    });
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
    _sellerOrderController.clear();
    _rebateOrderController.clear();
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
        sellerOrderNumber: _sellerOrderController.text,
        rebateOrderNumber: _rebateOrderController.text,
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
        _sellerOrderController.clear();
        _rebateOrderController.clear();
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

  Future<bool> _confirmDeleteInboundReceipt(InboundReceipt receipt) async {
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
      return false;
    }
    await _deleteInboundReceipt(receipt);
    return true;
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

  int _stockAddQuantityFor(WarehouseStock stock) {
    final quantity = _stockAddQuantities[stock.productCode] ?? 1;
    if (stock.quantity <= 0) {
      return 1;
    }
    return quantity.clamp(1, stock.quantity).toInt();
  }

  void _addStockToOutboundCart(WarehouseStock stock, int quantity) {
    final nextQuantity = quantity.clamp(1, stock.quantity).toInt();
    final index = _outboundCart
        .indexWhere((item) => item.productCode == stock.productCode);
    setState(() {
      if (index < 0) {
        _outboundCart.add(
          _OutboundCartEntry(
            productCode: stock.productCode,
            productName: stock.productName,
            quantity: nextQuantity,
          ),
        );
        _message = '已加入出库车：${stock.productName}';
        return;
      }
      final current = _outboundCart[index];
      final mergedQuantity = current.quantity + nextQuantity;
      if (mergedQuantity > stock.quantity) {
        _outboundCart[index] = current.copyWith(quantity: stock.quantity);
        _message = '出库数量不能超过当前库存';
        return;
      }
      _outboundCart[index] = current.copyWith(quantity: mergedQuantity);
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
      _outboundLogisticsController.clear();
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
        logisticsNumber: _outboundLogisticsController.text,
      );
      await _refreshData();
      if (!mounted) {
        return;
      }
      setState(() {
        _outboundCart.clear();
        _outboundImagePaths.clear();
        _outboundLogisticsController.clear();
        _message = '出库单已生成：${order.id}';
      });
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } on InventoryException catch (error) {
      setState(() {
        _message = error.message;
      });
    }
  }
}
