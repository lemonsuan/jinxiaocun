import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive_io.dart';
import 'package:sqflite/sqflite.dart';
import 'package:image/image.dart' as img;

import '../application/inventory_service.dart';
import '../application/ocr_access_policy.dart';
import '../domain/models.dart';
import '../domain/workspace_profile.dart';
import '../domain/express_capture.dart';
import '../domain/ocr_settings.dart';
import '../domain/tracking_number_rules.dart';
import 'local_database_schema.dart';
import 'sync_database_schema.dart';

part 'local_inventory_sync.dart';
part 'local_inventory_scope.dart';
part 'local_inventory_workspaces.dart';

/// 本地离线优先 SQLite 仓储数据库服务。
///
/// 架构特性：
/// 1. 多租户沙盒物理隔离：每个店铺工作区（或本地未绑定模式）对应独立的本地 SQLite 文件；
/// 2. 离线全功能闭环：商品检索、扫码核验、批次出入库、单据草稿、快照暂存均在本地零延迟完成；
/// 3. 双模数据防爆备份：
///    - 纯业务数据备份：剥离照片物理文件，毫秒级导出，几百KB，永不卡顿；
///    - 流式 ZIP 归档备份：分块流式直接归档全部单据实物照片，内存稳定低于 10MB，规避 Base64 内存溢出（OOM）；
///    - 导入还原：双向自适应识别 JSON / ZIP，自动解压照片沙盒并智能修复物理路径映射；
/// 4. 离线增量同步 (Sync v2)：本地记录单据修订版本号、操作唯一键，支持差量双向推送与拉取。
class LocalInventoryDatabase {
  LocalInventoryDatabase(
      {Database? database, Directory? directory, DatabaseFactory? factory})
      : _database = database,
        _directory = directory,
        _factory = factory;
  final Directory? _directory;
  final DatabaseFactory? _factory;
  Database? _configuration;
  String? _openedScope;
  bool _openedOnline = false;
  bool _syncReady = false;
  Object get processingScope => _database ?? this;
  Database get _settings => _configuration ?? _db;
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
  static const String _authModeKey = 'auth_mode';
  static const String _syncServerUrlKey = 'sync_server_url';
  static const String _authTokenKey = 'auth_token';
  static const String _activeShopIdKey = 'active_shop_id';
  static const String _activeShopNameKey = 'active_shop_name';

  Database? _database;

  Future<void> open() async {
    if (_database != null) {
      return;
    }
    await _openScoped();
  }

  Future<void> close() async {
    await _database?.close();
    await _configuration?.close();
    _configuration = null;
    _syncReady = false;
    _database = null;
  }

  OcrAccessPolicy get ocrPolicy => OcrAccessPolicy.forDevice(
      _settings.path == ':memory:' ? _settings : _settings.path,
      read: _readOcrEnabled,
      write: _writeOcrEnabled);

  Future<bool> _readOcrEnabled() async {
    final rows = await _settings.query('app_settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['ocr_enabled'],
        limit: 1);
    return rows.isEmpty || rows.single['value'] == 'true';
  }

