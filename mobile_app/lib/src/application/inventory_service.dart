import '../domain/models.dart';
import '../domain/tracking_number_rules.dart';

class InventoryException implements Exception {
  InventoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

class InventoryService {
  final Map<String, WarehouseStock> _stockByCode = {};
  final List<InboundReceipt> _inboundReceipts = [];
  final List<OutboundOrder> _outboundOrders = [];
  final List<StockLedgerEntry> _ledger = [];
  int _sequence = 0;

  List<InboundReceipt> get inboundHistory =>
      List.unmodifiable(_inboundReceipts);
  List<OutboundOrder> get outboundHistory => List.unmodifiable(_outboundOrders);
  List<StockLedgerEntry> get ledger => List.unmodifiable(_ledger);

  List<WarehouseStock> get stockTotals {
    final rows = _stockByCode.values.toList()
      ..sort((a, b) => a.productName.compareTo(b.productName));
    return List.unmodifiable(rows);
  }

  InboundReceipt confirmInbound({
    required String trackingNumber,
    required List<InboundDraftItem> items,
    String? imagePath,
    bool isSettled = false,
  }) {
    final normalizedTracking = trackingNumber.trim();
    if (normalizedTracking.isEmpty) {
      throw InventoryException('Tracking number is required.');
    }
    if (_inboundReceipts.any((r) => r.trackingNumber == normalizedTracking)) {
      throw InventoryException('Tracking number already exists.');
    }
    if (items.isEmpty &&
        !allowsEmptyInboundItemsForTracking(normalizedTracking)) {
      throw InventoryException('Inbound items are required.');
    }
    for (final item in items) {
      _validateInboundItem(item);
    }

    final now = DateTime.now();
    final receipt = InboundReceipt(
      id: _nextId('in'),
      trackingNumber: normalizedTracking,
      createdAt: now,
      items: List.unmodifiable(items),
      isSettled: isSettled,
      ocrStatus: OcrStatus.confirmed,
      imagePath: imagePath,
    );

    for (final item in items) {
      final code = _productCodeFor(item.productCode, item.productName);
      _increaseStock(code, item.productName, item.quantity);
      _ledger.add(
        StockLedgerEntry(
          id: _nextId('lg'),
          productCode: code,
          productName: item.productName.trim(),
          delta: item.quantity,
          reason: LedgerReason.inbound,
          sourceId: receipt.id,
          createdAt: now,
        ),
      );
    }
    _inboundReceipts.add(receipt);
    return receipt;
  }

  InboundReceipt setReceiptSettled(String receiptId, bool isSettled) {
    final index = _inboundReceipts.indexWhere((r) => r.id == receiptId);
    if (index < 0) {
      throw InventoryException('Inbound receipt not found.');
    }
    final current = _inboundReceipts[index];
    final updated = InboundReceipt(
      id: current.id,
      trackingNumber: current.trackingNumber,
      createdAt: current.createdAt,
      items: current.items,
      isSettled: isSettled,
      ocrStatus: current.ocrStatus,
      imagePath: current.imagePath,
    );
    _inboundReceipts[index] = updated;
    return updated;
  }

  InboundReceipt updateInboundReceiptItems(
    String receiptId,
    List<InboundDraftItem> items,
  ) {
    final index = _inboundReceipts.indexWhere((r) => r.id == receiptId);
    if (index < 0) {
      throw InventoryException('Inbound receipt not found.');
    }
    for (final item in items) {
      _validateInboundItem(item);
    }

    final current = _inboundReceipts[index];
    if (current.items.length != items.length) {
      throw InventoryException('Inbound receipt items changed. Refresh first.');
    }

    final negativeDeltasByCode = <String, int>{};
    for (var itemIndex = 0; itemIndex < current.items.length; itemIndex += 1) {
      final oldItem = current.items[itemIndex];
      final newItem = items[itemIndex];
      final delta = newItem.quantity - oldItem.quantity;
      if (delta < 0) {
        final code = _productCodeFor(oldItem.productCode, oldItem.productName);
        negativeDeltasByCode[code] = (negativeDeltasByCode[code] ?? 0) - delta;
      }
    }
    for (final entry in negativeDeltasByCode.entries) {
      final available = _stockByCode[entry.key]?.quantity ?? 0;
      if (available < entry.value) {
        throw InventoryException(
          'Cannot reduce inbound quantity because stock has already been shipped.',
        );
      }
    }

    final now = DateTime.now();
    for (var itemIndex = 0; itemIndex < current.items.length; itemIndex += 1) {
      final oldItem = current.items[itemIndex];
      final newItem = items[itemIndex];
      final delta = newItem.quantity - oldItem.quantity;
      if (delta == 0) {
        continue;
      }
      final code = _productCodeFor(oldItem.productCode, oldItem.productName);
      _increaseStock(code, oldItem.productName, delta);
      _ledger.add(
        StockLedgerEntry(
          id: _nextId('lg'),
          productCode: code,
          productName: oldItem.productName.trim(),
          delta: delta,
          reason: LedgerReason.inbound,
          sourceId: receiptId,
          createdAt: now,
        ),
      );
    }

    final updated = InboundReceipt(
      id: current.id,
      trackingNumber: current.trackingNumber,
      createdAt: current.createdAt,
      items: List.unmodifiable(items),
      isSettled: current.isSettled,
      ocrStatus: current.ocrStatus,
      imagePath: current.imagePath,
    );
    _inboundReceipts[index] = updated;
    return updated;
  }

