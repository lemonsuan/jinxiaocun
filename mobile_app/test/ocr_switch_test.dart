import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inventory_mobile_app/src/application/capture_work_coordinator.dart';
import 'package:inventory_mobile_app/src/application/express_processing_queue.dart';
import 'package:inventory_mobile_app/src/application/ocr_access_policy.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/platform/paddle_ocr_channel.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const channel = MethodChannel('inventory_app/paddle_ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  final databases = <LocalInventoryDatabase>[];
  final releases = <void Function()>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ocr-switch-');
  });
  tearDown(() async {
    for (final release in releases.reversed) {
      release();
    }
    releases.clear();
    messenger.setMockMethodCallHandler(channel, null);
    for (final db in databases.reversed) {
      await db.close();
    }
    databases.clear();
    await root.delete(recursive: true);
  });
  Future<LocalInventoryDatabase> open({Directory? directory}) async {
    final db = LocalInventoryDatabase(
        directory: directory ?? root, factory: databaseFactoryFfi);
    await db.open();
    databases.add(db);
    return db;
  }

  Future<String> photo(String name) async {
    final file = File('${root.path}/$name.jpg');
    await file.writeAsBytes(img.encodeJpg(img.Image(width: 8, height: 8)));
    return file.path;
  }

  const goods = [
    InboundDraftItem(productCode: '100001', productName: '测试商品', quantity: 2)
  ];
  Map<String, Object> recognition() => {
        'rows': [
          ['100001', '测试商品', '2']
        ],
        'rawText': '100001 测试商品 2'
      };

  test('默认开启，关闭持久写盘，重开与切店共享同设备开关，其他设备独立', () async {
    final db = await open();
    expect(await db.loadOcrEnabled(), true);
    await db.saveOcrEnabled(false);
    final config = await databaseFactoryFfi
        .openDatabase('${root.path}/inventory_config.db');
    expect(
        (await config.query('app_settings',
                where: 'key=?', whereArgs: ['ocr_enabled']))
            .single['value'],
        'false');
    await db.saveAuthMode('online');
    await db.saveSyncServerUrl('https://shop.example.test');
    await db.saveActiveShopId('shop-a');
    final shop = await open();
    expect(await shop.loadOcrEnabled(), false);
    await shop.saveActiveShopId('shop-b');
    final second = await open();
    expect(await second.loadOcrEnabled(), false);
    final other = await open(directory: Directory('${root.path}/other-device'));
    expect(await other.loadOcrEnabled(), true);
  });

  test('业务备份不导出或恢复设备OCR开关', () async {
    final db = await open();
    final backup = await db.exportBackupBytes(includeImages: false);
    await db.saveOcrEnabled(false);
    await db.importBackupBytes(backup);
    expect(await db.loadOcrEnabled(), false);
    expect(utf8.decode(await db.exportBackupBytes(includeImages: false)),
        isNot(contains('ocr_enabled')));
  });

  test('关闭新单待补录无自动任务，不改变旧商品和库存', () async {
    final db = await open();
    await db.confirmInbound(trackingNumber: 'OLD-001', items: goods);
    await db.saveOcrEnabled(false);
    final receipt = await db.confirmInbound(
        trackingNumber: 'OTHER-COURIER-001',
        items: [],
        imagePath: await photo('manual'),
        ocrStatus: OcrStatus.needsReview);
    expect(receipt.ocrStatus, OcrStatus.needsReview);
    expect(await db.nextExpressImageJob(), null);
    expect((await db.loadStockTotals()).single.quantity, 2);
    await db.saveOcrEnabled(true);
    expect(await db.nextExpressImageJob(), null);
    expect((await db.loadInboundHistory()).first.items, isEmpty);
  });

  test('关闭时平台零调用，关闭再开启拒绝旧识别结果', () async {
    final db = await open();
    var calls = 0;
    final response = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(channel, (_) {
      calls++;
      return response.future;
    });
    final ocr = PaddleOcrChannel(policy: () => db.ocrPolicy);
    await db.saveOcrEnabled(false);
    await expectLater(
        ocr.recognizeTable('/unused'), throwsA(isA<OcrCancelled>()));
    expect(calls, 0);
    await db.saveOcrEnabled(true);
    final future = ocr.recognizeTable('/photo.jpg');
    final assertion = expectLater(future, throwsA(isA<OcrCancelled>()));
    await Future<void>.delayed(Duration.zero);
    await db.saveOcrEnabled(false);
    await db.saveOcrEnabled(true);
    response.complete(recognition());
    await assertion;
    expect(calls, 1);
  });

  test('队列在关闭及相机租约期间暂停，退出只恢复旧pending', () async {
    final db = await open();
    final source = await photo('queue');
    await db.confirmInbound(
        trackingNumber: 'QUEUE-001',
        items: [],
        imagePath: source,
        ocrStatus: OcrStatus.pending,
        expressToken: 'queue_token');
    await db.saveOcrEnabled(false);
    await db.confirmInbound(
        trackingNumber: 'SKIPPED-001',
        items: [],
        imagePath: await photo('skipped'),
        ocrStatus: OcrStatus.needsReview);
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return recognition();
    });
    final queue = ExpressProcessingQueue.forDatabase(db);
    releases.add(queue.retain());
    await queue.kick();
    expect(calls, 0);
    expect(File(source).existsSync(), true);
    final release = CaptureWorkCoordinator.instance.acquire();
    releases.add(release);
    await db.saveOcrEnabled(true);
    await queue.kick();
    expect(calls, 0);
    release();
    await queue.kick();
    expect(calls, 1);
    final receipts = await db.loadInboundHistory();
    expect(
        receipts.firstWhere((r) => r.trackingNumber == 'SKIPPED-001').ocrStatus,
        OcrStatus.needsReview);
    expect((await db.loadStockTotals()).single.quantity, 2);
  });

  test('处理中关闭保持原图及pending，不写失败或库存', () async {
    final db = await open();
    final source = await photo('cancel');
    await db.confirmInbound(
        trackingNumber: 'CANCEL-001',
        items: [],
        imagePath: source,
        ocrStatus: OcrStatus.pending,
        expressToken: 'cancel_token');
    final entered = Completer<void>();
    final result = Completer<Map<String, Object>>();
    messenger.setMockMethodCallHandler(channel, (_) {
      entered.complete();
      return result.future;
    });
    final queue = ExpressProcessingQueue.forDatabase(db);
    releases.add(queue.retain());
    final running = queue.kick();
    await entered.future;
    await db.saveOcrEnabled(false);
    result.complete(recognition());
    await running;
    expect((await db.loadInboundHistory()).single.ocrStatus, OcrStatus.pending);
    expect(await db.nextExpressImageJob(), isNotNull);
    expect(File(source).existsSync(), true);
    expect(await db.loadStockTotals(), isEmpty);
  });

  test('OCR落库事务内关闭会回滚全部明细和库存', () async {
    final db = await open();
    final receipt = await db.confirmInbound(
        trackingNumber: 'TX-001', items: [], ocrStatus: OcrStatus.pending);
    final permit = await db.ocrPolicy.permit();
    Future<void>? disabling;
    var checks = 0;
    await expectLater(
        db.updateInboundOcrResult(
            receiptId: receipt.id,
            items: goods,
            ocrStatus: OcrStatus.confirmed,
            validateOcrPermit: () {
              permit.validate();
              if (++checks == 1) {
                disabling = db.saveOcrEnabled(false);
              }
            }),
        throwsA(isA<OcrCancelled>()));
    await disabling;
    expect(await db.loadStockTotals(), isEmpty);
    expect((await db.loadInboundHistory()).single.ocrStatus, OcrStatus.pending);
    expect((await db.loadInboundHistory()).single.items, isEmpty);
  });

  test('单据覆写事务内关闭回滚，手工元信息变化也拒绝旧结果', () async {
    final db = await open();
    final old =
        await db.confirmInbound(trackingNumber: 'AI-TX-001', items: goods);
    final permit = await db.ocrPolicy.permit();
    Future<void>? disabling;
    var checks = 0;
    await expectLater(
        db.overwriteInboundItems(
            receiptId: old.id,
            items: [goods.single.copyWith(quantity: 99)],
            ocrStatus: OcrStatus.confirmed,
            expectedReceipt: old,
            validateOcrPermit: () {
              permit.validate();
              if (++checks == 1) {
                disabling = db.saveOcrEnabled(false);
              }
            }),
        throwsA(isA<OcrCancelled>()));
    await disabling;
    expect((await db.loadStockTotals()).single.quantity, 2);
    await db.overwriteInboundItems(
        receiptId: old.id,
        items: goods,
        ocrStatus: OcrStatus.confirmed,
        sellerOrderNumber: 'MANUAL-EDIT');
    await expectLater(
        db.overwriteInboundItems(
            receiptId: old.id,
            items: [goods.single.copyWith(quantity: 99)],
            ocrStatus: OcrStatus.confirmed,
            expectedReceipt: old),
        throwsA(isA<Exception>()));
    expect((await db.loadInboundHistory()).single.sellerOrderNumber,
        'MANUAL-EDIT');
    expect((await db.loadStockTotals()).single.quantity, 2);
  });
}
