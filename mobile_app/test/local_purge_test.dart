import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/local_purge.dart';

void main() {
  sqfliteFfiInit();
  late Database sql;
  late LocalInventoryDatabase db;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('local-purge-test-');
    sql = await databaseFactoryFfi.openDatabase('${root.path}/test.db');
    for (final statement in LocalDatabaseSchema.createStatements) {
      await sql.execute(statement);
    }
    db = LocalInventoryDatabase(database: sql, directory: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> add(String id,
      {String date = '2026-10-29T01:00:00Z',
      bool settled = true,
      String? image}) async {
    await sql.insert('inbound_receipts', {
      'id': id,
      'tracking_number': id,
      'created_at': date,
      'ocr_status': 'confirmed',
      'is_settled': settled ? 1 : 0,
      'image_path': image
    });
    await sql.insert('inbound_items', {
      'id': 'item-$id',
      'receipt_id': id,
      'product_code': 'sku',
      'product_name': '商品',
      'quantity': 1
    });
    await sql.insert('ocr_results', {
      'id': 'ocr-$id',
      'receipt_id': id,
      'raw_json': '{}',
      'created_at': date
    });
    await sql.insert('stock_ledger', {
      'id': 'ledger-$id',
      'source_id': id,
      'product_code': 'sku',
      'product_name': '商品',
      'delta': 1,
      'reason': 'inbound',
      'created_at': date
    });
  }

  Future<LocalPurgePlan> plan() => db.prepareLocalPurge(
      from: DateTime.parse('2026-10-29T00:00:00Z'),
      to: DateTime.parse('2026-10-29T02:00:00Z'));
  test('闭区间、冻结目标及物理副本删除保留库存', () async {
    final photo = File('${root.path}/photo.jpg');
    await photo.writeAsString('image');
    await add('a', image: photo.path, date: '2026-10-29T08:00:00+08:00');
    await add('end', date: '2026-10-29T02:00:00Z');
    await add('outside', date: '2026-10-29T02:00:01Z');
    await add('unsettled', settled: false);
    await sql.insert('warehouse_stock',
        {'product_code': 'sku', 'product_name': '商品', 'quantity': 12});
    await sql.insert('sync_meta', {
      'kind': 'inbound',
      'id': 'a',
      'revision': 1,
      'data': '{"tracking_number":"a"}'
    });
    await sql.insert('sync_conflicts', {
      'operation_id': 'old',
      'kind': 'inbound',
      'id': 'a',
      'local_data': '{"tracking_number":"a"}',
      'message': '历史',
      'resolved': 1
    });
    await sql.delete('sync_dirty');
    final preview = await plan();
    expect(preview.receiptCount, 2);
    await add('late');
    await sql.delete('sync_dirty', where: 'id=?', whereArgs: ['late']);
    final result = await db.executeLocalPurge(preview);
    expect(result.receiptCount, 2);
    expect(result.deletedImageCount, 1);
    expect(await photo.exists(), false);
    for (final table in [
      'inbound_receipts',
      'inbound_items',
      'ocr_results',
      'stock_ledger'
    ]) {
      expect(await sql.query(table), hasLength(3), reason: table);
    }
    expect(await sql.query('sync_meta'), isEmpty);
    expect(await sql.query('sync_conflicts'), isEmpty);
    expect((await sql.query('sync_dirty')).map((row) => row['id']).toSet(),
        {'outside', 'unsettled'});
    expect((await sql.query('warehouse_stock')).single['quantity'], 12);
    await db.restoreLocallyHiddenRecords();
    expect(await sql.query('sync_purged'), hasLength(2));
  });
  test('内容变化整笔拒绝，照片仍在', () async {
    final photo = File('${root.path}/photo.jpg');
    await photo.writeAsString('image');
    await add('a', image: photo.path);
    final preview = await plan();
    await sql.update('inbound_items', {'quantity': 2});
    await expectLater(
        db.executeLocalPurge(preview), throwsA(isA<LocalPurgePlanChanged>()));
    expect(await sql.query('inbound_receipts'), hasLength(1));
    expect(await photo.exists(), true);
  });
  test('共享图片保留、活跃OCR跳过', () async {
    final photo = File('${root.path}/shared.jpg');
    await photo.writeAsString('image');
    await add('a', image: photo.path);
    await add('other', image: photo.path, settled: false);
    await add('active');
    await sql.update('inbound_receipts', {'ocr_status': 'processing'},
        where: 'id=?', whereArgs: ['active']);
    final preview = await plan();
    expect(preview.sharedImageCount, 1);
    expect(preview.skippedReasons['照片或识别处理中'], 1);
    final result = await db.executeLocalPurge(preview);
    expect(result.sharedImageCount, 1);
    expect(await photo.exists(), true);
  });
  test('高版本重放和迟到图片不复活且游标推进', () async {
    await add('a');
    await db.executeLocalPurge(await plan());
    final data = {
      'tracking_number': 'a',
      'created_at': '2026-10-29T01:00:00Z',
      'is_settled': true,
      'ocr_status': 'confirmed',
      'items': <Object>[]
    };
    await db.applySyncPull([
      {'kind': 'inbound', 'id': 'a', 'revision': 8, 'data': data}
    ], 8);
    expect(await sql.query('inbound_receipts'), isEmpty);
    expect(await sql.query('sync_meta'), isEmpty);
    expect(await db.loadSyncCursor(), 8);
    final late = File('${root.path}/late.jpg');
    await late.writeAsString('late');
    await db.attachSyncMedia(
        {'kind': 'inbound', 'id': 'a', 'index': 0, 'sha256': 'a' * 64},
        late.path);
    expect(await sql.query('sync_media'), isEmpty);
    await db.retryLocalPurgeFiles();
    expect(await late.exists(), false);
  });
  test('数据库事务失败保留照片，文件回收失败能够恢复重试', () async {
    final photo = File('${root.path}/photo.jpg');
    await photo.writeAsString('image');
    await add('a', image: photo.path);
    final preview = await plan();
    await sql.execute(
        "CREATE TRIGGER fail_purge BEFORE INSERT ON sync_purged BEGIN SELECT RAISE(ABORT,'测试回滚'); END");
    await expectLater(
        db.executeLocalPurge(preview), throwsA(isA<DatabaseException>()));
    expect(await photo.exists(), true);
    expect(await sql.query('inbound_receipts'), hasLength(1));
    expect(await sql.query('local_purge_gc'), isEmpty);
    await sql.execute('DROP TRIGGER fail_purge');
    await db.executeLocalPurge(preview);
    final blocked = Directory('${root.path}/blocked.jpg');
    await blocked.create();
    await sql.insert('local_purge_gc', {'path': blocked.path});
    expect((await db.retryLocalPurgeFiles()).pendingImageCount, 1);
    await blocked.delete();
    await File(blocked.path).writeAsString('image');
    expect((await db.retryLocalPurgeFiles()).deletedImageCount, 1);
    expect(await sql.query('local_purge_gc'), isEmpty);
  });
}
