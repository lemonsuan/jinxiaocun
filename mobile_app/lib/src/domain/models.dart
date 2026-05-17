enum OcrStatus { pending, processing, needsReview, confirmed, failed }

enum LedgerReason { inbound, outbound }

class InboundDraftItem {
  const InboundDraftItem({
    required this.productName,
    required this.quantity,
    this.productCode,
    this.purchasePrice,
    this.salePrice,
    this.sourceText,
  });

  final String? productCode;
  final String productName;
  final int quantity;
  final double? purchasePrice;
  final double? salePrice;
  final String? sourceText;

  InboundDraftItem copyWith({
    String? productCode,
    String? productName,
    int? quantity,
    double? purchasePrice,
    double? salePrice,
    String? sourceText,
  }) {
    return InboundDraftItem(
      productCode: productCode ?? this.productCode,
      productName: productName ?? this.productName,
      quantity: quantity ?? this.quantity,
      purchasePrice: purchasePrice ?? this.purchasePrice,
      salePrice: salePrice ?? this.salePrice,
      sourceText: sourceText ?? this.sourceText,
    );
  }
}

class InboundReceipt {
  const InboundReceipt({
    required this.id,
    required this.trackingNumber,
    required this.createdAt,
    required this.items,
    required this.isSettled,
    required this.ocrStatus,
    this.imagePath,
  });

  final String id;
  final String trackingNumber;
  final DateTime createdAt;
  final List<InboundDraftItem> items;
  final bool isSettled;
  final OcrStatus ocrStatus;
  final String? imagePath;
}

class OutboundItem {
  const OutboundItem({
    required this.productCode,
    required this.productName,
    required this.quantity,
  });

  final String productCode;
  final String productName;
  final int quantity;
}

class OutboundOrder {
  const OutboundOrder({
    required this.id,
    required this.createdAt,
    required this.items,
    this.imagePaths = const [],
    this.note,
  });

  final String id;
  final DateTime createdAt;
  final List<OutboundItem> items;
  final List<String> imagePaths;
  final String? note;
}

class StockLedgerEntry {
  const StockLedgerEntry({
    required this.id,
    required this.productCode,
    required this.productName,
    required this.delta,
    required this.reason,
    required this.sourceId,
    required this.createdAt,
  });

  final String id;
  final String productCode;
  final String productName;
  final int delta;
  final LedgerReason reason;
  final String sourceId;
  final DateTime createdAt;
}

class WarehouseStock {
  const WarehouseStock({
    required this.productCode,
    required this.productName,
    required this.quantity,
  });

  final String productCode;
  final String productName;
  final int quantity;
}
