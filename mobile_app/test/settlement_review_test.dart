import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory directory;
  late Database sql;
  late LocalInventoryDatabase database;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('settlement-review-');
    sql = await databaseFactoryFfi.openDatabase('${directory.path}/review.db');
    for (final statement in LocalDatabaseSchema.createStatements) {
      await sql.execute(statement);
    }
    database = LocalInventoryDatabase(database: sql, directory: directory);
    await database.loadStockTotals();
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<List<String>> addLargeBatch() async {
    final ids = List.generate(1205, (index) => 'receipt-$index');
    await sql.transaction((transaction) async {
      final batch = transaction.batch();
      for (final id in ids) {
        batch.insert('inbound_receipts', {
          'id': id,
          'tracking_number': id,
          'created_at': '2026-10-30T08:00:00+08:00',
          'ocr_status': 'confirmed',
          'is_settled': 0,
        });
      }
      await batch.commit(noResult: true);
      await transaction.update('sync_dirty', {'generation': 7});
    });
    return ids;
  }

  test('超过SQLite常见参数上限的大批量状态与dirty代际在后段写失败时全部回滚', () async {
    final ids = await addLargeBatch();
    // 后段故障保证跨分片写入也受同一事务保护，而非仅单条语句回滚。
    await sql.execute('''CREATE TRIGGER review_settlement_failure
      BEFORE UPDATE OF is_settled ON inbound_receipts
      WHEN NEW.id='receipt-1204'
      BEGIN SELECT RAISE(ABORT, 'review failure'); END''');
    await expectLater(
        database.setReceiptsSettled(ids, true), throwsA(anything));
    expect(await sql.query('inbound_receipts', where: 'is_settled=1'), isEmpty);
    expect(
        (await sql.query('sync_dirty')).every((row) => row['generation'] == 7),
        isTrue);
    await sql.execute('DROP TRIGGER review_settlement_failure');
    await database.setReceiptsSettled(ids, true);
    expect(await sql.query('inbound_receipts', where: 'is_settled=1'),
        hasLength(ids.length));
    expect(
        (await sql.query('sync_dirty')).every((row) => row['generation'] == 8),
        isTrue);
  });

  test('大批量尾部缺失目标不会提前修改已有记录或同步代际', () async {
    final ids = await addLargeBatch();
    await expectLater(
        database.setReceiptsSettled([...ids, 'missing-receipt'], true),
        throwsA(anything));
    expect(await sql.query('inbound_receipts', where: 'is_settled=1'), isEmpty);
    expect(
        (await sql.query('sync_dirty')).every((row) => row['generation'] == 7),
        isTrue);
    expect(await sql.query('stock_ledger'), isEmpty);
    expect(await sql.query('warehouse_stock'), isEmpty);
  });
}
