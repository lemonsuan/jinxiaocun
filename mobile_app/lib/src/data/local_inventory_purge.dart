part of 'local_inventory_database.dart';

extension LocalInventoryPurge on LocalInventoryDatabase {
  Future<bool> _isPurged(DatabaseExecutor db, String kind, String id) async =>
      (await db.query('sync_purged',
              where: 'kind=? AND id=?', whereArgs: [kind, id]))
          .isNotEmpty;

  Future<String?> _purgeSkip(DatabaseExecutor db, Map row, bool online) async {
    final id = row['id'];
    final hasJob = (await db.query('app_settings',
            where: 'key=?', whereArgs: ['express_image_job:$id']))
        .isNotEmpty;
    if (hasJob && row['ocr_status'] == 'failed') return '识别失败待重试';
    if (row['ocr_status'] == 'pending' ||
        row['ocr_status'] == 'processing' ||
        hasJob) {
      return '照片或识别处理中';
    }
    if (!online) return null;
    final meta = await db
        .query('sync_meta', where: "kind='inbound' AND id=?", whereArgs: [id]);
    if (meta.isEmpty || (meta.single['revision'] as int) < 1) return '尚未同步到服务器';
    for (final table in ['sync_dirty', 'sync_outbox', 'sync_conflicts']) {
      final rows = await db.query(table,
          where:
              "kind='inbound' AND id=?${table == 'sync_conflicts' ? ' AND resolved=0' : ''}",
          whereArgs: [id]);
      if (rows.isNotEmpty) return '存在待同步内容或冲突';
    }
    return null;
  }

  Future<String> _purgeFingerprint(DatabaseExecutor db, String id) async {
    final snapshot = <Object?>[];
    for (final entry in {
      'inbound_receipts': 'id',
      'inbound_items': 'receipt_id',
      'ocr_results': 'receipt_id',
      'stock_ledger': 'source_id',
    }.entries) {
      snapshot.add(await db.query(entry.key,
          where: '${entry.value}=?', whereArgs: [id], orderBy: 'id'));
    }
    for (final table in [
      'sync_meta',
      'sync_dirty',
      'sync_outbox',
      'sync_conflicts',
      'sync_abandoned',
      'sync_media'
    ]) {
      snapshot.add(await db.query(table,
          where: "kind='inbound' AND id=?", whereArgs: [id], orderBy: 'rowid'));
    }
    snapshot.add(await db.query('app_settings',
        where: 'key=?', whereArgs: ['express_image_job:$id']));
    return sha256.convert(utf8.encode(jsonEncode(snapshot))).toString();
  }

  Future<LocalPurgePlan> prepareLocalPurge(
      {required DateTime from, required DateTime to}) async {
    if (from.isAfter(to)) throw ArgumentError('开始时间不能晚于结束时间');
    await _ensureSync();
    if (_openedScope != null && await _selectedScope() != _openedScope) {
      throw const LocalPurgePlanChanged();
    }
    final online = await _isOnlineWorkspace();
    final scope = processingScope;
    return _db.transaction((txn) async {
      final hashes = <String, String>{};
      final skipped = <String, int>{};
      final images = <String>{};
      for (final row
          in await txn.query('inbound_receipts', where: 'is_settled=1')) {
        final created =
            DateTime.tryParse(row['created_at'] as String)?.toLocal();
        if (created == null ||
            created.isBefore(from.toLocal()) ||
            created.isAfter(to.toLocal())) {
          continue;
        }
        final reason = await _purgeSkip(txn, row, online);
        if (reason != null) {
          skipped.update(reason, (v) => v + 1, ifAbsent: () => 1);
          continue;
        }
        final id = row['id'] as String;
        hashes[id] = await _purgeFingerprint(txn, id);
        images.addAll(await _purgePaths(txn, id));
      }
      var shared = 0;
      for (final image in images) {
        if (await _purgeReferenced(txn, image,
            excluding: hashes.keys.toSet())) {
          shared++;
        }
      }
      return LocalPurgePlan(
          from: from,
          to: to,
          scope: scope,
          fingerprints: hashes,
          imageCount: images.length,
          sharedImageCount: shared,
          skippedReasons: skipped);
    });
  }