  void deleteInboundReceipt(String receiptId) {
    final index = _inboundReceipts.indexWhere((r) => r.id == receiptId);
    if (index < 0) {
      throw InventoryException('Inbound receipt not found.');
    }
    final receipt = _inboundReceipts[index];
    for (final item in receipt.items) {
      final code = _productCodeFor(item.productCode, item.productName);
      final available = _stockByCode[code]?.quantity ?? 0;
      if (available < item.quantity) {
        throw InventoryException(
          'Cannot delete inbound receipt because stock has already been shipped.',
        );
      }
    }
    for (final item in receipt.items) {
      final code = _productCodeFor(item.productCode, item.productName);
      _increaseStock(code, item.productName, -item.quantity);
    }
    _ledger.removeWhere(
      (entry) =>
          entry.reason == LedgerReason.inbound && entry.sourceId == receiptId,
    );
    _inboundReceipts.removeAt(index);
  }

  OutboundOrder confirmOutbound({
    required List<OutboundItem> items,
    List<String> imagePaths = const [],
    String? note,
  }) {
    if (items.isEmpty) {
      throw InventoryException('Outbound items are required.');
    }
    for (final item in items) {
      _validateOutboundItem(item);
      final available = _stockByCode[item.productCode]?.quantity ?? 0;
      if (available < item.quantity) {
        throw InventoryException(
          'Insufficient stock for ${item.productName}: $available available.',
        );
      }
    }

    final now = DateTime.now();
    final order = OutboundOrder(
      id: _nextId('out'),
      createdAt: now,
      items: List.unmodifiable(items),
      imagePaths: List.unmodifiable(
        imagePaths.map((path) => path.trim()).where((path) => path.isNotEmpty),
      ),
      note: note,
    );

    for (final item in items) {
      _increaseStock(item.productCode, item.productName, -item.quantity);
      _ledger.add(
        StockLedgerEntry(
          id: _nextId('lg'),
          productCode: item.productCode,
          productName: item.productName.trim(),
          delta: -item.quantity,
          reason: LedgerReason.outbound,
          sourceId: order.id,
          createdAt: now,
        ),
      );
    }
    _outboundOrders.add(order);
    return order;
  }

  List<InboundReceipt> searchInbound({bool? isSettled, String? keyword}) {
    final query = keyword?.trim().toLowerCase();
    return _inboundReceipts.where((receipt) {
      final matchesSettlement =
          isSettled == null || receipt.isSettled == isSettled;
      final matchesKeyword = query == null ||
          query.isEmpty ||
          receipt.trackingNumber.toLowerCase().contains(query) ||
          receipt.items.any(
            (item) => item.productName.toLowerCase().contains(query),
          );
      return matchesSettlement && matchesKeyword;
    }).toList(growable: false);
  }

  void _validateInboundItem(InboundDraftItem item) {
    if (item.productName.trim().isEmpty) {
      throw InventoryException('Product name is required.');
    }
    if (item.quantity <= 0) {
      throw InventoryException('Inbound quantity must be positive.');
    }
  }

  void _validateOutboundItem(OutboundItem item) {
    if (item.productCode.trim().isEmpty || item.productName.trim().isEmpty) {
      throw InventoryException('Outbound product is required.');
    }
    if (item.quantity <= 0) {
      throw InventoryException('Outbound quantity must be positive.');
    }
  }

  void _increaseStock(String code, String name, int delta) {
    final current = _stockByCode[code];
    final nextQuantity = (current?.quantity ?? 0) + delta;
    if (nextQuantity < 0) {
      throw InventoryException('Stock cannot be negative.');
    }
    _stockByCode[code] = WarehouseStock(
      productCode: code,
      productName: name.trim(),
      quantity: nextQuantity,
    );
  }

  String _productCodeFor(String? code, String name) {
    final normalizedCode = code?.trim();
    if (normalizedCode != null && normalizedCode.isNotEmpty) {
      return normalizedCode.toUpperCase();
    }
    return 'NAME:${name.trim().toLowerCase()}';
  }

  String _nextId(String prefix) {
    _sequence += 1;
    return '$prefix-${_sequence.toString().padLeft(6, '0')}';
  }
}
