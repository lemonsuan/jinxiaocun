part of 'local_inventory_database.dart';

/// Scalar wire maps keep persistence independent from HTTP and image transport.
extension InventorySyncPersistence on LocalInventoryDatabase {
  Future<List<Map<String, Object?>>> _backupBusinessRows(String table) async {
    await _ensureSync();
    final key = switch (table) {
      'inbound_receipts' => 'id',
      'inbound_items' => 'receipt_id',
      'ocr_results' => 'receipt_id',
      'outbound_orders' => 'id',
      'outbound_items' => 'order_id',
      'outbound_attachments' => 'order_id',
      _ => null
    };
    if (key == null) return _db.query(table);
    final kind = table.startsWith('outbound') ? 'outbound' : 'inbound';
    return _db.query(table,
        where: '$key NOT IN(SELECT id FROM sync_abandoned WHERE kind=?)',
        whereArgs: [kind]);
  }

  Future<void> _resetRestoredSync(Transaction txn) async {
    for (final table in [
      'sync_dirty',
      'sync_meta',
      'sync_outbox',
      'sync_conflicts',
      'sync_hidden',
      'sync_media',
      'sync_hash',
      'sync_abandoned'
    ]) {
      await txn.delete(table);
    }
    await txn.update('sync_control', {'cursor': 0, 'suppressed': 0});
  }

  Future<void> _ensureSync() async {
    if (_syncReady) return;
    for (final sql in SyncDatabaseSchema.statements) {
      await _db.execute(sql);
    }
    _syncReady = true;
  }

