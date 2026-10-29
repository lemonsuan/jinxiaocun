import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/local_purge.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Database sql;
  late LocalInventoryDatabase db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('purge-review-');
    sql = await databaseFactoryFfi.openDatabase('${root.path}/review.db');
    for (final statement in LocalDatabaseSchema.createStatements) {
      await sql.execute(statement);
    }
    db = LocalInventoryDatabase(database: sql, directory: root);
    await db.saveAuthMode('online');
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Map<String, Object?> data(String id) => {
        'tracking_number': id,
        'created_at': '2026-10-29T01:00:00Z',
        'ocr_status': 'confirmed',
        'is_settled': true,
        'items': <Object>[]
      };
  Map<String, Object?> record(
          String kind, String id, int revision, Map value) =>
      {'kind': kind, 'id': id, 'revision': revision, 'data': value};
  Future<void> add(String id, {bool accepted = true}) async {
    await sql.insert('inbound_receipts', {
      'id': id,
      'tracking_number': id,
      'created_at': '2026-10-29T01:00:00Z',
      'ocr_status': 'confirmed',
      'is_settled': 1
    });
    await sql.delete('sync_dirty', where: 'id=?', whereArgs: [id]);
    if (accepted) {
      await sql.insert('sync_meta', {
        'kind': 'inbound',
        'id': id,
        'revision': 1,
        'data': jsonEncode(data(id))
      });
    }
  }

  Future<LocalPurgePlan> preview() => db.prepareLocalPurge(
      from: DateTime.parse('2026-10-29T00:00:00Z'),
      to: DateTime.parse('2026-10-29T02:00:00Z'));

  test('在线只清已确认且无未决状态的单据', () async {
    for (final id in ['clean', 'dirty', 'frozen', 'conflict', 'unknown']) {
      await add(id, accepted: id != 'unknown');
    }
    await sql.insert(
        'sync_dirty', {'kind': 'inbound', 'id': 'dirty', 'generation': 2});
    await sql.insert('sync_outbox', {
      'operation_id': 'op',
      'kind': 'inbound',
      'id': 'frozen',
      'generation': 1,
      'base_revision': 1,
      'data': '{}'
    });
    await sql.insert('sync_conflicts', {
      'operation_id': 'conflict-op',
      'kind': 'inbound',
      'id': 'conflict',
      'local_data': '{}',
      'message': '未解决'
    });
    final plan = await preview();
    expect(plan.receiptIds, ['clean']);
    expect(plan.skippedReasons.values.reduce((a, b) => a + b), 4);
    await db.executeLocalPurge(plan);
    expect(await sql.query('inbound_receipts'), hasLength(4));
    expect(await sql.query('sync_outbox'), hasLength(1));
    expect(await sql.query('sync_conflicts'), hasLength(1));
  });

  test('预览后出现待同步状态时整笔拒绝', () async {
    await add('a');
    await add('b');
    final plan = await preview();
    await sql
        .insert('sync_dirty', {'kind': 'inbound', 'id': 'b', 'generation': 1});
    await expectLater(
        db.executeLocalPurge(plan), throwsA(isA<LocalPurgePlanChanged>()));
    expect(await sql.query('inbound_receipts'), hasLength(2));
    expect(await sql.query('sync_purged'), isEmpty);
  });

  test('清理后重放不复活且同包库存与其他单据正常', () async {
    await add('a');
    await db.applySyncPull([
      record('stock', 'sku', 2,
          {'product_code': 'sku', 'product_name': '商品', 'quantity': 12})
    ], 2);
    await db.executeLocalPurge(await preview());
    await db.applySyncPull([
      record('inbound', 'a', 3, data('a')),
      record('inbound', 'b', 4, data('b')),
      record('stock', 'sku', 5,
          {'product_code': 'sku', 'product_name': '商品', 'quantity': 15})
    ], 5);
    expect((await sql.query('inbound_receipts')).single['id'], 'b');
    expect((await sql.query('warehouse_stock')).single['quantity'], 15);
    expect(await db.loadSyncCursor(), 5);
    expect(await sql.query('sync_meta', where: "kind='inbound' AND id='a'"),
        isEmpty);
    expect(await sql.query('sync_dirty'), isEmpty);
    await db.restoreLocallyHiddenRecords();
    await db.applySyncPull([record('inbound', 'a', 6, data('a'))], 6);
    expect((await sql.query('inbound_receipts')).single['id'], 'b');
    expect((await sql.query('warehouse_stock')).single['quantity'], 15);
  });

  test('文件回收失败持久化且重开后可重试', () async {
    final blocked = Directory('${root.path}/blocked.jpg');
    await blocked.create();
    await add('a');
    await sql.update('inbound_receipts', {'image_path': blocked.path});
    await sql.delete('sync_dirty');
    final result = await db.executeLocalPurge(await preview());
    expect(result.pendingImageCount, 1);
    expect(await sql.query('inbound_receipts'), isEmpty);
    expect(await sql.query('local_purge_gc'), hasLength(1));
    await db.close();
    await blocked.delete();
    final photo = File(blocked.path);
    await photo.writeAsString('待回收');
    sql = await databaseFactoryFfi.openDatabase('${root.path}/review.db');
    db = LocalInventoryDatabase(database: sql, directory: root);
    final retried = await db.retryLocalPurgeFiles();
    expect(retried.deletedImageCount, 1);
    expect(await photo.exists(), false);
    expect(await sql.query('local_purge_gc'), isEmpty);
    expect(await sql.query('sync_purged'), hasLength(1));
  });

  test('其他单据的同步历史快照引用阻止图片回收', () async {
    final photo = File('${root.path}/shared-history.jpg');
    await photo.writeAsString('共享');
    await add('a');
    await sql.update('inbound_receipts', {'image_path': photo.path});
    await sql.delete('sync_dirty');
    await sql.insert('sync_conflicts', {
      'operation_id': 'other-history',
      'kind': 'outbound',
      'id': 'other',
      'local_data': jsonEncode({
        'image_paths': [photo.path]
      }),
      'message': '历史证据',
      'resolved': 1
    });
    final plan = await preview();
    expect(plan.sharedImageCount, 1);
    final result = await db.executeLocalPurge(plan);
    expect(result.sharedImageCount, 1);
    expect(result.deletedImageCount, 0);
    expect(await photo.exists(), true);
    expect(await sql.query('sync_conflicts'), hasLength(1));
  });
}
