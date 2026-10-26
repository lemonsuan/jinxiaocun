import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/domain/express_capture.dart';

void main() {
  late Database sqlite;
  late LocalInventoryDatabase database;
  setUp(() async {
    sqfliteFfiInit();
    sqlite = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    for (final sql in LocalDatabaseSchema.createStatements) {
      await sqlite.execute(sql);
    }
    database = LocalInventoryDatabase(database: sqlite);
  });
  tearDown(() async {
    await database.close();
  });
  Future<InboundReceipt> pending(String tracking) => database.confirmInbound(
      trackingNumber: tracking,
      items: const [],
      imagePath: '/old/$tracking.jpg',
      ocrStatus: OcrStatus.pending,
      expressToken: 'token_$tracking',
      expressCrop: CaptureCrop.full);
  Future<void> apply(ExpressImageJob job, {int quantity = 3}) =>
      database.updateInboundOcrResult(
          receiptId: job.receiptId,
          items: [
            InboundDraftItem(
                productCode: 'SKU123', productName: '测试商品', quantity: quantity)
          ],
          ocrStatus: OcrStatus.confirmed,
          expectedImagePath: job.imagePath,
          processedImagePath: '/new/crop.jpg',
          expectedExpressJobValue: job.encode());

  test(
      'pending receipt and job are atomic; completion updates photo and stock once',
      () async {
    final receipt = await pending('SF001');
    final job = (await database.nextExpressImageJob())!;
    expect(job.receiptId, receipt.id);
    expect(await database.isExpressImageJobCurrent(job), true);
    expect(await database.loadStockTotals(), isEmpty);
    await apply(job);
    await apply(job);
    expect(await database.nextExpressImageJob(), isNull);
    expect((await database.loadStockTotals()).single.quantity, 3);
    expect((await database.loadInboundHistory()).single.imagePath,
        '/new/crop.jpg');
    expect(
        await sqlite.query('app_settings',
            where: 'key = ?', whereArgs: [job.settingKey]),
        isEmpty);
  });
  test(
      'stale token and stale source cannot write results; retry gets a fresh token',
      () async {
    final receipt = await pending('SF002');
    final old = (await database.nextExpressImageJob())!;
    await database.updateInboundOcrResult(
        receiptId: receipt.id,
        items: const [],
        ocrStatus: OcrStatus.failed,
        expectedImagePath: old.imagePath,
        expectedExpressJobValue: old.encode());
    expect(await database.nextExpressImageJob(), isNull);
    expect(await database.retryExpressImageJob(receipt.id), true);
    final retry = (await database.nextExpressImageJob())!;
    expect(retry.token, isNot(old.token));
    await apply(old, quantity: 99);
    expect(await database.loadStockTotals(), isEmpty);
    final wrongPath = ExpressImageJob(
        receiptId: retry.receiptId,
        imagePath: '/wrong.jpg',
        token: retry.token);
    await apply(wrongPath, quantity: 99);
    expect(await database.loadStockTotals(), isEmpty);
    await apply(retry);
    expect((await database.loadStockTotals()).single.quantity, 3);
  });
  test(
      'manual overwrite invalidates pending job and prevents stale inventory writes',
      () async {
    final receipt = await pending('SF003');
    final job = (await database.nextExpressImageJob())!;
    await database.overwriteInboundItems(
        receiptId: receipt.id,
        items: const [
          InboundDraftItem(
              productCode: 'SKU123', productName: '测试商品', quantity: 7)
        ],
        ocrStatus: OcrStatus.confirmed);
    await apply(job, quantity: 99);
    expect((await database.loadStockTotals()).single.quantity, 7);
    expect(await database.isExpressImageJobCurrent(job), false);
  });
  test(
      'deleting receipt invalidates job and stale callback cannot resurrect stock',
      () async {
    final receipt = await pending('SF004');
    final job = (await database.nextExpressImageJob())!;
    await database.deleteInboundReceipt(receipt.id);
    await apply(job, quantity: 99);
    expect(await database.loadInboundHistory(), isEmpty);
    expect(await database.loadStockTotals(), isEmpty);
    expect(await database.nextExpressImageJob(), isNull);
  });
  test(
      'restored receipt path replaces original-device job path and invalidates old result',
      () async {
    final receipt = await pending('SF005');
    final old = (await database.nextExpressImageJob())!;
    await sqlite.update(
        'inbound_receipts', {'image_path': '/restored/phone/photo.jpg'},
        where: 'id = ?', whereArgs: [receipt.id]);
    final restored = (await database.nextExpressImageJob())!;
    expect(restored.imagePath, '/restored/phone/photo.jpg');
    expect(restored.token, isNot(old.token));
    expect(await database.isExpressImageJobCurrent(old), false);
    await apply(old, quantity: 99);
    expect(await database.loadStockTotals(), isEmpty);
    await apply(restored);
    expect((await database.loadStockTotals()).single.quantity, 3);
  });
  test(
      'malformed mismatched durable job is quarantined instead of spinning forever',
      () async {
    final receipt = await pending('SF006');
    final job = (await database.nextExpressImageJob())!;
    final wrong = ExpressImageJob(
        receiptId: 'other-receipt', imagePath: job.imagePath, token: job.token);
    await sqlite.update('app_settings', {'value': wrong.encode()},
        where: 'key = ?', whereArgs: [job.settingKey]);
    expect(await database.nextExpressImageJob(), isNull);
    expect((await database.loadInboundHistory()).single.ocrStatus,
        OcrStatus.failed);
    expect((await database.loadInboundHistory()).single.id, receipt.id);
  });
  test(
      'corrupt JSON is quarantined then retry recovers from live photo using full crop',
      () async {
    final receipt = await pending('SF008');
    final job = (await database.nextExpressImageJob())!;
    await sqlite.update('app_settings', {'value': '{invalid'},
        where: 'key = ?', whereArgs: [job.settingKey]);
    expect(await database.nextExpressImageJob(), isNull);
    expect(await database.retryExpressImageJob(receipt.id), true);
    final recovered = (await database.nextExpressImageJob())!;
    expect(recovered.imagePath, receipt.imagePath);
    expect(recovered.crop.toMap(), CaptureCrop.full.toMap());
    await apply(recovered);
    expect((await database.loadStockTotals()).single.quantity, 3);
  });
  test('duplicate tracking transaction never inserts a second durable job',
      () async {
    await pending('SF007');
    await expectLater(pending('SF007'), throwsA(isA<Exception>()));
    expect((await database.loadInboundHistory()).length, 1);
    expect((await sqlite.query('app_settings')).length, 1);
  });
}
