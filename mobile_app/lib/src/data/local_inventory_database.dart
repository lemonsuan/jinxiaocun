import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../application/inventory_service.dart';
import '../domain/models.dart';
import '../domain/ocr_settings.dart';
import '../domain/tracking_number_rules.dart';
import 'local_database_schema.dart';

class LocalInventoryDatabase {
  static const String _backupFormat = 'inventory_mobile_app_backup';
  static const int _backupVersion = 1;
  static const List<String> _backupTables = [
    'products',
    'inbound_receipts',
    'inbound_items',
    'outbound_orders',
    'outbound_items',
    'outbound_attachments',
    'stock_ledger',
    'warehouse_stock',
    'ocr_results',
    'app_settings',
  ];
  static const List<String> _clearTables = [
    'app_settings',
    'ocr_results',
    'inbound_items',
    'outbound_items',
    'outbound_attachments',
    'stock_ledger',
    'warehouse_stock',
    'inbound_receipts',
    'outbound_orders',
    'products',
  ];
  static const String _ocrRowMergeToleranceKey = 'ocr_row_merge_tolerance';
  static const String _geminiApiKey = 'gemini_api_key';
  static const String _geminiApiUrl = 'gemini_api_url';
  static const String _geminiModelKey = 'gemini_model';

  Database? _database;