  Future<void> _writeOcrEnabled(bool enabled) async {
    await _settings.insert(
        'app_settings',
        {
          'key': 'ocr_enabled',
          'value': enabled.toString(),
          'updated_at': DateTime.now().toIso8601String()
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> loadOcrEnabled() async {
    final policy = ocrPolicy;
    await policy.load();
    return policy.enabled;
  }

  Future<void> saveOcrEnabled(bool enabled) => ocrPolicy.setEnabled(enabled);

  Future<double> loadOcrRowMergeTolerance() async {
    final rows = await _settings.query(
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
    await _settings.insert(
      'app_settings',
      {
        'key': _ocrRowMergeToleranceKey,
        'value': normalized.toStringAsFixed(2),
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadAuthMode() async {
    final rows = await _settings.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_authModeKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveAuthMode(String value) async {
    await _settings.insert(
      'app_settings',
      {
        'key': _authModeKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadSyncServerUrl() async {
    final rows = await _settings.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_syncServerUrlKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return 'http://10.0.2.2:8000';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveSyncServerUrl(String value) async {
    await _settings.insert(
      'app_settings',
      {
        'key': _syncServerUrlKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadAuthToken() async {
    final rows = await _settings.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_authTokenKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveAuthToken(String value) async {
    await _settings.insert(
      'app_settings',
      {
        'key': _authTokenKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearAuthCredentials() async {
    await _settings.delete(
      'app_settings',
      where: 'key = ? OR key = ? OR key = ? OR key = ?',
      whereArgs: [
        _authModeKey,
        _authTokenKey,
        _activeShopIdKey,
        _activeShopNameKey
      ],
    );
  }

  Future<String> loadActiveShopId() async {
    final rows = await _settings.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_activeShopIdKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveActiveShopId(String value) async {
    await _settings.insert(
      'app_settings',
      {
        'key': _activeShopIdKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> loadActiveShopName() async {
    final rows = await _settings.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_activeShopNameKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return '';
    }
    return rows.single['value']! as String;
  }

  Future<void> saveActiveShopName(String value) async {
    await _settings.insert(
      'app_settings',
      {
        'key': _activeShopNameKey,
        'value': value,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }


  Future<Uint8List> exportBackupBytes({bool includeImages = true}) async {
    final tableRows = <String, List<Map<String, Object?>>>{};
    for (final table in _backupTables) {
      tableRows[table] = table == 'app_settings'
          ? await _db.query(table, where: "key LIKE 'express_image_job:%'")
          : await _backupBusinessRows(table);
    }

    final images = <Map<String, String>>[];
    if (includeImages) {
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
    }

    final backup = <String, Object?>{
      'format': _backupFormat,
      'version': _backupVersion,
      'schemaVersion': LocalDatabaseSchema.version,
      'exportedAt': DateTime.now().toIso8601String(),
      'tables': tableRows,
      'images': images,
      'includeImages': includeImages,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(backup)));
  }

  /// 稳妥的全量 ZIP 备份：以流式方式打包核心数据库表和物理单据照片，杜绝内存爆满卡死
  Future<void> exportBackupZipFile(
    File destinationZipFile, {
    void Function(int current, int total, String status)? onProgress,
  }) async {
    onProgress?.call(0, 1, '正在导出核心数据库表...');
    final jsonBytes = await exportBackupBytes(includeImages: false);

    final tempDir = await getTemporaryDirectory();
    final tempJsonFile = File(path.join(tempDir.path,
        'backup_data_${DateTime.now().microsecondsSinceEpoch}.json'));
    await tempJsonFile.writeAsBytes(jsonBytes, flush: true);

    if (destinationZipFile.existsSync()) {
      destinationZipFile.deleteSync();
    }

    final encoder = ZipFileEncoder();
    encoder.create(destinationZipFile.path);
    encoder.addFile(tempJsonFile, 'backup_data.json');

    // 收集所有需要备份的实际存在的图片文件
    final imageFiles = <String, File>{}; // relativeName -> File
    final receiptRows = await _db.query('inbound_receipts');
    for (final row in receiptRows) {
      final imgPath = row['image_path'];
      if (imgPath is String && imgPath.isNotEmpty) {
        final f = File(imgPath);
        if (f.existsSync()) {
          final relName = path.basename(imgPath);
          imageFiles[relName] = f;
        }
      }
    }
    final outboundRows = await _db.query('outbound_attachments');
    for (final row in outboundRows) {
      final imgPath = row['image_path'];
      if (imgPath is String && imgPath.isNotEmpty) {
        final f = File(imgPath);
        if (f.existsSync()) {
          final relName = path.basename(imgPath);
          imageFiles[relName] = f;
        }
      }
    }

    final totalImages = imageFiles.length;
    int current = 0;
    for (final entry in imageFiles.entries) {
      current++;
      onProgress?.call(
          current, totalImages, '正在流式压缩单据照片 ($current/$totalImages)...');
      encoder.addFile(entry.value, 'images/${entry.key}');
    }

    onProgress?.call(totalImages, totalImages, '正在完成归档封装...');
    encoder.close();

    try {
      if (tempJsonFile.existsSync()) {
        tempJsonFile.deleteSync();
      }
    } catch (_) {}
  }

  /// 通用还原入口：自动识别 .zip 压缩包、纯数据 .json 以及旧版带 Base64 的 .json 备份
  Future<void> importBackupFromFile(File file) async {
    final lower = file.path.toLowerCase();
    if (lower.endsWith('.zip')) {
      await importBackupFromZip(file);
      return;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      await importBackupFromZip(file);
      return;
    }
    await importBackupBytes(bytes);
  }

  /// 从 ZIP 归档包中解压还原数据库与全部单据物理照片
  Future<void> importBackupFromZip(File zipFile) async {
    await _guardBackupRestore();
    final tempDir = await getTemporaryDirectory();
    final extractDir = Directory(path.join(
        tempDir.path, 'extract_${DateTime.now().microsecondsSinceEpoch}'));
    await extractDir.create(recursive: true);

    try {
      extractFileToDisk(zipFile.path, extractDir.path);

      final jsonFile = File(path.join(extractDir.path, 'backup_data.json'));
      if (!jsonFile.existsSync()) {
        throw InventoryException('压缩包内未找到数据库备份数据文件(backup_data.json)');
      }

      final jsonBytes = await jsonFile.readAsBytes();
      final decoded = jsonDecode(utf8.decode(jsonBytes));
      if (decoded is! Map) {
        throw InventoryException('Invalid backup data in zip.');
      }
      if (decoded['format'] != _backupFormat ||
          decoded['version'] != _backupVersion) {
        throw InventoryException('Unsupported backup format in zip.');
      }
      final schemaVersion = decoded['schemaVersion'];
      if (schemaVersion is! int ||
          schemaVersion > LocalDatabaseSchema.version) {
        throw InventoryException('Backup schema is newer than this app.');
      }
      final tables = decoded['tables'];
      if (tables is! Map) {
        throw InventoryException('Invalid backup tables in zip.');
      }

      // 将压缩包内的 images/ 提取并迁移到应用本地存储目录
      final appDocDir = _directory ?? await getApplicationDocumentsDirectory();
      final targetImageDir =
          Directory(path.join(appDocDir.path, 'inbound_images'));
      await targetImageDir.create(recursive: true);

      final imagePathMap = <String, String>{};
      final zipImagesDir = Directory(path.join(extractDir.path, 'images'));
      if (zipImagesDir.existsSync()) {
        final files = zipImagesDir.listSync();
        final timestamp = DateTime.now().microsecondsSinceEpoch;
        for (var i = 0; i < files.length; i++) {
          final entity = files[i];
          if (entity is File) {
            final baseName = path.basename(entity.path);
            final targetPath = path.join(
                targetImageDir.path, 'import_${timestamp}_${i}_$baseName');
            await entity.copy(targetPath);
            imagePathMap[baseName] = targetPath;
          }
        }
      }

      // 事务恢复数据表
      await _db.transaction((txn) async {
        for (final table in _clearTables) {
          await txn.delete(table);
        }
        await _resetRestoredSync(txn);
        for (final table in _backupTables) {
          for (final row in _backupRows(tables, table)) {
            if (table == 'app_settings' &&
                !(row['key'] as String? ?? '')
                    .startsWith('express_image_job:')) {
              continue;
            }
            await txn.insert(
              table,
              _normalizeBackupRowWithBaseName(table, row, imagePathMap),
            );
          }
        }
      });
    } finally {
      try {
        if (extractDir.existsSync()) {
          extractDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> importBackupBytes(Uint8List bytes) async {
    await _guardBackupRestore();
    // 自动侦测：如果传入的是 ZIP 文件字节流，自动转至 ZIP 解压恢复
    if (bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      final tempDir = await getTemporaryDirectory();
      final tempZip = File(path.join(tempDir.path,
          'temp_restore_${DateTime.now().microsecondsSinceEpoch}.zip'));
      await tempZip.writeAsBytes(bytes, flush: true);
      try {
        await importBackupFromZip(tempZip);
      } finally {
        try {
          if (tempZip.existsSync()) tempZip.deleteSync();
        } catch (_) {}
      }
      return;
    }

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
      await _resetRestoredSync(txn);
      for (final table in _backupTables) {
        for (final row in _backupRows(tables, table)) {
          if (table == 'app_settings' &&
              !(row['key'] as String? ?? '').startsWith('express_image_job:')) {
            continue;
          }
          await txn.insert(
            table,
            _normalizeBackupRow(table, row, imagePathMap),
          );
        }
      }
    });
  }

  Future<List<WarehouseStock>> loadStockTotals() async {
    await _ensureSync();
    final rows = await _db.query(
      'warehouse_stock',
      where:
          "product_code NOT IN (SELECT id FROM sync_hidden WHERE kind = 'stock')",
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
    await _ensureSync();
    final receiptRows = await _db.query(
      'inbound_receipts',
      where:
          "id NOT IN (SELECT id FROM sync_hidden WHERE kind = 'inbound' UNION SELECT id FROM sync_abandoned WHERE kind='inbound')",
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
          schemeNumber: row['scheme_number'] as String?,
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

  /// 轻量查询最近 [limit] 条入库单（不加载商品明细）
  Future<List<InboundReceipt>> loadRecentInboundReceipts(int limit) async {
    await _ensureSync();
    final receiptRows = await _db.query(
      'inbound_receipts',
      where:
          "id NOT IN (SELECT id FROM sync_hidden WHERE kind = 'inbound' UNION SELECT id FROM sync_abandoned WHERE kind='inbound')",
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return receiptRows
        .map((row) => InboundReceipt(
              id: row['id']! as String,
              trackingNumber: row['tracking_number']! as String,
              sellerOrderNumber: row['seller_order_number'] as String?,
              rebateOrderNumber: row['rebate_order_number'] as String?,
              schemeNumber: row['scheme_number'] as String?,
              createdAt: DateTime.parse(row['created_at']! as String),
              items: const [],
              isSettled: (row['is_settled']! as int) == 1,
              ocrStatus: _ocrStatusFromName(row['ocr_status']! as String),
              imagePath: row['image_path'] as String?,
            ))
        .toList();
  }

  Future<List<OutboundOrder>> loadOutboundHistory() async {
    await _ensureSync();
    final orderRows = await _db.query(
      'outbound_orders',
      where:
          "id NOT IN (SELECT id FROM sync_hidden WHERE kind = 'outbound' UNION SELECT id FROM sync_abandoned WHERE kind='outbound')",
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
    String? schemeNumber,
    String? imagePath,
    bool isSettled = false,
    OcrStatus ocrStatus = OcrStatus.confirmed,
    CaptureCrop? expressCrop,
    String? expressToken,
  }) async {
    final normalizedTracking = trackingNumber.trim();
    final normalizedSellerOrder = _optionalText(sellerOrderNumber);
    final normalizedRebateOrder = _optionalText(rebateOrderNumber);
    final normalizedScheme = _optionalText(schemeNumber);
    if (normalizedTracking.isEmpty) {
      throw InventoryException('Tracking number is required.');
    }
    if (items.isEmpty &&
        ocrStatus == OcrStatus.confirmed &&
        !allowsEmptyInboundItemsForTracking(normalizedTracking)) {
      throw InventoryException('Inbound items are required.');
    }
    for (final item in items) {
      _validateInboundItem(item);
    }

    final now = DateTime.now();
    final receiptId = _nextId('in');
    final resolvedItems = <InboundDraftItem>[];

    try {
      await _db.transaction((txn) async {
        await txn.insert('inbound_receipts', {
          'id': receiptId,
          'tracking_number': normalizedTracking,
          'seller_order_number': normalizedSellerOrder,
          'rebate_order_number': normalizedRebateOrder,
          'scheme_number': normalizedScheme,
          'image_path': imagePath,
          'ocr_status': ocrStatus.name,
          'is_settled': isSettled ? 1 : 0,
          'created_at': now.toIso8601String(),
        });

        if (expressToken != null && imagePath != null) {
          final job = ExpressImageJob(
              receiptId: receiptId,
              imagePath: imagePath,
              token: expressToken,
              crop: expressCrop ?? CaptureCrop.full);
          await txn.insert(
              'app_settings',
              {
                'key': job.settingKey,
                'value': job.encode(),
                'updated_at': now.toIso8601String()
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (var index = 0; index < items.length; index += 1) {
          final item = items[index];
          final code = _productCodeFor(item.productCode, item.productName);
          resolvedItems.add(item.copyWith(productCode: code));
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
      items: List.unmodifiable(resolvedItems),
      isSettled: isSettled,
      ocrStatus: ocrStatus,
      imagePath: imagePath,
    );
  }

  Future<void> updateInboundOcrResult({
    required String receiptId,
    required List<InboundDraftItem> items,
    required OcrStatus ocrStatus,
    String? sellerOrderNumber,
    String? expectedImagePath,
    String? processedImagePath,
    String? expectedExpressJobValue,
    void Function()? validateOcrPermit,
  }) async {
    final now = DateTime.now();
    await _db.transaction((txn) async {
      validateOcrPermit?.call();
      if (expectedExpressJobValue != null) {
        final jobs = await txn.query('app_settings',
            columns: ['value'],
            where: 'key = ?',
            whereArgs: ['express_image_job:$receiptId']);
        if (jobs.isEmpty || jobs.single['value'] != expectedExpressJobValue) {
          return;
        }
      }
      // 1. 防重幂等安全检查
      final receipts = await txn.query(
        'inbound_receipts',
        columns: ['ocr_status', 'seller_order_number', 'image_path'],
        where: 'id = ?',
        whereArgs: [receiptId],
      );
      if (receipts.isEmpty) {
        return; // 单据不存在，直接退出
      }
      if (expectedImagePath != null &&
          receipts.first['image_path'] != expectedImagePath) {
        return;
      }
      final currentStatus = receipts.first['ocr_status'] as String?;
      if (currentStatus != OcrStatus.pending.name &&
          currentStatus != OcrStatus.processing.name) {
        return; // 如果不是 pending/processing，说明已被处理过，为避免库存和台账重复累加，直接退出
      }

      // 2. 更新主表状态
      final updateValues = <String, Object?>{
        'ocr_status': ocrStatus.name,
        if (processedImagePath != null) 'image_path': processedImagePath,
      };
      if (expectedExpressJobValue != null && ocrStatus == OcrStatus.confirmed) {
        await txn.delete('app_settings',
            where: 'key = ?', whereArgs: ['express_image_job:$receiptId']);
      }
      // 如果提取出了订单号，且主表当前的订单号为空时才回填
      final currentSellerOrder =
          receipts.first['seller_order_number'] as String?;
      if ((currentSellerOrder == null || currentSellerOrder.trim().isEmpty) &&
          sellerOrderNumber != null &&
          sellerOrderNumber.trim().isNotEmpty) {
        updateValues['seller_order_number'] = sellerOrderNumber.trim();
      }
      await txn.update(
        'inbound_receipts',
        updateValues,
        where: 'id = ?',
        whereArgs: [receiptId],
      );

      // 3. 写入商品明细，并递增库存和台账记录
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
      validateOcrPermit?.call();
    });
  }

  /// Loads one durable job at a time; the backlog stays in SQLite, not RAM.
  Future<ExpressImageJob?> nextExpressImageJob() async {
    final rows = await _db.rawQuery('''SELECT s.key, s.value, r.id, r.image_path
      FROM app_settings s JOIN inbound_receipts r
      ON s.key = 'express_image_job:' || r.id
      WHERE r.ocr_status IN ('pending', 'processing')
      ORDER BY r.created_at ASC LIMIT 1''');
    if (rows.isEmpty) return null;
    final row = rows.single;
    try {
      final old = ExpressImageJob.decode(row['value'] as String);
      // Backup restore remaps receipt image paths; never use the old device path.
      if (old.receiptId != row['id'] || old.settingKey != row['key']) {
        throw const FormatException('Job identity mismatch');
      }
      final currentPath = row['image_path'] as String?;
      if (currentPath == null || currentPath.isEmpty) {
        throw const FormatException('Missing photo');
      }
      if (old.imagePath != currentPath) {
        final updated = ExpressImageJob(
            receiptId: row['id'] as String,
            imagePath: currentPath,
            token: '${DateTime.now().microsecondsSinceEpoch}',
            crop: old.crop);
        await _db.update('app_settings', {'value': updated.encode()},
            where: 'key = ? AND value = ?',
            whereArgs: [row['key'], row['value']]);
        return updated;
      }
      if (old.encode() != row['value']) {
        await _db.update('app_settings', {'value': old.encode()},
            where: 'key = ? AND value = ?',
            whereArgs: [row['key'], row['value']]);
      }
      return old;
    } catch (_) {
      await _db.update(
          'inbound_receipts', {'ocr_status': OcrStatus.failed.name},
          where: 'id = ? AND ocr_status IN (?, ?)',
          whereArgs: [
            row['id'],
            OcrStatus.pending.name,
            OcrStatus.processing.name
          ]);
      return nextExpressImageJob();
    }
  }

  Future<bool> isExpressImageJobCurrent(ExpressImageJob job) async {
    final rows = await _db.rawQuery('''SELECT r.id FROM inbound_receipts r
      JOIN app_settings s ON s.key = 'express_image_job:' || r.id
      WHERE r.id = ? AND r.image_path = ? AND s.value = ?
      AND r.ocr_status IN ('pending', 'processing') LIMIT 1''',
        [job.receiptId, job.imagePath, job.encode()]);
    return rows.isNotEmpty;
  }

  Future<bool> retryExpressImageJob(String receiptId) async {
    return _db.transaction((txn) async {
      final rows = await txn.query('inbound_receipts',
          where: 'id = ? AND ocr_status = ?',
          whereArgs: [receiptId, OcrStatus.failed.name]);
      final settings = await txn.query('app_settings',
          where: 'key = ?', whereArgs: ['express_image_job:$receiptId']);
      if (rows.isEmpty || settings.isEmpty) return false;
      CaptureCrop crop = CaptureCrop.full;
      try {
        final old = ExpressImageJob.decode(settings.single['value'] as String);
        if (old.receiptId == receiptId) crop = old.crop;
      } catch (_) {
        // Keep the full original when corrupt metadata cannot establish a safe crop.
      }
      final photo = rows.single['image_path'];
      if (photo is! String || photo.isEmpty) return false;
      final job = ExpressImageJob(
          receiptId: receiptId,
          imagePath: photo,
          token: '${DateTime.now().microsecondsSinceEpoch}',
          crop: crop);
      await txn.update('app_settings', {'value': job.encode()},
          where: 'key = ?', whereArgs: [job.settingKey]);
      await txn.update(
          'inbound_receipts', {'ocr_status': OcrStatus.pending.name},
          where: 'id = ?', whereArgs: [receiptId]);
      return true;
    });
  }

  Future<bool> isImagePathReferenced(String imagePath) async {
    final receipts = await _db.query('inbound_receipts',
        columns: ['id'],
        where: 'image_path = ?',
        whereArgs: [imagePath],
        limit: 1);
    if (receipts.isNotEmpty) return true;
    final attachments = await _db.query('outbound_attachments',
        columns: ['id'],
        where: 'image_path = ?',
        whereArgs: [imagePath],
        limit: 1);
    return attachments.isNotEmpty;
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
      await txn.delete('app_settings',
          where: 'key = ?', whereArgs: ['express_image_job:$receiptId']);
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
    if (await _isOnlineWorkspace()) {
      await _hide('inbound', receiptId);
      return;
    }
    await _db.transaction((txn) async {
      await txn.delete('app_settings',
          where: 'key = ?', whereArgs: ['express_image_job:$receiptId']);
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
    final directory = _directory ?? await getApplicationDocumentsDirectory();
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
      if (oldImagePath is String && oldImagePath.isNotEmpty) {
        normalized['image_path'] = imagePathMap[oldImagePath] ??
            (File(oldImagePath).existsSync() ? oldImagePath : null);
      } else {
        normalized['image_path'] = null;
      }
    }
    if (table == 'outbound_attachments') {
      final oldImagePath = normalized['image_path'];
      if (oldImagePath is String && oldImagePath.isNotEmpty) {
        normalized['image_path'] = imagePathMap[oldImagePath] ??
            (File(oldImagePath).existsSync() ? oldImagePath : '');
      } else {
        normalized['image_path'] = '';
      }
    }
    return normalized;
  }

  Map<String, Object?> _normalizeBackupRowWithBaseName(
    String table,
    Map<String, Object?> row,
    Map<String, String> imagePathMap,
  ) {
    final normalized = Map<String, Object?>.from(row);
    if (table == 'inbound_receipts') {
      final oldImagePath = normalized['image_path'];
      if (oldImagePath is String && oldImagePath.isNotEmpty) {
        final bName = path.basename(oldImagePath);
        normalized['image_path'] = imagePathMap[oldImagePath] ??
            imagePathMap[bName] ??
            (File(oldImagePath).existsSync() ? oldImagePath : null);
      } else {
        normalized['image_path'] = null;
      }
    }
    if (table == 'outbound_attachments') {
      final oldImagePath = normalized['image_path'];
      if (oldImagePath is String && oldImagePath.isNotEmpty) {
        final bName = path.basename(oldImagePath);
        normalized['image_path'] = imagePathMap[oldImagePath] ??
            imagePathMap[bName] ??
            (File(oldImagePath).existsSync() ? oldImagePath : '');
      } else {
        normalized['image_path'] = '';
      }
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
    return 'SCBH:${DateTime.now().microsecondsSinceEpoch}';
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
    await _ensureSync();
    final rows = await _db.query(
      'products',
      where: "code NOT IN (SELECT id FROM sync_hidden WHERE kind = 'product')",
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

  /// 使用 AI 识别后的新明细覆盖指定入库单，直接扣减旧明细库存并追加新明细库存与流水
  Future<void> _validateReceiptSnapshot(
      Transaction txn, InboundReceipt expected) async {
    final rows = await txn
        .query('inbound_receipts', where: 'id = ?', whereArgs: [expected.id]);
    final items = await txn.query('inbound_items',
        where: 'receipt_id = ?', whereArgs: [expected.id]);
    List<String> canonical(Iterable<Map<String, Object?>> values) => values
        .map((r) => jsonEncode([
              r['product_code'],
              r['product_name'],
              r['quantity'],
              (r['purchase_price'] as num?)?.toDouble(),
              (r['sale_price'] as num?)?.toDouble()
            ]))
        .toList()
      ..sort();
    final oldItems = canonical(expected.items.map((i) => <String, Object?>{
          'product_code': i.productCode,
          'product_name': i.productName,
          'quantity': i.quantity,
          'purchase_price': i.purchasePrice,
          'sale_price': i.salePrice
        }));
    if (rows.isEmpty ||
        rows.single['image_path'] != expected.imagePath ||
        rows.single['ocr_status'] != expected.ocrStatus.name ||
        rows.single['tracking_number'] != expected.trackingNumber ||
        rows.single['seller_order_number'] != expected.sellerOrderNumber ||
        rows.single['rebate_order_number'] != expected.rebateOrderNumber ||
        rows.single['scheme_number'] != expected.schemeNumber ||
        rows.single['is_settled'] != (expected.isSettled ? 1 : 0) ||
        jsonEncode(canonical(items)) != jsonEncode(oldItems)) {
      throw InventoryException('单据或商品已被修改，本次识别结果未覆盖，请刷新后重试。');
    }
  }

  Future<void> overwriteInboundItems({
    required String receiptId,
    required List<InboundDraftItem> items,
    String? sellerOrderNumber,
    String? schemeNumber,
    required OcrStatus ocrStatus,
    void Function()? validateOcrPermit,
    InboundReceipt? expectedReceipt,
    String? replacementImagePath,
  }) async {
    final now = DateTime.now();
    await _db.transaction((txn) async {
      validateOcrPermit?.call();
      if (expectedReceipt != null) {
        await _validateReceiptSnapshot(txn, expectedReceipt);
      }
      await txn.delete('app_settings',
          where: 'key = ?', whereArgs: ['express_image_job:$receiptId']);
      // 1. 获取原入库单的创建时间，用于台账流水的生成
      final receiptRows = await txn.query(
        'inbound_receipts',
        columns: ['created_at'],
        where: 'id = ?',
        whereArgs: [receiptId],
        limit: 1,
      );
      final createdAt = receiptRows.isNotEmpty
          ? DateTime.parse(receiptRows.first['created_at']! as String)
          : now;

      // 2. 查出旧的明细数据
      final oldItems = await txn.query(
        'inbound_items',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
      );

      final affectedCodes = <String>{};

      // 3. 从库存中减去旧明细的识别数量
      for (final oldItem in oldItems) {
        final code = oldItem['product_code']! as String;
        final name = oldItem['product_name']! as String;
        final qty = oldItem['quantity']! as int;
        affectedCodes.add(code);

        await _increaseStockRaw(txn, code, name, -qty);
      }

      // 4. 清除旧明细和旧台账
      await txn.delete(
        'inbound_items',
        where: 'receipt_id = ?',
        whereArgs: [receiptId],
      );
      await txn.delete(
        'stock_ledger',
        where: 'source_id = ? AND reason = ?',
        whereArgs: [receiptId, LedgerReason.inbound.name],
      );

      // 5. 更新主表状态及相关单号
      final updateValues = <String, Object?>{
        'ocr_status': ocrStatus.name,
        if (replacementImagePath != null) 'image_path': replacementImagePath,
      };
      if (sellerOrderNumber != null && sellerOrderNumber.trim().isNotEmpty) {
        updateValues['seller_order_number'] = sellerOrderNumber.trim();
      }
      if (schemeNumber != null && schemeNumber.trim().isNotEmpty) {
        updateValues['scheme_number'] = schemeNumber.trim();
      }
      await txn.update(
        'inbound_receipts',
        updateValues,
        where: 'id = ?',
        whereArgs: [receiptId],
      );

      // 6. 写入新的明细，并追加库存与新台账流水
      int ledgerIndex = 0;
      for (var index = 0; index < items.length; index += 1) {
        final item = items[index];
        final code = _productCodeFor(item.productCode, item.productName);
        affectedCodes.add(code);
        await _upsertProduct(txn, code, item.productName, createdAt);

        await txn.insert('inbound_items', {
          'id': '$receiptId-item-$index',
          'receipt_id': receiptId,
          'product_code': code,
          'product_name': item.productName.trim(),
          'quantity': item.quantity,
          'purchase_price': item.purchasePrice,
          'sale_price': item.salePrice,
        });

        // 累加新库存
        await _increaseStockRaw(txn, code, item.productName, item.quantity);

        // 插入新台账
        await _insertLedgerRaw(
          txn,
          productCode: code,
          productName: item.productName,
          delta: item.quantity,
          reason: LedgerReason.inbound.name,
          sourceId: receiptId,
          createdAt: createdAt,
          index: ledgerIndex++,
        );
      }

      // 7. 安全检验：受影响商品的结余库存不能小于 0
      for (final code in affectedCodes) {
        final currentStock = await _stockFor(txn, code);
        if (currentStock < 0) {
          throw InventoryException('无法覆写：冲销后商品 (编码: $code) 的库存不足 (结余小于0)。');
        }
      }
      validateOcrPermit?.call();
    });
  }

  /// 全局重新生成库存和台账
  Future<void> rebuildInventoryStockAndLedger() async {
    if (await _isOnlineWorkspace()) {
      await _ensureSync();
      await _db.transaction((txn) => _reconcileStock(txn));
      return;
    }
    await _db.transaction((txn) async {
      // 1. 物理清空已有的台账和库存
      await txn.delete('stock_ledger');
      await txn.delete('warehouse_stock');

      int ledgerIndex = 0;

      // 2. 遍历所有入库单明细并重写
      final receipts =
          await txn.query('inbound_receipts', orderBy: 'created_at ASC');
      for (final receipt in receipts) {
        final receiptId = receipt['id']! as String;
        final createdAtStr = receipt['created_at']! as String;
        final createdAt = DateTime.parse(createdAtStr);

        final items = await txn.query(
          'inbound_items',
          where: 'receipt_id = ?',
          whereArgs: [receiptId],
        );

        for (final item in items) {
          final code = item['product_code']! as String;
          final name = item['product_name']! as String;
          final qty = item['quantity']! as int;

          // 累加库存
          await _increaseStockRaw(txn, code, name, qty);

          // 插入台账
          await _insertLedgerRaw(
            txn,
            productCode: code,
            productName: name,
            delta: qty,
            reason: 'inbound',
            sourceId: receiptId,
            createdAt: createdAt,
            index: ledgerIndex++,
          );
        }
      }

      // 3. 遍历所有出库单明细并重写
      final orders =
          await txn.query('outbound_orders', orderBy: 'created_at ASC');
      for (final order in orders) {
        final orderId = order['id']! as String;
        final createdAtStr = order['created_at']! as String;
        final createdAt = DateTime.parse(createdAtStr);

        final items = await txn.query(
          'outbound_items',
          where: 'order_id = ?',
          whereArgs: [orderId],
        );

        for (final item in items) {
          final code = item['product_code']! as String;
          final name = item['product_name']! as String;
          final qty = item['quantity']! as int;

          // 扣减库存
          await _increaseStockRaw(txn, code, name, -qty);

          // 插入台账
          await _insertLedgerRaw(
            txn,
            productCode: code,
            productName: name,
            delta: -qty,
            reason: 'outbound',
            sourceId: orderId,
            createdAt: createdAt,
            index: ledgerIndex++,
          );
        }
      }
    });
  }

  /// 无负库存校验的底层操作方法
  Future<void> _increaseStockRaw(
    Transaction txn,
    String code,
    String name,
    int delta,
  ) async {
    final rows = await txn.query(
      'warehouse_stock',
      columns: ['quantity'],
      where: 'product_code = ?',
      whereArgs: [code],
      limit: 1,
    );
    final current = rows.isEmpty ? 0 : rows.single['quantity']! as int;
    final next = current + delta;
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

  Future<void> _insertLedgerRaw(
    Transaction txn, {
    required String productCode,
    required String productName,
    required int delta,
    required String reason,
    required String sourceId,
    required DateTime createdAt,
    required int index,
  }) async {
    await txn.insert('stock_ledger', {
      'id': 'lg-${DateTime.now().microsecondsSinceEpoch}-$index',
      'product_code': productCode,
      'product_name': productName.trim(),
      'delta': delta,
      'reason': reason,
      'source_id': sourceId,
      'created_at': createdAt.toIso8601String(),
    });
  }

  Future<void> compressOldInboundImages(
      {bool force = false,
      void Function(int current, int total)? onProgress}) async {
    try {
      final now = DateTime.now();
      final sevenDaysAgo = now.subtract(const Duration(days: 7));

      final rows = await _db.query(
        'inbound_receipts',
        columns: ['id', 'image_path'],
        where: 'created_at < ? AND image_path IS NOT NULL AND image_path != ?',
        whereArgs: [sevenDaysAgo.toIso8601String(), ''],
      );

      final total = rows.length;
      if (total == 0) {
        onProgress?.call(0, 0);
        return;
      }

      for (int i = 0; i < total; i++) {
        final row = rows[i];
        final receiptId = row['id'] as String;
        final imagePath = row['image_path'] as String;

        onProgress?.call(i + 1, total);

        if (!force && imagePath.contains('_compressed')) {
          continue;
        }

        final originalFile = File(imagePath);
        if (!originalFile.existsSync()) {
          continue;
        }

        try {
          final ext = path.extension(imagePath);
          final dir = path.dirname(imagePath);
          final baseName = path.basenameWithoutExtension(imagePath);

          // 如果强制重新压缩并且已经是带 _compressed 后缀的文件，则直接覆盖原文件，不重复加后缀
          final newPath = baseName.contains('_compressed')
              ? imagePath
              : path.join(dir, '${baseName}_compressed$ext');

          await _compressImageScale(imagePath, newPath);

          // 如果是生成了新的压缩图片文件，则更新数据库，并物理删除原大图
          if (newPath != imagePath && File(newPath).existsSync()) {
            await _db.update(
              'inbound_receipts',
              {'image_path': newPath},
              where: 'id = ?',
              whereArgs: [receiptId],
            );
            await originalFile.delete();
          }
        } catch (_) {
          continue;
        }
      }
    } catch (_) {}
  }

  Future<void> _compressImageScale(String inputPath, String outputPath,
      {int maxDimension = 1000}) async {
    final bytes = await File(inputPath).readAsBytes();
    final img.Image? image = img.decodeImage(bytes);
    if (image == null) return;

    img.Image resized = image;
    if (image.width > maxDimension || image.height > maxDimension) {
      if (image.width > image.height) {
        resized = img.copyResize(image, width: maxDimension);
      } else {
        resized = img.copyResize(image, height: maxDimension);
      }
    }

    final Uint8List jpgBytes = img.encodeJpg(resized, quality: 70);
    await File(outputPath).writeAsBytes(jpgBytes, flush: true);
  }

  Future<void> clearSettledTextData() async {
    if (await _isOnlineWorkspace()) {
      await _hideSettled();
      return;
    }
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'inbound_receipts',
        columns: ['id', 'image_path'],
        where: 'is_settled = ?',
        whereArgs: [1],
      );

      final ids = rows.map((r) => r['id'] as String).toList();
      if (ids.isEmpty) return;

      for (final row in rows) {
        final imagePath = row['image_path'] as String?;
        if (imagePath != null && imagePath.isNotEmpty) {
          final file = File(imagePath);
          if (file.existsSync()) {
            await file.delete();
          }
        }
      }

      for (final receiptId in ids) {
        await txn.delete(
          'inbound_items',
          where: 'receipt_id = ?',
          whereArgs: [receiptId],
        );
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
      }

      await txn.delete(
        'inbound_receipts',
        where: 'is_settled = ?',
        whereArgs: [1],
      );
    });
  }

  Future<void> clearSettledImagesData() async {
    if (await _isOnlineWorkspace()) {
      await _hideSettled();
      return;
    }
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'inbound_receipts',
        columns: ['id', 'image_path'],
        where: 'is_settled = ? AND image_path IS NOT NULL AND image_path != ?',
        whereArgs: [1, ''],
      );

      if (rows.isEmpty) return;

      for (final row in rows) {
        final id = row['id'] as String;
        final imagePath = row['image_path'] as String;
        final file = File(imagePath);
        if (file.existsSync()) {
          await file.delete();
        }
        await txn.update(
          'inbound_receipts',
          {'image_path': null},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    });
  }

  Future<void> clearWarehouseStock() async {
    if (await _isOnlineWorkspace()) {
      await _hideTable('stock', 'warehouse_stock', 'product_code');
      return;
    }
    await _db.delete('warehouse_stock');
  }

  Future<void> clearStockAndProducts() async {
    if (await _isOnlineWorkspace()) {
      await _hideTable('stock', 'warehouse_stock', 'product_code');
      await _hideTable('product', 'products', 'code');
      return;
    }
    await _db.transaction((txn) async {
      await txn.delete('warehouse_stock');
      await txn.delete('products');
    });
  }
}