  Future<Set<String>> _purgePaths(DatabaseExecutor db, String id) async {
    final result = <String>{};
    for (final row
        in await db.query('inbound_receipts', where: 'id=?', whereArgs: [id])) {
      final value = row['image_path'] as String?;
      if (value != null && value.isNotEmpty && !value.startsWith('sync://')) {
        result.add(value);
      }
    }
    for (final row in await db.query('sync_media',
        where: "kind='inbound' AND id=?", whereArgs: [id])) {
      final value = row['local_path'] as String?;
      if (value != null && value.isNotEmpty) result.add(value);
    }
    // 历史已解决冲突也可能保留替换前的图片路径，随副本一并回收。
    void collect(Object? value, [String? key]) {
      if (value is Map) {
        for (final entry in value.entries) {
          collect(entry.value, entry.key.toString());
        }
      } else if (value is List) {
        for (final entry in value) {
          collect(entry, key);
        }
      } else if (value is String) {
        if (['image_path', 'image_paths', 'imagePath', 'local_path']
                .contains(key) &&
            path.isAbsolute(value) &&
            !value.startsWith('sync://')) {
          result.add(value);
        } else {
          try {
            final decoded = jsonDecode(value);
            if (decoded is Map || decoded is List) collect(decoded);
          } catch (_) {}
        }
      }
    }

    for (final table in [
      'sync_meta',
      'sync_outbox',
      'sync_conflicts',
      'sync_abandoned'
    ]) {
      for (final row in await db
          .query(table, where: "kind='inbound' AND id=?", whereArgs: [id])) {
        collect(row);
      }
    }
    return result;
  }

