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
    this.sellerOrderNumber,
    this.rebateOrderNumber,
    this.schemeNumber,
    this.imagePath,
  });

  final String id;
  final String trackingNumber;
  final String? sellerOrderNumber;
  final String? rebateOrderNumber;
  final String? schemeNumber;
  final DateTime createdAt;
  final List<InboundDraftItem> items;
  final bool isSettled;
  final OcrStatus ocrStatus;
  final String? imagePath;

  InboundReceipt copyWith({
    String? id,
    String? trackingNumber,
    String? sellerOrderNumber,
    String? rebateOrderNumber,
    String? schemeNumber,
    DateTime? createdAt,
    List<InboundDraftItem>? items,
    bool? isSettled,
    OcrStatus? ocrStatus,
    String? imagePath,
  }) {
    return InboundReceipt(
      id: id ?? this.id,
      trackingNumber: trackingNumber ?? this.trackingNumber,
      sellerOrderNumber: sellerOrderNumber ?? this.sellerOrderNumber,
      rebateOrderNumber: rebateOrderNumber ?? this.rebateOrderNumber,
      schemeNumber: schemeNumber ?? this.schemeNumber,
      createdAt: createdAt ?? this.createdAt,
      items: items ?? this.items,
      isSettled: isSettled ?? this.isSettled,
      ocrStatus: ocrStatus ?? this.ocrStatus,
      imagePath: imagePath ?? this.imagePath,
    );
  }
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
    this.logisticsNumber,
    this.note,
  });

  final String id;
  final DateTime createdAt;
  final List<OutboundItem> items;
  final List<String> imagePaths;
  final String? logisticsNumber;
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

class ProductCatalogItem {
  const ProductCatalogItem({
    required this.productCode,
    required this.productName,
    this.defaultPurchasePrice,
    this.defaultSalePrice,
  });

  final String productCode;
  final String productName;
  final double? defaultPurchasePrice;
  final double? defaultSalePrice;

  ProductCatalogItem copyWith({
    String? productCode,
    String? productName,
    double? defaultPurchasePrice,
    double? defaultSalePrice,
  }) {
    return ProductCatalogItem(
      productCode: productCode ?? this.productCode,
      productName: productName ?? this.productName,
      defaultPurchasePrice: defaultPurchasePrice ?? this.defaultPurchasePrice,
      defaultSalePrice: defaultSalePrice ?? this.defaultSalePrice,
    );
  }
}

