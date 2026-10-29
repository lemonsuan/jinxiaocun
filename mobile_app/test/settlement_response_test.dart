import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Database sql;
  late LocalInventoryDatabase database;
  late List<String> ids;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('settlement-response-');
    sql = await databaseFactoryFfi.openDatabase('${root.path}/test.db');
    for (final statement in LocalDatabaseSchema.createStatements) {
      await sql.execute(statement);
    }
    database = LocalInventoryDatabase(database: sql, directory: root);
    ids = [];
    for (var i = 0; i < 2; i++) {
      ids.add((await database.confirmInbound(
              trackingNumber: 'SETTLE-$i',
              imagePath: '${root.path}/retained-$i.jpg',
              items: const [
            InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: 2)
          ]))
          .id);
    }
  });
  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test('批量去重只改结算字段并保留库存明细与照片，同值重试不新增dirty代际', () async {
    final ledger = await sql.query('stock_ledger');
    final stock = await sql.query('warehouse_stock');
    final items = await sql.query('inbound_items');
    final before = await sql.query('inbound_receipts');
    await database.setReceiptsSettled([ids[0], ids[0], ids[1]], true);
    final after = await sql.query('inbound_receipts');
    expect(after, [
      for (final row in before) {...row, 'is_settled': 1}
    ]);
    expect(await sql.query('stock_ledger'), ledger);
    expect(await sql.query('warehouse_stock'), stock);
    expect(await sql.query('inbound_items'), items);
    final dirty = await sql.query('sync_dirty');
    await database.setReceiptsSettled(ids, true);
    expect(await sql.query('sync_dirty'), dirty);
    await database.setReceiptSettled(ids[0], false);
    expect(
        (await database.loadInboundHistory()).where((r) => r.isSettled).length,
        1);
  });

  test('缺失目标整批失败，已有单据及同步代际不变；空批次不写', () async {
    final before = await sql.query('inbound_receipts');
    final dirty = await sql.query('sync_dirty');
    await expectLater(database.setReceiptsSettled([...ids, 'missing'], true),
        throwsException);
    expect(await sql.query('inbound_receipts'), before);
    expect(await sql.query('sync_dirty'), dirty);
    await database.setReceiptsSettled([], true);
    expect(await sql.query('sync_dirty'), dirty);
  });
}