  Future<LocalPurgeResult> executeLocalPurge(LocalPurgePlan plan) async {
    await _ensureSync();
    if (!identical(plan.scope, processingScope) ||
        (_openedScope != null && await _selectedScope() != _openedScope)) {
      throw const LocalPurgePlanChanged();
    }
    final online = await _isOnlineWorkspace();
    final collectedPaths = <String>{};
    await _db.transaction((txn) async {
      for (final id in plan.receiptIds) {
        final rows =
            await txn.query('inbound_receipts', where: 'id=?', whereArgs: [id]);
        if (rows.isEmpty ||
            rows.single['is_settled'] != 1 ||
            await _purgeSkip(txn, rows.single, online) != null ||
            await _purgeFingerprint(txn, id) != plan.fingerprints[id]) {
          throw const LocalPurgePlanChanged();
        }
      }
      final control = (await txn.query('sync_control')).single['suppressed'];
      await txn.update('sync_control', {'suppressed': 1});
      for (final id in plan.receiptIds) {
        for (final image in await _purgePaths(txn, id)) {
          collectedPaths.add(image);
          await txn.insert('local_purge_gc', {'path': image},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await txn.insert('sync_purged', {'kind': 'inbound', 'id': id},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        for (final table in [
          'sync_meta',
          'sync_dirty',
          'sync_outbox',
          'sync_conflicts',
          'sync_abandoned',
          'sync_media',
          'sync_hidden'
        ]) {
          await txn
              .delete(table, where: "kind='inbound' AND id=?", whereArgs: [id]);
        }
        await txn.delete('app_settings',
            where: 'key=?', whereArgs: ['express_image_job:$id']);
        await txn
            .delete('inbound_items', where: 'receipt_id=?', whereArgs: [id]);
        await txn.delete('ocr_results', where: 'receipt_id=?', whereArgs: [id]);
        await txn.delete('stock_ledger',
            where: "source_id=? AND reason='inbound'", whereArgs: [id]);
        await txn.delete('inbound_receipts', where: 'id=?', whereArgs: [id]);
      }
      await txn.update('sync_control', {'suppressed': control});
    });
    final gc = await _retryLocalPurgeFiles(paths: collectedPaths);
    return LocalPurgeResult(
        receiptCount: plan.receiptCount,
        deletedImageCount: gc.deletedImageCount,
        sharedImageCount: gc.sharedImageCount,
        pendingImageCount: gc.pendingImageCount);
  }

  /// 逐行检查所有持久业务副本；未知结构中出现路径时也保守保留。
  Future<bool> _purgeReferenced(DatabaseExecutor db, String image,
      {Set<String> excluding = const {}}) async {
    bool contains(Object? value) {
      if (value is String) {
        if (value == image) return true;
        if (path.isAbsolute(value)) {
          if (path.normalize(value) == path.normalize(image)) return true;
          try {
            if (File(value).resolveSymbolicLinksSync() ==
                File(image).resolveSymbolicLinksSync()) {
              return true;
            }
          } catch (_) {}
        }
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map || decoded is List) return contains(decoded);
        } catch (_) {}
        return false;
      }
      if (value is Map) return value.values.any(contains);
      if (value is List) return value.any(contains);
      return false;
    }

    for (final table in [
      'inbound_receipts',
      'outbound_attachments',
      'ocr_results',
      'app_settings',
      'sync_media',
      'sync_meta',
      'sync_outbox',
      'sync_conflicts',
      'sync_abandoned'
    ]) {
      for (final row in await db.query(table)) {
        final excluded = (table == 'inbound_receipts' &&
                excluding.contains(row['id'])) ||
            (table == 'ocr_results' && excluding.contains(row['receipt_id'])) ||
            (row['kind'] == 'inbound' && excluding.contains(row['id'])) ||
            (table == 'app_settings' &&
                excluding.any((id) => row['key'] == 'express_image_job:$id'));
        if (!excluded && contains(row)) return true;
      }
    }
    return false;
  }

  /// 数据库已提交后回收文件；失败路径留在日志中供下次启动重试。
  Future<LocalPurgeResult> retryLocalPurgeFiles() => _retryLocalPurgeFiles();

  Future<LocalPurgeResult> _retryLocalPurgeFiles({Set<String>? paths}) async {
    await _ensureSync();
    final root = path.normalize(path.absolute(
        (_directory ?? await getApplicationDocumentsDirectory()).path));
    var deleted = 0, shared = 0, pending = 0;
    for (final row in await _db.query('local_purge_gc')) {
      final image = row['path'] as String;
      if (paths != null && !paths.contains(image)) continue;
      try {
        // 引用检查和文件移除之间持有写事务，防止其他录入新增同一路径引用。
        final outcome = await _db.transaction((txn) async {
          if (await _purgeReferenced(txn, image)) {
            await txn
                .delete('local_purge_gc', where: 'path=?', whereArgs: [image]);
            return 'shared';
          }
          final normalized = path.normalize(path.absolute(image));
          final file = File(image);
          if (!path.isWithin(root, normalized) ||
              FileSystemEntity.isLinkSync(image)) {
            return 'pending';
          }
          // 只处理照片文件和云端媒体缓存，不能把误写的数据库或设置文件当图片删除。
          final extension = path.extension(image).toLowerCase();
          final mediaPath =
              path.isWithin(path.join(root, 'cloud_media'), normalized);
          if (!['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif']
                  .contains(extension) &&
              !mediaPath) {
            return 'pending';
          }
          final type = FileSystemEntity.typeSync(image, followLinks: false);
          if (type != FileSystemEntityType.file &&
              type != FileSystemEntityType.notFound) {
            return 'pending';
          }
          var removed = false;
          if (file.existsSync()) {
            final real = file.resolveSymbolicLinksSync();
            final realRoot = Directory(root).resolveSymbolicLinksSync();
            if (!path.isWithin(realRoot, real)) return 'pending';
            file.deleteSync();
            removed = true;
          }
          await txn.delete('sync_hash', where: 'path=?', whereArgs: [image]);
          await txn
              .delete('local_purge_gc', where: 'path=?', whereArgs: [image]);
          return removed ? 'deleted' : 'absent';
        });
        if (outcome == 'shared') shared++;
        if (outcome == 'deleted') deleted++;
        if (outcome == 'pending') pending++;
      } catch (_) {
        pending++;
      }
    }
    return LocalPurgeResult(
        receiptCount: 0,
        deletedImageCount: deleted,
        sharedImageCount: shared,
        pendingImageCount: pending);
  }
}
