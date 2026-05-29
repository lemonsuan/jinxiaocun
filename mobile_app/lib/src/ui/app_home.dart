import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;


import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../application/inventory_service.dart';
import '../data/local_inventory_database.dart';
import '../domain/models.dart';
import '../domain/ocr_settings.dart';
import '../ocr/gemma_extractor.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/paddle_ocr_channel.dart';
import 'scanner_page.dart';
import 'product_price_page.dart';
import 'photo_count_page.dart';
import 'backup_management_page.dart';
import 'ai_config_page.dart';



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
  late final GemmaExtractor _gemmaExtractor = GemmaExtractor(_database);
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

  List<WarehouseStock> _stockTotals = const [];
  List<InboundReceipt> _inboundHistory = const [];
  List<OutboundOrder> _outboundHistory = const [];
  String? _currentInboundImagePath;
  String? _message;
  double _ocrRowMergeTolerance = OcrSettings.defaultRowMergeTolerance;
  bool _isSettled = false;
  bool _isReady = false;

  int _selectedTabIndex = 0;
  int _inventorySubTabIndex = 0;
  int? _revealedDraftDeleteIndex;
  _HistorySettlementFilter _historySettlementFilter =
      _HistorySettlementFilter.all;
  String? _expandedReceiptId;
  final Map<String, int> _editingReceiptQuantities = {};

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
                  _inventoryManagementTab(),
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
            label: '库存管理',
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

      // 1. 三行输入大圆角白色 Card 容器
      Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              // 第一行：快递单号
              Row(
                children: [
                  const Icon(Icons.mail_outline, color: Colors.grey, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _trackingController,
                      decoration: const InputDecoration(
                        hintText: '输入或扫描快递单号',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _scanTrackingNumber,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F3ED),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.qr_code_scanner,
                          color: Color(0xff2d6a4f), size: 18),
                    ),
                  ),
                ],
              ),
              Divider(height: 1, color: Colors.grey.shade100),

              // 第二行：商家单号
              Row(
                children: [
                  const Icon(Icons.storefront, color: Colors.grey, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _sellerOrderController,
                      decoration: const InputDecoration(
                        hintText: '输入商家单号',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
              Divider(height: 1, color: Colors.grey.shade100),

              // 第三行：方案编号
              Row(
                children: [
                  const Icon(Icons.assignment_outlined,
                      color: Colors.grey, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _rebateOrderController,
                      decoration: const InputDecoration(
                        hintText: '输入方案编号',
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),

      // 2. 拍照识别与相册识别动作 Card
      Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xff2d6a4f),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _captureAndRecognizeList,
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('拍照识别',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE8F3ED),
                    foregroundColor: const Color(0xff2d6a4f),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _pickAndRecognizeList,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: const Text('相册识别',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
      if (_currentInboundImagePath != null) ...[
        const SizedBox(height: 8),
        _inboundImageTile(_currentInboundImagePath!),
      ],
      const SizedBox(height: 12),
      _inboundDraftToolbar(),
      for (var index = 0; index < _draftItems.length; index += 1)
        _draftTile(index, _draftItems[index]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _isSettled,
        activeThumbColor: const Color(0xff2d6a4f),
        onChanged: (value) {
          setState(() {
            _isSettled = value;
          });
        },
        title:
            const Text('本单已结算', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      const SizedBox(height: 4),
      SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xff2d6a4f),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: _confirmInbound,
          icon: const Icon(Icons.archive_outlined, size: 20),
          label: const Text('确认入库',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
      ),
      const SizedBox(height: 12),
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
    final valueText = _ocrRowMergeTolerance.toStringAsFixed(2);

    return _page([
      _sectionTitle('个人中心'),
      const SizedBox(height: 8),

      // 1. 上部白色 Card 容器（拍照计数、商品价格管理）
      Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.center_focus_weak,
                      color: Colors.blue.shade600, size: 20),
                ),
                title: const Text('拍照计数',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                subtitle: const Text('端侧离线自动识别与标记计数',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => PhotoCountPage(
                        database: _database,
                        onInventoryUpdated: _refreshData,
                      ),
                    ),
                  );
                },
              ),
              Divider(height: 1, color: Colors.grey.shade100),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.local_offer_outlined,
                      color: Colors.green.shade600, size: 20),
                ),
                title: const Text('商品价格管理',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                subtitle: const Text('查看全部商品并编辑入库/出库指导价格',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => ProductPricePage(
                        database: _database,
                        onPricesUpdated: _refreshData,
                      ),
                    ),
                  );
                },
              ),
              Divider(height: 1, color: Colors.grey.shade100),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.auto_awesome_outlined,
                      color: Colors.teal.shade600, size: 20),
                ),
                title: const Text('AI 智能提取配置',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                subtitle: const Text('配置 OpenAI/Gemini 双格式并动态选择大模型',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => AiConfigPage(
                        database: _database,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),

      // 2. 下部白色 Card 容器（OCR 行距滑块、备份管理）
      Card(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              // OCR 行距滑块行 (1:1 像素级复原右侧 Slider 水平对齐)
              Row(
                children: [
                  Expanded(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.purple.shade50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.tune_outlined,
                            color: Colors.purple.shade600, size: 20),
                      ),
                      title: Text('OCR 行距 $valueText',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                      subtitle: const Text('严格 - 宽松',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 130,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 12),
                      ),
                      child: Slider(
                        min: OcrSettings.minRowMergeTolerance,
                        max: OcrSettings.maxRowMergeTolerance,
                        divisions: 8,
                        activeColor: const Color(0xff2d6a4f),
                        value: _ocrRowMergeTolerance,
                        onChanged: (value) {
                          setState(() {
                            _ocrRowMergeTolerance =
                                OcrSettings.normalizeRowMergeTolerance(value);
                          });
                        },
                        onChangeEnd: _saveOcrRowMergeTolerance,
                      ),
                    ),
                  ),
                ],
              ),
              Divider(height: 1, color: Colors.grey.shade100),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.cloud_upload_outlined,
                      color: Colors.orange.shade600, size: 20),
                ),
                title: const Text('备份管理',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                subtitle: const Text('本地备份数据历史、导入/导出与还原',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => BackupManagementPage(
                        database: _database,
                        onDatabaseRestored: _refreshData,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
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
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '扫码入库',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _clearCurrentInboundDraft,
            icon: const Icon(Icons.cleaning_services_outlined, size: 16),
            label: const Text('清空当前单',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xff2d6a4f),
              side: const BorderSide(color: Color(0xff2d6a4f), width: 1.2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ],
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '商品草稿 ${_draftItems.length}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          TextButton.icon(
            onPressed: _addManualDraftItem,
            icon: const Icon(Icons.edit, size: 16, color: Color(0xff2d6a4f)),
            label: const Text('手动添加',
                style: TextStyle(
                    color: Color(0xff2d6a4f),
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            onPressed: _scanDraftItem,
            icon: const Icon(Icons.qr_code_scanner,
                size: 16, color: Color(0xff2d6a4f)),
            label: const Text('扫码添加',
                style: TextStyle(
                    color: Color(0xff2d6a4f),
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _openAiExtractDialog,
            child: Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                color: Color(0xFFE8F3ED),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.menu, color: Color(0xff2d6a4f), size: 18),
            ),
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
                          if (item.sourceText != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  (item.sourceText!.contains('Gemma') ||
                                          item.sourceText!.contains('AI'))
                                      ? Icons.auto_awesome
                                      : Icons.edit_note,
                                  size: 14,
                                  color: Colors.teal,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  item.sourceText!,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Colors.teal,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ],
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
    final isOutOfStock = stock.quantity <= 0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stock.productName,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '编码：${stock.productCode}',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '库存：${stock.quantity}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isOutOfStock
                                ? Colors.redAccent
                                : const Color(0xff2d6a4f),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isOutOfStock)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '无货',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                )
              else
                GestureDetector(
                  onTap: () {
                    _addStockToOutboundCart(stock, 1);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('已加入出库车：${stock.productName}'),
                        duration: const Duration(milliseconds: 800),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F3ED),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.add_shopping_cart,
                        color: Color(0xff2d6a4f), size: 18),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: Colors.grey.shade100),
      ],
    );
  }

  Future<void> _rotateImageFile(String path, int quarterTurns) async {
    if (quarterTurns % 4 == 0) {
      return;
    }
    final File file = File(path);
    if (!file.existsSync()) return;

    final Uint8List bytes = await file.readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    final ui.Image image = frameInfo.image;

    final double angle = (quarterTurns % 4) * 90 * 3.141592653589793 / 180;
    final bool is90or270 = (quarterTurns % 4) % 2 != 0;
    final int targetWidth = is90or270 ? image.height : image.width;
    final int targetHeight = is90or270 ? image.width : image.height;

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);

    canvas.translate(targetWidth / 2, targetHeight / 2);
    canvas.rotate(angle);
    canvas.translate(-image.width / 2, -image.height / 2);
    canvas.drawImage(image, Offset.zero, ui.Paint());

    final ui.Picture picture = recorder.endRecording();
    final ui.Image rotatedImage =
        await picture.toImage(targetWidth, targetHeight);
    final ByteData? byteData =
        await rotatedImage.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null) {
      await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      // 清理 Flutter ImageCache，防止列表缩略图不更新
      PaintingBinding.instance.imageCache.evict(FileImage(file));
    }

    image.dispose();
    rotatedImage.dispose();
  }

  Future<void> _reRecognizeReceipt(InboundReceipt receipt) async {
    final path = receipt.imagePath;
    if (path == null || path.isEmpty) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        int currentStep = 1;
        int quarterTurns = 0;
        bool isLoading = false;
        List<InboundDraftItem> newDraftItems = [];

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 头部
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '图片旋转与二次识别',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: isLoading ? null : () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close, color: Colors.grey),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 主体
                    if (currentStep == 1) ...[
                      // 第一步：展示预览及旋转 (固定高度，不撑满屏幕)
                      SizedBox(
                        height: 280,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InteractiveViewer(
                                maxScale: 4.0,
                                child: Center(
                                  child: RotatedBox(
                                    quarterTurns: quarterTurns,
                                    child: Image.file(
                                      File(path),
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (isLoading)
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Center(
                                  child: CircularProgressIndicator(
                                    color: Color(0xff2d6a4f),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 底部按钮 Row
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xff2d6a4f),
                                side: const BorderSide(
                                    color: Color(0xff2d6a4f), width: 1.2),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: isLoading
                                  ? null
                                  : () {
                                      setDialogState(() {
                                        quarterTurns = (quarterTurns + 1) % 4;
                                      });
                                    },
                              icon: const Icon(Icons.rotate_right, size: 18),
                              label: const Text(
                                '旋转90°',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xff2d6a4f),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: isLoading
                                  ? null
                                  : () async {
                                      setDialogState(() {
                                        isLoading = true;
                                      });
                                      try {
                                        // 1. 如果有旋转，则先物理旋转并写回文件，且重置 quarterTurns
                                        if (quarterTurns % 4 != 0) {
                                          await _rotateImageFile(path, quarterTurns);
                                          setDialogState(() {
                                            quarterTurns = 0;
                                          });
                                        }

                                        // 2. 调用 OCR 和 Gemma 提取
                                        final ocrResult = await _paddleOcr
                                            .recognizeTable(path,
                                                rowMergeTolerance:
                                                    _ocrRowMergeTolerance);
                                        final ocrText = ocrResult.editableText;
                                        final extracted = await _gemmaExtractor
                                            .extract(ocrText);

                                        newDraftItems = extracted.items
                                            .map((item) => InboundDraftItem(
                                                  productName: item.productName,
                                                  quantity: item.quantity,
                                                  productCode: item.productCode,
                                                  purchasePrice: item.purchasePrice,
                                                  salePrice: item.salePrice,
                                                  sourceText: '重新识别提取',
                                                ))
                                            .toList();

                                        setDialogState(() {
                                          currentStep = 2;
                                          isLoading = false;
                                        });
                                      } catch (e) {
                                        setDialogState(() {
                                          isLoading = false;
                                        });
                                        if (dialogContext.mounted) {
                                          ScaffoldMessenger.of(dialogContext)
                                              .showSnackBar(SnackBar(
                                                  content: Text('识别失败: $e')));
                                        }
                                      }
                                    },
                              icon: const Icon(Icons.document_scanner_outlined,
                                  size: 18),
                              label: const Text(
                                '开始识别',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else ...[
                      // 第二步：识别完成商品预览
                      const Text(
                        '二次识别已完成！商品清单预览：',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF475569),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F6F4),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: newDraftItems.isEmpty
                              ? const SizedBox(
                                  height: 100,
                                  child: Center(
                                    child: Text(
                                      '未提取到商品信息',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  shrinkWrap: true,
                                  physics: const ClampingScrollPhysics(),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  itemCount: newDraftItems.length,
                                  separatorBuilder: (context, index) =>
                                      Divider(height: 1, color: Colors.grey.shade200),
                                  itemBuilder: (context, index) {
                                    final item = newDraftItems[index];
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12, horizontal: 16),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              item.productName,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF1E293B),
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Text(
                                            'x${item.quantity}',
                                            style: const TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: Color(0xff2d6a4f),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 底部按钮 Row
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xff2d6a4f),
                                side: const BorderSide(
                                    color: Color(0xff2d6a4f), width: 1.2),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: () {
                                setDialogState(() {
                                  currentStep = 1;
                                });
                              },
                              child: const Text(
                                '重新旋转',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xff2d6a4f),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onPressed: newDraftItems.isEmpty
                                  ? null
                                  : () async {
                                      try {
                                        await _database.updateInboundReceiptItems(
                                            receipt.id, newDraftItems);
                                        if (dialogContext.mounted) {
                                          Navigator.pop(dialogContext);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text('重新识别并更新成功！')));
                                        }
                                        _refreshData();
                                        setState(() {
                                          _expandedReceiptId = null;
                                        });
                                      } catch (e) {
                                        if (dialogContext.mounted) {
                                          ScaffoldMessenger.of(dialogContext)
                                              .showSnackBar(SnackBar(
                                                  content: Text('覆写保存失败: $e')));
                                        }
                                      }
                                    },
                              child: const Text(
                                '确认覆写清单',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _receiptTile(InboundReceipt receipt) {
    final isExpanded = _expandedReceiptId == receipt.id;
    final totalQuantity =
        receipt.items.fold<int>(0, (sum, item) => sum + item.quantity);

    // 如果展开，将数量读入 Map 进行初始化
    if (isExpanded) {
      for (final item in receipt.items) {
        final key = '${receipt.id}_${item.productCode}';
        _editingReceiptQuantities.putIfAbsent(key, () => item.quantity);
      }
    }

    bool hasChanges = false;
    if (isExpanded) {
      for (final item in receipt.items) {
        final key = '${receipt.id}_${item.productCode}';
        final edited = _editingReceiptQuantities[key] ?? item.quantity;
        if (edited != item.quantity) {
          hasChanges = true;
          break;
        }
      }
    }

    final String timeStr =
        '${receipt.createdAt.year}年${receipt.createdAt.month.toString().padLeft(2, '0')}月${receipt.createdAt.day.toString().padLeft(2, '0')}日 '
        '${receipt.createdAt.hour.toString().padLeft(2, '0')}时${receipt.createdAt.minute.toString().padLeft(2, '0')}分';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          setState(() {
            if (isExpanded) {
              _expandedReceiptId = null;
            } else {
              _expandedReceiptId = receipt.id;
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. 头部 Row (始终展现，左侧70%标题，右侧30%结算按钮)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    flex: 7,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (isExpanded) ...[
                          Text(
                            '单号：${receipt.id}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                        Text(
                          '快递：${receipt.trackingNumber.isEmpty ? "无" : receipt.trackingNumber}',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$timeStr  ·  $totalQuantity 件货',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 右侧 30%：结算状态按钮，支持点击切换
                  Expanded(
                    flex: 3,
                    child: GestureDetector(
                      onTap: () async {
                        try {
                          await _database.setReceiptSettled(
                              receipt.id, !receipt.isSettled);
                          await _refreshData();
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('更新结算状态失败: $e')),
                            );
                          }
                        }
                      },
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: receipt.isSettled
                              ? const Color(0xFFE8F5E9)
                              : const Color(0xFFFFEBEE),
                          border: Border.all(
                            color: receipt.isSettled
                                ? const Color(0xff2d6a4f)
                                : Colors.redAccent,
                            width: 1.0,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: receipt.isSettled
                                    ? const Color(0xff2d6a4f)
                                    : Colors.redAccent,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              receipt.isSettled ? '已结算' : '未结算',
                              style: TextStyle(
                                color: receipt.isSettled
                                    ? const Color(0xff2d6a4f)
                                    : Colors.redAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              // 2. 展开显示商品与操作
              if (isExpanded) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),

                // 商品明细列表
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: receipt.items.length,
                  itemBuilder: (context, idx) {
                    final item = receipt.items[idx];
                    final key = '${receipt.id}_${item.productCode}';
                    final currentQty =
                        _editingReceiptQuantities[key] ?? item.quantity;

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.productName,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '编码：${item.productCode ?? '无'}',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 数字微调器
                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF4F9F4),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove,
                                      size: 14, color: Colors.grey),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    if (currentQty > 1) {
                                      setState(() {
                                        _editingReceiptQuantities[key] =
                                            currentQty - 1;
                                      });
                                    }
                                  },
                                ),
                                Text(
                                  '$currentQty',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add,
                                      size: 14, color: Colors.grey),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () {
                                    setState(() {
                                      _editingReceiptQuantities[key] =
                                          currentQty + 1;
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                // 拍照预览缩略图
                if (receipt.imagePath != null &&
                    File(receipt.imagePath!).existsSync()) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(receipt.imagePath!),
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],

                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // 底部操作区（重新识别、删除单据、保存）
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => _reRecognizeReceipt(receipt),
                          icon: const Icon(Icons.refresh,
                              size: 16, color: Color(0xff2d6a4f)),
                          label: const Text('重新识别',
                              style: TextStyle(
                                  color: Color(0xff2d6a4f),
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact),
                        ),
                        const SizedBox(width: 16),
                        TextButton.icon(
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('删除单据'),
                                content:
                                    const Text('确认要删除这笔入库单据及对应的库存吗？该操作不可撤销！'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('取消')),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('确认删除',
                                        style: TextStyle(
                                            color: Colors.redAccent,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await _database.deleteInboundReceipt(receipt.id);
                              _refreshData();
                            }
                          },
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.redAccent),
                          label: const Text('删除单据',
                              style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact),
                        ),
                      ],
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: hasChanges
                            ? const Color(0xff2d6a4f)
                            : Colors.grey.shade200,
                        foregroundColor:
                            hasChanges ? Colors.white : Colors.grey.shade400,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: !hasChanges
                          ? null
                          : () async {
                              final updatedItems = receipt.items.map((item) {
                                final key = '${receipt.id}_${item.productCode}';
                                final newQty = _editingReceiptQuantities[key] ??
                                    item.quantity;
                                return item.copyWith(quantity: newQty);
                              }).toList();
                              try {
                                await _database.updateInboundReceiptItems(
                                    receipt.id, updatedItems);
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('修改保存成功！')));
                                _refreshData();
                                setState(() {
                                  _expandedReceiptId = null;
                                });
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('保存失败: $e')));
                              }
                            },
                      child: const Text('保存',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
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
    return FloatingActionButton(
      onPressed: _showOutboundCartDialog,
      child: Badge(
        label: totalQuantity > 0 ? Text(totalQuantity.toString()) : null,
        child: const Icon(Icons.shopping_cart_outlined),
      ),
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

  Future<void> _openAiExtractDialog() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        bool isExtracting = false;
        bool isGenerating = false;

        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final isLoading = isExtracting || isGenerating;
            final message = isExtracting
                ? 'AI 正在智能提取中...'
                : (isGenerating ? '正在重新生成文本...' : '');

            return Dialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 标题
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'AI 智能提取文本预览',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: isLoading ? null : () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close, color: Colors.grey),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 文本预览框
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        TextField(
                          controller: _ocrTextController,
                          maxLines: 8,
                          enabled: !isLoading,
                          decoration: const InputDecoration(
                            hintText: '识别出的 OCR 文本，可手动进行微调...',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.all(12),
                          ),
                          style: const TextStyle(fontSize: 14),
                        ),
                        if (isLoading)
                          Container(
                            height: 200,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const CircularProgressIndicator(
                                    color: Color(0xff2d6a4f),
                                    strokeWidth: 3,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    message,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xff2d6a4f),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 底部按钮 Row
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xff2d6a4f),
                              side: const BorderSide(
                                  color: Color(0xff2d6a4f), width: 1.2),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: isLoading
                                ? null
                                : () async {
                                    if (_currentInboundImagePath == null ||
                                        _currentInboundImagePath!.isEmpty) {
                                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                                        const SnackBar(
                                            content: Text('未找到当前单的图片，请先拍照或相册识别')),
                                      );
                                      return;
                                    }
                                    setDialogState(() => isGenerating = true);
                                    try {
                                      final recognition = await _paddleOcr.recognizeTable(
                                        _currentInboundImagePath!,
                                        rowMergeTolerance: _ocrRowMergeTolerance,
                                      );
                                      _ocrTextController.text = recognition.editableText;
                                      if (dialogContext.mounted) {
                                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                                          const SnackBar(content: Text('已重新生成 OCR 文字。')),
                                        );
                                      }
                                    } catch (e) {
                                      if (dialogContext.mounted) {
                                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                                          SnackBar(content: Text('重新生成文字失败: $e')),
                                        );
                                      }
                                    } finally {
                                      setDialogState(() => isGenerating = false);
                                    }
                                  },
                            child: const Text(
                              '重新生成',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xff2d6a4f),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(24)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: isLoading
                                ? null
                                : () async {
                                    final text = _ocrTextController.text.trim();
                                    if (text.isEmpty) {
                                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                                        const SnackBar(
                                            content: Text('识别文本不能为空，无法提取')),
                                      );
                                      return;
                                    }
                                    setDialogState(() => isExtracting = true);
                                    try {
                                      final result = await _gemmaExtractor.extract(text);
                                      if (!dialogContext.mounted) return;
                                      setState(() {
                                        if (result.trackingNumber != null &&
                                            result.trackingNumber!.isNotEmpty) {
                                          _trackingController.text = result.trackingNumber!;
                                        }
                                        if (result.sellerOrderNumber != null &&
                                            result.sellerOrderNumber!.isNotEmpty) {
                                          _sellerOrderController.text =
                                              result.sellerOrderNumber!;
                                        }
                                        if (result.schemeNumber != null &&
                                            result.schemeNumber!.isNotEmpty) {
                                          _rebateOrderController.text =
                                              result.schemeNumber!;
                                        }
                                        if (result.items.isNotEmpty) {
                                          _draftItems
                                            ..clear()
                                            ..addAll(result.items);
                                          _message =
                                              'AI 提取成功，已载入 ${result.items.length} 个商品。';
                                        } else {
                                          _message = 'AI 提取结束，但未发现有效的商品条目。';
                                        }
                                      });
                                      Navigator.pop(dialogContext); // 关闭弹窗
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(_message!)),
                                      );
                                    } catch (e) {
                                      var items = _postProcessor.processPlainText(text);
                                      if (!dialogContext.mounted) return;
                                      setState(() {
                                        if (items.isNotEmpty) {
                                          _draftItems
                                            ..clear()
                                            ..addAll(items);
                                          _message =
                                              'AI 提取失败，已降级本地提取 ${items.length} 个商品。';
                                        } else {
                                          _message = 'AI 提取与本地降级提取均未发现商品。';
                                        }
                                      });
                                      Navigator.pop(dialogContext); // 关闭弹窗
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(_message!)),
                                      );
                                    } finally {
                                      setDialogState(() => isExtracting = false);
                                    }
                                  },
                            child: const Text(
                              'AI 识别',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }



  Future<void> _scanDraftItem() async {
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (context) => const ScannerPage()),
    );
    if (barcode == null || barcode.isEmpty) return;

    String? matchedName;
    try {
      final catalog = await _database.loadProductCatalog();
      final match = catalog.firstWhere((p) => p.productCode == barcode);
      matchedName = match.productName;
    } catch (_) {}

    if (matchedName != null) {
      setState(() {
        _draftItems.insert(
          0,
          InboundDraftItem(
            productName: matchedName!,
            productCode: barcode,
            quantity: 1,
            sourceText: 'Barcode',
          ),
        );
        _message = '扫码添加成功：$matchedName ($barcode)';
      });
    } else {
      if (!mounted) return;
      final nameController = TextEditingController();
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('新增扫码商品'),
            content: TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '请输入商品名称',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () {
                  final text = nameController.text.trim();
                  if (text.isNotEmpty) {
                    Navigator.of(dialogContext).pop(text);
                  }
                },
                child: const Text('添加'),
              ),
            ],
          );
        },
      );
      if (name != null && name.isNotEmpty) {
        setState(() {
          _draftItems.insert(
            0,
            InboundDraftItem(
              productName: name,
              productCode: barcode,
              quantity: 1,
              sourceText: 'Barcode',
            ),
          );
          _message = '扫码添加成功：$name ($barcode)';
        });
      }
    }
  }

  Widget _inventoryManagementTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding:
              const EdgeInsets.only(left: 16, right: 16, top: 8, bottom: 4),
          child: Text(
            '库存管理',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<int>(
                value: 0,
                label: Text('库存商品'),
              ),
              ButtonSegment<int>(
                value: 1,
                label: Text('历史出库'),
              ),
            ],
            selected: {_inventorySubTabIndex},
            onSelectionChanged: (set) {
              setState(() {
                _inventorySubTabIndex = set.first;
              });
            },
          ),
        ),
        Expanded(
          child: _inventorySubTabIndex == 0
              ? _stockTotalsTab()
              : _historyOutboundTab(),
        ),
      ],
    );
  }
}