  Future<void> open() async {
    if (_database != null) {
      return;
    }
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = path.join(directory.path, 'inventory_app.db');
    _database = await openDatabase(
      dbPath,
      version: LocalDatabaseSchema.version,
      onCreate: (db, version) async {
        for (final statement in LocalDatabaseSchema.createStatements) {
          await db.execute(statement);
        }
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        for (var version = oldVersion + 1;
            version <= newVersion;
            version += 1) {
          for (final statement
              in LocalDatabaseSchema.migrationStatements[version] ??
                  const <String>[]) {
            await db.execute(statement);
          }
        }
      },
    );
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  Future<double> loadOcrRowMergeTolerance() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_ocrRowMergeToleranceKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return OcrSettings.defaultRowMergeTolerance;
    }
    return OcrSettings.normalizeRowMergeTolerance(
      double.tryParse(rows.single['value']! as String),
    );
  }

  Future<void> saveOcrRowMergeTolerance(double value) async {
    final normalized = OcrSettings.normalizeRowMergeTolerance(value);
    await _db.insert(
      'app_settings',
      {
        'key': _ocrRowMergeToleranceKey,
        'value': normalized.toStringAsFixed(2),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadGeminiApiKey() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_geminiApiKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveGeminiApiKey(String value) async {
    await _db.insert(
      'app_settings',
      {
        'key': _geminiApiKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadGeminiApiUrl() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_geminiApiUrl],
      limit: 1,
    );
    if (rows.isEmpty) {
      return 'https://generativelanguage.googleapis.com';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveGeminiApiUrl(String value) async {
    await _db.insert(
      'app_settings',
      {
        'key': _geminiApiUrl,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadGeminiModel() async {
    final rows = await _db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_geminiModelKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveGeminiModel(String value) async {
    await _db.insert(
      'app_settings',
      {
        'key': _geminiModelKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Uint8List> exportBackupBytes() async {
    final tableRows = <String, List<Map<String, Object?>>>{};
    for (final table in _backupTables) {
      tableRows[table] = await _db.query(table);
    }

    final images = <Map<String, String>>[];
    final exportedImagePaths = <String>{};
    for (final row in tableRows['inbound_receipts'] ?? const []) {
      final imagePath = row['image_path'];
      if (imagePath is! String ||
          imagePath.isEmpty ||
          exportedImagePaths.contains(imagePath)) {
        continue;
      }
      final file = File(imagePath);
      if (!file.existsSync()) {
        continue;
      }
      exportedImagePaths.add(imagePath);
      final bytes = await file.readAsBytes();
      images.add({
        'originalPath': imagePath,
        'fileName': path.basename(imagePath),
        'base64': base64Encode(bytes),
      });
    }
    for (final row in tableRows['outbound_attachments'] ?? const []) {
      final imagePath = row['image_path'];
      if (imagePath is! String ||
          imagePath.isEmpty ||
          exportedImagePaths.contains(imagePath)) {
        continue;
      }
      final file = File(imagePath);
      if (!file.existsSync()) {
        continue;
      }
      exportedImagePaths.add(imagePath);
      final bytes = await file.readAsBytes();
      images.add({
        'originalPath': imagePath,
        'fileName': path.basename(imagePath),
        'base64': base64Encode(bytes),
      });
    }

    final backup = <String, Object?>{
      'format': _backupFormat,
      'version': _backupVersion,
      'schemaVersion': LocalDatabaseSchema.version,
      'exportedAt': DateTime.now().toIso8601String(),
      'tables': tableRows,
      'images': images,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(backup)));
  }

  Future<void> importBackupBytes(Uint8List bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw InventoryException('Invalid backup file.');
    }
    if (decoded['format'] != _backupFormat ||
        decoded['version'] != _backupVersion) {
      throw InventoryException('Unsupported backup file.');
    }
    final schemaVersion = decoded['schemaVersion'];
    if (schemaVersion is! int || schemaVersion > LocalDatabaseSchema.version) {
      throw InventoryException('Backup schema is newer than this app.');
    }
    final tables = decoded['tables'];
    if (tables is! Map) {
      throw InventoryException('Invalid backup tables.');
    }

    final imagePathMap = await _restoreBackupImages(decoded['images']);
    await _db.transaction((txn) async {
      for (final table in _clearTables) {
        await txn.delete(table);
      }
      for (final table in _backupTables) {
        for (final row in _backupRows(tables, table)) {
          await txn.insert(
            table,
            _normalizeBackupRow(table, row, imagePathMap),
          );
        }
      }
    });
  }

  Future<List<WarehouseStock>> loadStockTotals() async {
    final rows = await _db.query(
      'warehouse_stock',
      orderBy: 'product_name COLLATE NOCASE ASC',
    );
    return rows.map((row) {
      return WarehouseStock(
        productCode: row['product_code']! as String,
        productName: row['product_name']! as String,
        quantity: row['quantity']! as int,
      );
    }).toList(growable: false);
  }

  Future<List<InboundReceipt>> loadInboundHistory() async {
    final receiptRows = await _db.query(
      'inbound_receipts',
      orderBy: 'created_at DESC',
    );
    final receipts = <InboundReceipt>[];
    for (final row in receiptRows) {
      final receiptId = row['id']! as String;
      final itemRows = await _db.query(
        'inbound_items',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
        orderBy: 'id ASC',
      );
      receipts.add(
        InboundReceipt(
          id: receiptId,
          trackingNumber: row['tracking_number']! as String,
          sellerOrderNumber: row['seller_order_number'] as String?,
          rebateOrderNumber: row['rebate_order_number'] as String?,
          createdAt: DateTime.parse(row['created_at']! as String),
          items: itemRows.map(_inboundItemFromRow).toList(growable: false),
          isSettled: (row['is_settled']! as int) == 1,
          ocrStatus: _ocrStatusFromName(row['ocr_status']! as String),
          imagePath: row['image_path'] as String?,
        ),
      );
    }
    return receipts;
  }

  Future<List<OutboundOrder>> loadOutboundHistory() async {
    final orderRows = await _db.query(
      'outbound_orders',
      orderBy: 'created_at DESC',
    );
    final orders = <OutboundOrder>[];
    for (final row in orderRows) {
      final orderId = row['id']! as String;
      final itemRows = await _db.query(
        'outbound_items',
        where: 'order_id = ?',
        whereArgs: [orderId],
        orderBy: 'id ASC',
      );
      final attachmentRows = await _db.query(
        'outbound_attachments',
        where: 'order_id = ?',
        whereArgs: [orderId],
        orderBy: 'id ASC',
      );
      orders.add(
        OutboundOrder(
          id: orderId,
          createdAt: DateTime.parse(row['created_at']! as String),
          items: itemRows.map(_outboundItemFromRow).toList(growable: false),
          imagePaths: attachmentRows
              .map((row) => row['image_path']! as String)
              .toList(growable: false),
          logisticsNumber: row['logistics_number'] as String?,
          note: row['note'] as String?,
        ),
      );
    }
    return orders;
  }

  Future<InboundReceipt> confirmInbound({
    required String trackingNumber,
    required List<InboundDraftItem> items,
    String? sellerOrderNumber,
    String? rebateOrderNumber,
    String? imagePath,
    bool isSettled = false,
  }) async {
    final normalizedTracking = trackingNumber.trim();
    final normalizedSellerOrder = _optionalText(sellerOrderNumber);
    final normalizedRebateOrder = _optionalText(rebateOrderNumber);
    if (normalizedTracking.isEmpty) {
      throw InventoryException('Tracking number is required.');
    }
    if (items.isEmpty &&
        !allowsEmptyInboundItemsForTracking(normalizedTracking)) {
      throw InventoryException('Inbound items are required.');
    }
    for (final item in items) {
      _validateInboundItem(item);
    }

    final now = DateTime.now();
    final receiptId = _nextId('in');
    try {
      await _db.transaction((txn) async {
        await txn.insert('inbound_receipts', {
          'id': receiptId,
          'tracking_number': normalizedTracking,
          'seller_order_number': normalizedSellerOrder,
          'rebate_order_number': normalizedRebateOrder,
          'image_path': imagePath,
          'ocr_status': OcrStatus.confirmed.name,
          'is_settled': isSettled ? 1 : 0,
          'created_at': now.toIso8601String(),
        });
        for (var index = 0; index < items.length; index += 1) {
          final item = items[index];
          final code = _productCodeFor(item.productCode, item.productName);
          await _upsertProduct(txn, code, item.productName, now);
          await txn.insert('inbound_items', {
            'id': '$receiptId-item-$index',
            'receipt_id': receiptId,
            'product_code': code,
            'product_name': item.productName.trim(),
            'quantity': item.quantity,
            'purchase_price': item.purchasePrice,
            'sale_price': item.salePrice,
          });
          await _increaseStock(txn, code, item.productName, item.quantity);
          await _insertLedger(
            txn,
            productCode: code,
            productName: item.productName,
            delta: item.quantity,
            reason: LedgerReason.inbound,
            sourceId: receiptId,
            createdAt: now,
          );
        }
      });
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw InventoryException('Tracking number already exists.');
      }
      rethrow;
    }

    return InboundReceipt(
      id: receiptId,
      trackingNumber: normalizedTracking,
      sellerOrderNumber: normalizedSellerOrder,
      rebateOrderNumber: normalizedRebateOrder,
      createdAt: now,
      items: List.unmodifiable(items),
      isSettled: isSettled,
      ocrStatus: OcrStatus.confirmed,
      imagePath: imagePath,
    );
  }

  Future<void> setReceiptSettled(String receiptId, bool isSettled) async {
    final count = await _db.update(
      'inbound_receipts',
      {'is_settled': isSettled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [receiptId],
    );
    if (count == 0) {
      throw InventoryException('Inbound receipt not found.');
    }
  }

  Future<void> updateInboundReceiptItems(
    String receiptId,
    List<InboundDraftItem> items,
  ) async {
    for (final item in items) {
      _validateInboundItem(item);
    }

    final now = DateTime.now();
    await _db.transaction((txn) async {
      final receiptRows = await txn.query(
        'inbound_receipts',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [receiptId],
        limit: 1,
      );
      if (receiptRows.isEmpty) {
        throw InventoryException('Inbound receipt not found.');
      }

      final itemRows = await txn.query(
        'inbound_items',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
        orderBy: 'id ASC',
      );
      if (itemRows.length != items.length) {
        throw InventoryException(
            'Inbound receipt items changed. Refresh first.');
      }

      final negativeDeltasByCode = <String, int>{};
      for (var index = 0; index < itemRows.length; index += 1) {
        final row = itemRows[index];
        final oldQuantity = row['quantity']! as int;
        final newQuantity = items[index].quantity;
        final delta = newQuantity - oldQuantity;
        if (delta < 0) {
          final code = row['product_code']! as String;
          negativeDeltasByCode[code] =
              (negativeDeltasByCode[code] ?? 0) - delta;
        }
      }
      for (final entry in negativeDeltasByCode.entries) {
        final available = await _stockFor(txn, entry.key);
        if (available < entry.value) {
          throw InventoryException(
            'Cannot reduce inbound quantity because stock has already been shipped.',
          );
        }
      }

      for (var index = 0; index < itemRows.length; index += 1) {
        final row = itemRows[index];
        final oldQuantity = row['quantity']! as int;
        final newQuantity = items[index].quantity;
        final delta = newQuantity - oldQuantity;
        if (delta == 0) {
          continue;
        }
        final code = row['product_code']! as String;
        final name = row['product_name']! as String;
        await txn.update(
          'inbound_items',
          {'quantity': newQuantity},
          where: 'id = ?',
          whereArgs: [row['id']! as String],
        );
        await _increaseStock(txn, code, name, delta);
        await _insertLedger(
          txn,
          productCode: code,
          productName: name,
          delta: delta,
          reason: LedgerReason.inbound,
          sourceId: receiptId,
          createdAt: now,
        );
      }
    });
  }

  Future<void> deleteInboundReceipt(String receiptId) async {
    await _db.transaction((txn) async {
      final receiptRows = await txn.query(
        'inbound_receipts',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [receiptId],
        limit: 1,
      );
      if (receiptRows.isEmpty) {
        throw InventoryException('Inbound receipt not found.');
      }

      final itemRows = await txn.query(
        'inbound_items',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
      );
      for (final row in itemRows) {
        final code = row['product_code']! as String;
        final quantity = row['quantity']! as int;
        final available = await _stockFor(txn, code);
        if (available < quantity) {
          throw InventoryException(
            'Cannot delete inbound receipt because stock has already been shipped.',
          );
        }
      }
      for (final row in itemRows) {
        await _increaseStock(
          txn,
          row['product_code']! as String,
          row['product_name']! as String,
          -(row['quantity']! as int),
        );
      }

      await txn.delete(
        'stock_ledger',
        where: 'source_id = ? AND reason = ?',
        whereArgs: [receiptId, LedgerReason.inbound.name],
      );
      await txn.delete(
        'ocr_results',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
      );
      await txn.delete(
        'inbound_items',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
      );
      await txn.delete(
        'inbound_receipts',
        where: 'id = ?',
        whereArgs: [receiptId],
      );
    });
  }

  Future<OutboundOrder> confirmOutbound({
    required List<OutboundItem> items,
    List<String> imagePaths = const [],
    String? logisticsNumber,
    String? note,
  }) async {
    if (items.isEmpty) {
      throw InventoryException('Outbound items are required.');
    }
    for (final item in items) {
      _validateOutboundItem(item);
    }

    final now = DateTime.now();
    final orderId = _nextId('out');
    final normalizedImagePaths = imagePaths
        .map((imagePath) => imagePath.trim())
        .where((imagePath) => imagePath.isNotEmpty)
        .toList(growable: false);
    final normalizedLogisticsNumber = _optionalText(logisticsNumber);
    await _db.transaction((txn) async {
      for (final item in items) {
        final available = await _stockFor(txn, item.productCode);
        if (available < item.quantity) {
          throw InventoryException(
            'Insufficient stock for ${item.productName}: $available available.',
          );
        }
      }
      await txn.insert('outbound_orders', {
        'id': orderId,
        'logistics_number': normalizedLogisticsNumber,
        'note': note,
        'created_at': now.toIso8601String(),
      });
      for (var index = 0; index < normalizedImagePaths.length; index += 1) {
        await txn.insert('outbound_attachments', {
          'id': '$orderId-attachment-$index',
          'order_id': orderId,
          'image_path': normalizedImagePaths[index],
          'created_at': now.toIso8601String(),
        });
      }
      for (var index = 0; index < items.length; index += 1) {
        final item = items[index];
        await txn.insert('outbound_items', {
          'id': '$orderId-item-$index',
          'order_id': orderId,
          'product_code': item.productCode,
          'product_name': item.productName.trim(),
          'quantity': item.quantity,
        });
        await _increaseStock(
            txn, item.productCode, item.productName, -item.quantity);
        await _insertLedger(
          txn,
          productCode: item.productCode,
          productName: item.productName,
          delta: -item.quantity,
          reason: LedgerReason.outbound,
          sourceId: orderId,
          createdAt: now,
        );
      }
    });

    return OutboundOrder(
      id: orderId,
      createdAt: now,
      items: List.unmodifiable(items),
      imagePaths: List.unmodifiable(normalizedImagePaths),
      logisticsNumber: normalizedLogisticsNumber,
      note: note,
    );
  }

  Future<Map<String, String>> _restoreBackupImages(Object? rawImages) async {
    if (rawImages == null) {
      return const {};
    }
    if (rawImages is! List) {
      throw InventoryException('Invalid backup images.');
    }
    final directory = await getApplicationDocumentsDirectory();
    final imageDirectory =
        Directory(path.join(directory.path, 'inbound_images'));
    await imageDirectory.create(recursive: true);

    final importedAt = DateTime.now().microsecondsSinceEpoch;
    final imagePathMap = <String, String>{};
    for (var index = 0; index < rawImages.length; index += 1) {
      final rawImage = rawImages[index];
      if (rawImage is! Map) {
        throw InventoryException('Invalid backup image.');
      }
      final originalPath = rawImage['originalPath'];
      final base64Value = rawImage['base64'];
      if (originalPath is! String ||
          originalPath.isEmpty ||
          base64Value is! String) {
        throw InventoryException('Invalid backup image.');
      }
      final rawFileName = rawImage['fileName'];
      final fileName = path.basename(
        rawFileName is String && rawFileName.isNotEmpty
            ? rawFileName
            : 'image_$index.jpg',
      );
      final targetPath = path.join(
        imageDirectory.path,
        'import_${importedAt}_${index}_$fileName',
      );
      try {
        await File(targetPath).writeAsBytes(
          base64Decode(base64Value),
          flush: true,
        );
      } on FormatException {
        throw InventoryException('Invalid backup image data.');
      }
      imagePathMap[originalPath] = targetPath;
    }
    return imagePathMap;
  }

  List<Map<String, Object?>> _backupRows(
      Map<dynamic, dynamic> tables, String table) {
    final rawRows = tables[table];
    if (rawRows == null) {
      return const [];
    }
    if (rawRows is! List) {
      throw InventoryException('Invalid backup table: $table.');
    }
    return rawRows.map((rawRow) {
      if (rawRow is! Map) {
        throw InventoryException('Invalid backup row: $table.');
      }
      return rawRow.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
    }).toList(growable: false);
  }

  Map<String, Object?> _normalizeBackupRow(
    String table,
    Map<String, Object?> row,
    Map<String, String> imagePathMap,
  ) {
    final normalized = Map<String, Object?>.from(row);
    if (table == 'inbound_receipts') {
      final oldImagePath = normalized['image_path'];
      normalized['image_path'] =
          oldImagePath is String ? imagePathMap[oldImagePath] : null;
    }
    if (table == 'outbound_attachments') {
      final oldImagePath = normalized['image_path'];
      normalized['image_path'] = oldImagePath is String
          ? imagePathMap[oldImagePath] ?? oldImagePath
          : '';
    }
    return normalized;
  }

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('Local database is not open.');
    }
    return database;
  }

  InboundDraftItem _inboundItemFromRow(Map<String, Object?> row) {
    return InboundDraftItem(
      productCode: row['product_code']! as String,
      productName: row['product_name']! as String,
      quantity: row['quantity']! as int,
      purchasePrice: row['purchase_price'] as double?,
      salePrice: row['sale_price'] as double?,
    );
  }

  OutboundItem _outboundItemFromRow(Map<String, Object?> row) {
    return OutboundItem(
      productCode: row['product_code']! as String,
      productName: row['product_name']! as String,
      quantity: row['quantity']! as int,
    );
  }

  OcrStatus _ocrStatusFromName(String name) {
    return OcrStatus.values.firstWhere(
      (status) => status.name == name,
      orElse: () => OcrStatus.needsReview,
    );
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

  Future<void> _upsertProduct(
    Transaction txn,
    String code,
    String name,
    DateTime now,
  ) async {
    await txn.insert(
      'products',
      {
        'code': code,
        'name': name.trim(),
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _increaseStock(
    Transaction txn,
    String code,
    String name,
    int delta,
  ) async {
    final current = await _stockFor(txn, code);
    final next = current + delta;
    if (next < 0) {
      throw InventoryException('Stock cannot be negative.');
    }
    await txn.insert(
      'warehouse_stock',
      {
        'product_code': code,
        'product_name': name.trim(),
        'quantity': next,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> _stockFor(Transaction txn, String code) async {
    final rows = await txn.query(
      'warehouse_stock',
      columns: ['quantity'],
      where: 'product_code = ?',
      whereArgs: [code],
      limit: 1,
    );
    if (rows.isEmpty) {
      return 0;
    }
    return rows.single['quantity']! as int;
  }

  Future<void> _insertLedger(
    Transaction txn, {
    required String productCode,
    required String productName,
    required int delta,
    required LedgerReason reason,
    required String sourceId,
    required DateTime createdAt,
  }) async {
    await txn.insert('stock_ledger', {
      'id': _nextId('lg'),
      'product_code': productCode,
      'product_name': productName.trim(),
      'delta': delta,
      'reason': reason.name,
      'source_id': sourceId,
      'created_at': createdAt.toIso8601String(),
    });
  }

  String _productCodeFor(String? code, String name) {
    final normalizedCode = code?.trim();
    if (normalizedCode != null && normalizedCode.isNotEmpty) {
      return normalizedCode.toUpperCase();
    }
    return 'NAME:${name.trim().toLowerCase()}';
  }

  String? _optionalText(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  String _nextId(String prefix) {
    return '$prefix-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<List<ProductCatalogItem>> loadProductCatalog() async {
    final rows = await _db.query(
      'products',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map((row) {
      return ProductCatalogItem(
        productCode: row['code']! as String,
        productName: row['name']! as String,
        defaultPurchasePrice: row['default_purchase_price'] as double?,
        defaultSalePrice: row['default_sale_price'] as double?,
      );
    }).toList(growable: false);
  }

  Future<void> updateProductPrice(
    String productCode, {
    double? purchasePrice,
    double? salePrice,
  }) async {
    await _db.update(
      'products',
      {
        'default_purchase_price': purchasePrice,
        'default_sale_price': salePrice,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'code = ?',
      whereArgs: [productCode],
    );
  }
}