  Future<Map<String, Object?>?> loadSyncContext() async {
    if (!await _isOnlineWorkspace()) return null;
    // 一次读取整套选择，避免切换事务前后的不同字段被拼到同一请求。
    var config = await _authSnapshot();
    var device = config['sync_device_id'] ?? '';
    if (device.isEmpty) {
      device =
          'device-${DateTime.now().microsecondsSinceEpoch}-${sha256.convert(utf8.encode(_db.path)).toString().substring(0, 12)}';
      await _settings.insert(
          'app_settings',
          {
            'key': 'sync_device_id',
            'value': device,
            'updated_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      // 首次创建设备标识也重新读取同一份配置快照，再检查已打开的工作区。
      config = await _authSnapshot();
      device = config['sync_device_id'] ?? '';
    }
    if (config[LocalInventoryDatabase._authModeKey] != 'online') return null;
    final server = _InventoryScope._server(
        config[LocalInventoryDatabase._syncServerUrlKey] ?? '');
    final token = config[LocalInventoryDatabase._authTokenKey] ?? '';
    final shop = config[LocalInventoryDatabase._activeShopIdKey] ?? '';
    if (token.isEmpty || shop.isEmpty || device.isEmpty) return null;
    if (_openedScope != null && '$server\n$shop' != _openedScope) return null;
    return {
      'server_url': server,
      'token': token,
      'shop_id': shop,
      'device_id': device
    };
  }

  Future<List<Map<String, Object?>>> pendingSyncRecords(
      {int limit = 50}) async {
    await _ensureSync();
    return _db.transaction((txn) async {
      final rows = await txn.rawQuery(
          '''SELECT d.*,COALESCE(m.revision,0) AS base_revision FROM sync_dirty d
        LEFT JOIN sync_meta m ON m.kind=d.kind AND m.id=d.id
        WHERE NOT EXISTS(SELECT 1 FROM sync_abandoned a WHERE a.kind=d.kind AND a.id=d.id)
        AND NOT EXISTS(SELECT 1 FROM sync_outbox o WHERE o.kind=d.kind AND o.id=d.id AND (o.status='pending' OR o.generation>=d.generation))
        AND NOT EXISTS(SELECT 1 FROM sync_conflicts c WHERE c.kind=d.kind AND c.id=d.id AND c.resolved=0 AND c.generation>=d.generation)
        ORDER BY CASE d.kind WHEN 'product' THEN 0 WHEN 'inbound' THEN 1 ELSE 2 END,d.id LIMIT ?''',
          [limit]);
      final records = <Map<String, Object?>>[];
      for (final row in rows) {
        final data =
            await _document(txn, row['kind'] as String, row['id'] as String);
        if (data != null) records.add({...row, 'data': data});
      }
      return records;
    });
  }

  Future<Map<String, Object?>> freezeSyncOperation(
      Map candidate, Map wireData) async {
    await _ensureSync();
    final device = await _setting('sync_device_id');
    return _db.transaction((txn) async {
      final kind = candidate['kind'] as String;
      final id = candidate['id'] as String;
      final existing = await txn.query('sync_outbox',
          where: "kind=? AND id=? AND (status='pending' OR generation=?)",
          whereArgs: [kind, id, candidate['generation']]);
      if (existing.isNotEmpty) return _operation(existing.first);
      final generation = candidate['generation'] as int;
      final current = await txn
          .query('sync_dirty', where: 'kind=? AND id=?', whereArgs: [kind, id]);
      if (current.isEmpty || current.first['generation'] != generation) {
        throw StateError('单据在上传图片期间发生变化，请重新同步');
      }
      final operationId =
          '$device-${DateTime.now().microsecondsSinceEpoch}-$generation';
      final row = <String, Object?>{
        'operation_id': operationId,
        'kind': kind,
        'id': id,
        'generation': generation,
        'base_revision': candidate['base_revision'] ?? 0,
        'data': jsonEncode(wireData)
      };
      await txn.insert('sync_outbox', row);
      return _operation(row);
    });
  }

  Map<String, Object?> _operation(Map row) => {
        'operation_id': row['operation_id'],
        'kind': row['kind'],
        'id': row['id'],
        'base_revision': row['base_revision'],
        'data': jsonDecode(row['data'] as String)
      };
  Future<List<Map<String, Object?>>> pendingSyncOperations(
      {int limit = 50}) async {
    await _ensureSync();
    return (await _db.query('sync_outbox',
            where: "status='pending'", orderBy: 'rowid', limit: limit))
        .map(_operation)
        .toList();
  }

  Future<int> pendingSyncCount() async {
    await _ensureSync();
    return Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM sync_dirty')) ??
        0;
  }

  Future<int> loadSyncCursor() async {
    await _ensureSync();
    return (await _db.query('sync_control')).single['cursor'] as int;
  }

  Future<void> applySyncPushResults(List<Map> results) async {
    await _ensureSync();
    await _db.transaction((txn) async {
      for (final result in results) {
        final rows = await txn.query('sync_outbox',
            where: 'operation_id=?', whereArgs: [result['operation_id']]);
        if (rows.isEmpty) continue;
        final op = rows.single;
        if (result['status'] == 'applied' || result['status'] == 'duplicate') {
          final revision = result['revision'];
          if (revision is! int || revision < 1) {
            throw const FormatException('Invalid acknowledgement revision');
          }
          await _saveMeta(txn, op['kind'] as String, op['id'] as String,
              revision, jsonDecode(op['data'] as String) as Map);
          await txn.delete('sync_dirty',
              where: 'kind=? AND id=? AND generation=?',
              whereArgs: [op['kind'], op['id'], op['generation']]);
          await txn.delete('sync_outbox',
              where: 'operation_id=?', whereArgs: [op['operation_id']]);
          await txn.update('sync_conflicts', {'resolved': 1},
              where: 'kind=? AND id=? AND generation<=?',
              whereArgs: [op['kind'], op['id'], op['generation']]);
          await txn.delete('sync_outbox',
              where: "kind=? AND id=? AND status='conflict' AND generation<=?",
              whereArgs: [op['kind'], op['id'], op['generation']]);
        } else if (result['status'] == 'conflict') {
          await txn.update('sync_outbox', {'status': 'conflict'},
              where: 'operation_id=?', whereArgs: [op['operation_id']]);
          await txn.insert(
              'sync_conflicts',
              {
                'operation_id': op['operation_id'],
                'kind': op['kind'],
                'id': op['id'],
                'local_data': op['data'],
                'generation': op['generation'],
                'code': result['code'],
                'remote_record': result['record'] == null
                    ? null
                    : jsonEncode(result['record']),
                'message': result['message']?.toString() ?? '服务器版本冲突'
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });
  }

  Future<void> applySyncPull(List<Map> changes, int cursor) async {
    await _ensureSync();
    if (cursor < 0) throw const FormatException('Invalid cursor');
    await _db.transaction((txn) async {
      final oldCursor =
          (await txn.query('sync_control')).single['cursor'] as int;
      if (cursor < oldCursor) return;
      await txn.update('sync_control', {'suppressed': 1});
      for (final change in changes) {
        _validateRecord(change);
        final kind = change['kind'] as String;
        final id = change['id'] as String;
        final revision = change['revision'] as int;
        if (revision > cursor) {
          throw const FormatException('Record exceeds pull cursor');
        }
        if (await _isPurged(txn, kind, id)) continue;
        final previous = await txn.query('sync_meta',
            where: 'kind=? AND id=?', whereArgs: [kind, id]);
        if (previous.isNotEmpty &&
            (previous.single['revision'] as int) >= revision) {
          continue;
        }
        final data = Map<String, Object?>.from(change['data'] as Map);
        final dirty = await txn.query('sync_dirty',
            where: 'kind=? AND id=?', whereArgs: [kind, id]);
        if (dirty.isNotEmpty && kind != 'stock') {
          final frozen = await txn.query('sync_outbox',
              where: 'kind=? AND id=?', whereArgs: [kind, id]);
          if (frozen.any(
              (op) => _sameSyncValue(jsonDecode(op['data'] as String), data))) {
            // The push committed but its HTTP acknowledgement was lost. Keep the
            // operation for idempotent retry and retain any edits made since freeze.
            await _saveMeta(txn, kind, id, revision, data);
            continue;
          }
          // Preserve all local edits. Pull is also allowed to discover conflicts
          // before this device has had a chance to push its dirty generation.
          final local = await _document(txn, kind, id);
          await txn.insert(
              'sync_conflicts',
              {
                'operation_id': 'pull-$kind-$id-$revision',
                'kind': kind,
                'id': id,
                'local_data': jsonEncode(local),
                'generation': dirty.single['generation'],
                'remote_record': jsonEncode(change),
                'message': '服务器已有更新，本机修改已保留'
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
          continue;
        }
        if (kind != 'stock') await _writeRemote(txn, kind, id, data);
        await _saveMeta(txn, kind, id, revision, data);
      }
      await _reconcileStock(txn);
      await txn.update('sync_control', {'suppressed': 0, 'cursor': cursor});
    });
  }

  Future<void> _saveMeta(DatabaseExecutor txn, String kind, String id,
      int revision, Map data) async {
    if (await _isPurged(txn, kind, id)) return;
    final previous = await txn
        .query('sync_meta', where: 'kind=? AND id=?', whereArgs: [kind, id]);
    if (previous.isNotEmpty && (previous.first['revision'] as int) > revision) {
      return;
    }
    await txn.insert(
        'sync_meta',
        {
          'kind': kind,
          'id': id,
          'revision': revision,
          'data': jsonEncode(data)
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> _document(
      DatabaseExecutor db, String kind, String id) async {
    final table = switch (kind) {
      'product' => 'products',
      'inbound' => 'inbound_receipts',
      'outbound' => 'outbound_orders',
      _ => throw const FormatException('Unknown document kind')
    };
    final rows = await db.query(table,
        where: '${kind == 'product' ? 'code' : 'id'}=?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final data = Map<String, Object?>.from(rows.single);
    if (kind == 'product') return data;
    data.remove('id');
    final inbound = kind == 'inbound';
    if (inbound) data['is_settled'] = data['is_settled'] == 1;
    data['items'] = (await db.query(
            inbound ? 'inbound_items' : 'outbound_items',
            where: '${inbound ? 'receipt_id' : 'order_id'}=?',
            whereArgs: [id],
            orderBy: 'id'))
        .map((row) => Map<String, Object?>.from(row)
          ..remove(inbound ? 'receipt_id' : 'order_id'))
        .toList();
    if (!inbound) {
      data['image_paths'] = (await db.query('outbound_attachments',
              where: 'order_id=?', whereArgs: [id], orderBy: 'id'))
          .map((r) => r['image_path'])
          .toList();
    }
    return data;
  }

  bool _sameSyncValue(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every(
              (key) => b.containsKey(key) && _sameSyncValue(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          List.generate(a.length, (i) => i)
              .every((i) => _sameSyncValue(a[i], b[i]));
    }
    return a == b;
  }

  void _validateRecord(Map record) {
    final kind = record['kind'];
    final id = record['id'];
    final data = record['data'];
    if (!['product', 'inbound', 'outbound', 'stock'].contains(kind) ||
        id is! String ||
        id.isEmpty ||
        id.length > 200 ||
        record['revision'] is! int ||
        (record['revision'] as int) < 1 ||
        data is! Map) {
      throw const FormatException('Invalid sync record');
    }
    if (kind == 'stock') {
      if (data['product_code'] != id ||
          data['quantity'] is! int ||
          (data['quantity'] as int) < 0 ||
          data['product_name'] is! String) {
        throw const FormatException('Invalid stock record');
      }
    } else if (kind == 'product') {
      if (data['code'] != id || data['name'] is! String) {
        throw const FormatException('Invalid product record');
      }
    } else {
      if (data['items'] is! List ||
          data['created_at'] is! String ||
          DateTime.tryParse(data['created_at'] as String) == null) {
        throw const FormatException('Invalid document');
      }
      if (kind == 'inbound' &&
          (data['tracking_number'] is! String ||
              (data['tracking_number'] as String).isEmpty ||
              data['is_settled'] is! bool ||
              !OcrStatus.values.any((s) => s.name == data['ocr_status']))) {
        throw const FormatException('Invalid inbound');
      }
      final ids = <String>{};
      for (final item in data['items'] as List) {
        if (item is! Map ||
            item['id'] is! String ||
            !ids.add(item['id'] as String) ||
            item['product_code'] is! String ||
            item['product_name'] is! String ||
            item['quantity'] is! int ||
            (item['quantity'] as int) <= 0) {
          throw const FormatException('Invalid document item');
        }
        for (final key in ['purchase_price', 'sale_price']) {
          final price = item[key];
          if (price != null &&
              (price is! num || !price.isFinite || price < 0)) {
            throw const FormatException('Invalid price');
          }
        }
      }
    }
    final digests = <Object?>[
      if (data['image_sha256'] != null) data['image_sha256'],
      ...?data['image_sha256s'] as List?
    ];
    for (final digest in digests) {
      if (digest is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('Invalid media digest');
      }
    }
  }

  Future<void> _writeRemote(Transaction txn, String kind, String id,
      Map<String, Object?> data) async {
    if (await _isPurged(txn, kind, id)) return;
    if (kind == 'product') {
      await txn.insert(
          'products',
          {
            'code': id,
            'name': data['name'],
            'default_purchase_price': data['default_purchase_price'],
            'default_sale_price': data['default_sale_price'],
            'created_at':
                data['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
            'updated_at':
                data['updated_at'] ?? DateTime.now().toUtc().toIso8601String()
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      return;
    }
    final inbound = kind == 'inbound';
    final parentKey = inbound ? 'receipt_id' : 'order_id';
    final itemTable = inbound ? 'inbound_items' : 'outbound_items';
    // Never replace a child belonging to a different root document.
    for (final raw in data['items'] as List) {
      final item = raw as Map;
      final existing =
          await txn.query(itemTable, where: 'id=?', whereArgs: [item['id']]);
      if (existing.isNotEmpty && existing.single[parentKey] != id) {
        throw const FormatException('Cross-document item id');
      }
    }
    final digests = inbound
        ? [if (data['image_sha256'] != null) data['image_sha256']]
        : (data['image_sha256s'] as List? ?? []);
    final oldMedia = await txn
        .query('sync_media', where: 'kind=? AND id=?', whereArgs: [kind, id]);
    final paths = <String>[];
    await txn
        .delete('sync_media', where: 'kind=? AND id=?', whereArgs: [kind, id]);
    for (var index = 0; index < digests.length; index++) {
      final digest = digests[index] as String;
      final old = oldMedia
          .where((row) => row['sha256'] == digest && row['local_path'] != null);
      final local = old.isEmpty ? null : old.first['local_path'] as String;
      paths.add(local ?? 'sync://$digest');
      await txn.insert('sync_media', {
        'kind': kind,
        'id': id,
        'position': index,
        'sha256': digest,
        'local_path': local
      });
    }
    if (inbound) {
      await txn.insert(
          'inbound_receipts',
          {
            'id': id,
            'tracking_number': data['tracking_number'],
            'seller_order_number': data['seller_order_number'],
            'rebate_order_number': data['rebate_order_number'],
            'scheme_number': data['scheme_number'],
            'created_at': data['created_at'],
            'ocr_status': data['ocr_status'],
            'is_settled': data['is_settled'] == true ? 1 : 0,
            'image_path': paths.isEmpty ? null : paths.first
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await txn.insert(
          'outbound_orders',
          {
            'id': id,
            'created_at': data['created_at'],
            'logistics_number': data['logistics_number'],
            'note': data['note']
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn
          .delete('outbound_attachments', where: 'order_id=?', whereArgs: [id]);
      for (var i = 0; i < paths.length; i++) {
        await txn.insert('outbound_attachments', {
          'id': 'sync-$id-$i',
          'order_id': id,
          'image_path': paths[i],
          'created_at': data['created_at']
        });
      }
    }
    await txn.delete(itemTable, where: '$parentKey=?', whereArgs: [id]);
    for (final item in data['items'] as List) {
      await txn.insert(itemTable,
          {...Map<String, Object?>.from(item as Map), parentKey: id});
    }
    if (inbound) {
      await txn.delete('app_settings',
          where: 'key=?', whereArgs: ['express_image_job:$id']);
    }
  }

  Map<String, int> _deltas(String kind, Map? data) {
    final quantities = <String, int>{};
    if (data == null) return quantities;
    for (final raw in data['items'] as List? ?? []) {
      final item = raw as Map;
      final code = item['product_code'] as String;
      quantities[code] = (quantities[code] ?? 0) +
          (kind == 'outbound' ? -1 : 1) * (item['quantity'] as int);
    }
    return quantities;
  }

  Future<void> _reconcileStock(Transaction txn,
      {bool rejectNegative = false}) async {
    final pending = <String, int>{};
    for (final dirty in await txn.query('sync_dirty',
        where: "kind IN ('inbound','outbound')")) {
      final kind = dirty['kind'] as String;
      final id = dirty['id'] as String;
      final local = _deltas(kind, await _document(txn, kind, id));
      final baseline = await txn
          .query('sync_meta', where: 'kind=? AND id=?', whereArgs: [kind, id]);
      final accepted = _deltas(
          kind,
          baseline.isEmpty
              ? null
              : jsonDecode(baseline.single['data'] as String) as Map);
      for (final code in {...local.keys, ...accepted.keys}) {
        pending[code] =
            (pending[code] ?? 0) + (local[code] ?? 0) - (accepted[code] ?? 0);
      }
    }
    for (final snapshot
        in await txn.query('sync_meta', where: "kind='stock'")) {
      final data = jsonDecode(snapshot['data'] as String) as Map;
      final code = data['product_code'] as String;
      final projected = (data['quantity'] as int) + (pending[code] ?? 0);
      if (projected < 0) {
        if (rejectNegative) {
          throw InventoryException('相关本机单据依赖这笔库存，请先处理出库冲突');
        }
        await txn.insert(
            'sync_conflicts',
            {
              'operation_id': 'stock-$code-${snapshot['revision']}',
              'kind': 'stock',
              'id': code,
              'local_data': jsonEncode({'pending_delta': pending[code]}),
              'remote_record': jsonEncode({
                'kind': 'stock',
                'id': code,
                'revision': snapshot['revision'],
                'data': data
              }),
              'message': '共享库存不足，本机待同步出库需要处理'
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      if (projected >= 0) {
        await txn.update('sync_conflicts', {'resolved': 1},
            where: "kind='stock' AND id=?", whereArgs: [code]);
      }
      final quantity = projected < 0 ? 0 : projected;
      final old = await txn
          .query('warehouse_stock', where: 'product_code=?', whereArgs: [code]);
      final delta =
          quantity - (old.isEmpty ? 0 : old.single['quantity'] as int);
      if (delta != 0) {
        await txn.insert('stock_ledger', {
          'id': 'sync-adjust-$code-${DateTime.now().microsecondsSinceEpoch}',
          'product_code': code,
          'product_name': data['product_name'],
          'delta': delta,
          'reason': LedgerReason.adjustment.name,
          'source_id': 'sync-stock-${snapshot['revision']}',
          'created_at': DateTime.now().toUtc().toIso8601String()
        });
      }
      await txn.insert(
          'warehouse_stock',
          {
            'product_code': code,
            'product_name': data['product_name'],
            'quantity': quantity
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _hide(String kind, String id) async {
    await _ensureSync();
    await _db.insert('sync_hidden', {'kind': kind, 'id': id},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _hideTable(String kind, String table, String key) async {
    await _ensureSync();
    await _db.execute(
        'INSERT OR IGNORE INTO sync_hidden(kind,id) SELECT ?, $key FROM $table',
        [kind]);
  }

  Future<void> _hideSettled() async {
    await _ensureSync();
    await _db.execute(
        "INSERT OR IGNORE INTO sync_hidden(kind,id) SELECT 'inbound',id FROM inbound_receipts WHERE is_settled=1");
  }

  Future<void> restoreLocallyHiddenRecords() async {
    await _ensureSync();
    await _db.delete('sync_hidden');
  }

  Future<int> syncConflictCount() async {
    await _ensureSync();
    return Sqflite.firstIntValue(await _db.rawQuery(
            'SELECT COUNT(*) FROM sync_conflicts WHERE resolved=0')) ??
        0;
  }

  Future<List<Map<String, Object?>>> loadSyncConflicts() async {
    await _ensureSync();
    return _db.transaction((txn) async {
      final entries = <Map<String, Object?>>[];
      for (final row in await txn.query('sync_conflicts',
          where: 'resolved=0', orderBy: 'rowid')) {
        entries.add({
          ...row,
          'local_data': jsonDecode(row['local_data'] as String),
          'remote_record': row['remote_record'] == null
              ? null
              : jsonDecode(row['remote_record'] as String),
          'can_abandon': await _canAbandon(txn, row)
        });
      }
      return entries;
    });
  }

  Future<bool> _canAbandon(DatabaseExecutor txn, Map conflict) async {
    final kind = conflict['kind'];
    final id = conflict['id'];
    if (!['inbound', 'outbound'].contains(kind) ||
        conflict['remote_record'] != null ||
        conflict['resolved'] != 0 ||
        ![
          'insufficient_stock',
          'invalid_data',
          'duplicate_tracking',
          'media_missing',
          'duplicate_media',
          'duplicate_line',
          'line_parent_mismatch'
        ].contains(conflict['code'])) {
      return false;
    }
    final operations = await txn
        .query('sync_outbox', where: 'kind=? AND id=?', whereArgs: [kind, id]);
    if (operations.any((op) => op['status'] == 'pending')) return false;
    final rejected = operations.where((op) =>
        op['operation_id'] == conflict['operation_id'] &&
        op['status'] == 'conflict' &&
        op['base_revision'] == 0);
    if (rejected.isEmpty) return false;
    final meta = await txn.query('sync_meta',
        where: 'kind=? AND id=? AND revision>0', whereArgs: [kind, id]);
    if (meta.isNotEmpty) return false;
    final remote = await txn.query('sync_conflicts',
        where: 'kind=? AND id=? AND remote_record IS NOT NULL',
        whereArgs: [kind, id]);
    return remote.isEmpty;
  }

  /// Explicitly cancels a server-rejected NEW local attempt. Ordinary online
  /// delete/hide never uses this path and never changes shared stock.
  Future<void> abandonUnacceptedSyncConflict(String operationId) async {
    await _ensureSync();
    await _db.transaction((txn) async {
      final rows = await txn.query('sync_conflicts',
          where: 'operation_id=?', whereArgs: [operationId]);
      if (rows.isEmpty || !await _canAbandon(txn, rows.single)) {
        throw InventoryException('仅能放弃服务器明确拒绝且从未接受过的本机新单据');
      }
      final conflict = rows.single;
      final kind = conflict['kind'] as String;
      final id = conflict['id'] as String;
      final snapshot = await _document(txn, kind, id);
      if (snapshot == null) throw InventoryException('本机单据不存在');
      final deltas = _deltas(kind, snapshot);
      for (final entry in deltas.entries) {
        final stock = await txn.query('warehouse_stock',
            where: 'product_code=?', whereArgs: [entry.key]);
        final current = stock.isEmpty ? 0 : stock.single['quantity'] as int;
        if (current - entry.value < 0) {
          throw InventoryException('本机其他出库依赖这笔入库，请先处理相关出库');
        }
      }
      await txn.update('sync_control', {'suppressed': 1});
      await txn.insert('sync_abandoned', {
        'kind': kind,
        'id': id,
        'data': jsonEncode(snapshot),
        'operation_id': operationId
      });
      await txn.insert('sync_hidden', {'kind': kind, 'id': id},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      for (final entry in deltas.entries) {
        final stock = await txn.query('warehouse_stock',
            where: 'product_code=?', whereArgs: [entry.key]);
        final name = stock.isEmpty ? entry.key : stock.single['product_name'];
        final current = stock.isEmpty ? 0 : stock.single['quantity'] as int;
        await txn.insert(
            'warehouse_stock',
            {
              'product_code': entry.key,
              'product_name': name,
              'quantity': current - entry.value
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (entry.value != 0) {
          await txn.insert('stock_ledger', {
            'id':
                'abandon-${DateTime.now().microsecondsSinceEpoch}-${entry.key}',
            'product_code': entry.key,
            'product_name': name,
            'delta': -entry.value,
            'reason': 'adjustment',
            'source_id': operationId,
            'created_at': DateTime.now().toUtc().toIso8601String()
          });
        }
      }
      await txn.delete('sync_dirty',
          where: 'kind=? AND id=?', whereArgs: [kind, id]);
      await txn.delete('sync_outbox',
          where: 'kind=? AND id=?', whereArgs: [kind, id]);
      await txn.update('sync_conflicts', {'resolved': 1},
          where: 'kind=? AND id=?', whereArgs: [kind, id]);
      if (kind == 'inbound') {
        await txn.delete('app_settings',
            where: 'key=?', whereArgs: ['express_image_job:$id']);
      }
      await _reconcileStock(txn, rejectNegative: true);
      await txn.update('sync_control', {'suppressed': 0});
    });
  }

  Future<void> acceptServerSyncConflict(String operationId) async {
    await _ensureSync();
    await _db.transaction((txn) async {
      final rows = await txn.query('sync_conflicts',
          where: 'operation_id=? AND resolved=0', whereArgs: [operationId]);
      if (rows.isEmpty) return;
      final conflict = rows.single;
      if (conflict['remote_record'] == null || conflict['kind'] == 'stock') {
        throw InventoryException('没有可安全替换的服务器单据，请先处理相关单据冲突');
      }
      final record = jsonDecode(conflict['remote_record'] as String) as Map;
      _validateRecord(record);
      final kind = record['kind'] as String;
      final id = record['id'] as String;
      if (kind != conflict['kind'] || id != conflict['id']) {
        throw const FormatException('冲突单据身份不一致');
      }
      if (await _isPurged(txn, kind, id)) return;
      // The latest received server copy wins explicit resolution, never an old
      // conflict snapshot if a newer snapshot was already committed.
      final meta = await txn
          .query('sync_meta', where: 'kind=? AND id=?', whereArgs: [kind, id]);
      if (meta.isNotEmpty &&
          (meta.single['revision'] as int) > (record['revision'] as int)) {
        throw InventoryException('服务器版本已更新，请重新同步后处理冲突');
      }
      final localSnapshot = await _document(txn, kind, id);
      await txn.insert('sync_conflicts', {
        'operation_id':
            'resolved-$operationId-${DateTime.now().microsecondsSinceEpoch}',
        'kind': kind,
        'id': id,
        'local_data': jsonEncode(localSnapshot),
        'remote_record': jsonEncode(record),
        'message': '用户选择服务器版本前保留的本机完整快照',
        'resolved': 1,
      });
      await txn.update('sync_control', {'suppressed': 1});
      await _writeRemote(
          txn, kind, id, Map<String, Object?>.from(record['data'] as Map));
      await _saveMeta(
          txn, kind, id, record['revision'] as int, record['data'] as Map);
      await txn.delete('sync_dirty',
          where: 'kind=? AND id=?', whereArgs: [kind, id]);
      await txn.delete('sync_outbox',
          where: 'kind=? AND id=?', whereArgs: [kind, id]);
      await txn.update('sync_conflicts', {'resolved': 1},
          where: 'kind=? AND id=?', whereArgs: [kind, id]);
      await _reconcileStock(txn, rejectNegative: true);
      await txn.update('sync_control', {'suppressed': 0});
    });
  }

  Future<List<Map<String, Object?>>> pendingSyncMediaDownloads(
      {int limit = 20}) async {
    await _ensureSync();
    return _db.rawQuery(
        '''SELECT kind,id,position AS "index",sha256 FROM sync_media m WHERE local_path IS NULL
      AND NOT EXISTS(SELECT 1 FROM sync_hidden h WHERE h.kind=m.kind AND h.id=m.id)
      AND NOT EXISTS(SELECT 1 FROM sync_purged p WHERE p.kind=m.kind AND p.id=m.id) LIMIT ?''',
        [limit]);
  }

  Future<void> attachSyncMedia(Map reference, String localPath) async {
    await _ensureSync();
    await _db.transaction((txn) async {
      if (await _isPurged(
          txn, reference['kind'] as String, reference['id'] as String)) {
        await txn.insert('local_purge_gc', {'path': localPath},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        return;
      }
      final args = [
        reference['kind'],
        reference['id'],
        reference['index'],
        reference['sha256']
      ];
      final rows = await txn.query('sync_media',
          where: 'kind=? AND id=? AND position=? AND sha256=?',
          whereArgs: args);
      if (rows.isEmpty || rows.single['local_path'] != null) return;
      final dirty = await txn.query('sync_dirty',
          where: 'kind=? AND id=?', whereArgs: args.take(2).toList());
      if (dirty.isNotEmpty) return;
      await txn.update('sync_control', {'suppressed': 1});
      await txn.update('sync_media', {'local_path': localPath},
          where: 'kind=? AND id=? AND position=? AND sha256=?',
          whereArgs: args);
      final placeholder = 'sync://${reference['sha256']}';
      if (reference['kind'] == 'inbound') {
        await txn.update('inbound_receipts', {'image_path': localPath},
            where: 'id=? AND image_path=?',
            whereArgs: [reference['id'], placeholder]);
      } else {
        await txn.update('outbound_attachments', {'image_path': localPath},
            where: 'order_id=? AND id=? AND image_path=?',
            whereArgs: [
              reference['id'],
              'sync-${reference['id']}-${reference['index']}',
              placeholder
            ]);
      }
      await txn.update('sync_control', {'suppressed': 0});
    });
  }

  Future<String?> syncMediaDigest(
      String imagePath, int size, int modifiedMicros) async {
    await _ensureSync();
    final rows = await _db.query('sync_hash',
        where: 'path=? AND size=? AND modified=?',
        whereArgs: [imagePath, size, modifiedMicros]);
    return rows.isEmpty ? null : rows.single['digest'] as String;
  }

  Future<void> rememberSyncMedia(
      String imagePath, int size, int modifiedMicros, String digest) async {
    await _ensureSync();
    await _db.insert(
        'sync_hash',
        {
          'path': imagePath,
          'size': size,
          'modified': modifiedMicros,
          'digest': digest
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
