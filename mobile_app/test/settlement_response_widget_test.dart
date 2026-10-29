import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/application/express_processing_queue.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ui/app_home.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ControlledDatabase extends LocalInventoryDatabase {
  ControlledDatabase(Directory directory)
      : super(directory: directory, factory: databaseFactoryFfi);
  int inboundReads = 0, stockReads = 0, outboundReads = 0, settlementWrites = 0;
  Completer<void>? writeGate, readGate, readEntered;
  bool failWrite = false;
  bool failNextRead = false;
  Object? scopeOverride;
  @override
  Object get processingScope => scopeOverride ?? super.processingScope;
  @override
  Future<List<InboundReceipt>> loadInboundHistory() async {
    inboundReads++;
    if (failNextRead) {
      failNextRead = false;
      throw StateError('模拟后台读取失败');
    }
    final gate = readGate;
    readGate = null;
    final snapshot = await super.loadInboundHistory();
    if (gate != null) {
      readEntered?.complete();
      await gate.future;
    }
    return snapshot;
  }

  @override
  Future<List<WarehouseStock>> loadStockTotals() {
    stockReads++;
    return super.loadStockTotals();
  }

  @override
  Future<List<OutboundOrder>> loadOutboundHistory() {
    outboundReads++;
    return super.loadOutboundHistory();
  }

  @override
  Future<void> setReceiptsSettled(Iterable<String> ids, bool settled) async {
    settlementWrites++;
    await writeGate?.future;
    if (failWrite) throw StateError('模拟保存失败');
    await super.setReceiptsSettled(ids, settled);
  }

  Future<void> externalSettlement(String id, bool settled) =>
      super.setReceiptsSettled([id], settled);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late ControlledDatabase db;
  late InboundReceipt receipt;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('settlement-widget-');
    db = ControlledDatabase(root);
    await db.open();
    await db.saveOcrEnabled(false);
    receipt = await db.confirmInbound(
        trackingNumber: 'SETTLE-WIDGET-1',
        items: const [
          InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: 2)
        ]);
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    await db.close();
    await root.delete(recursive: true);
  });
  Future<void> drain(WidgetTester tester, [int count = 25]) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(home: AppHome(database: db)));
    await drain(tester);
    await tester.tap(find.text('历史入库'));
    await tester.pumpAndSettle();
  }

  Finder marker() => find.byKey(ValueKey('receipt-settlement-${receipt.id}'));
  void expectSettled(bool value) => expect(
      find.descendant(of: marker(), matching: find.text(value ? '已结算' : '未结算')),
      findsOneWidget);
  void refresh() {
    for (final listener
        in List.of(ExpressProcessingQueue.forDatabase(db).listeners)) {
      listener();
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('单条保存后只改对应行，重复点击只写一次，筛选立即使用新状态', (tester) async {
    await open(tester);
    final reads = [db.stockReads, db.inboundReads, db.outboundReads];
    db.writeGate = Completer<void>();
    await tester.tap(marker());
    await tester.pump();
    await tester.tap(marker());
    expect(db.settlementWrites, 1);
    expectSettled(false);
    db.writeGate!.complete();
    await drain(tester);
    expectSettled(true);
    expect([db.stockReads, db.inboundReads, db.outboundReads], reads);
    await tester.tap(find.text('未结算').first);
    await tester.pump();
    expect(marker(), findsNothing);
    await finish(tester);
  });

  for (final fail in [false, true]) {
    testWidgets(
        fail ? '保存失败不改状态，失效旧刷新仍接回同期新增入库' : '保存成功不被旧刷新覆盖，后台接回库存与入库且后续合法状态可见',
        (tester) async {
      await open(tester);
      db.readGate = Completer<void>();
      final held = db.readGate!;
      db.readEntered = Completer<void>();
      refresh();
      await drain(tester);
      expect(db.readEntered!.isCompleted, true);
      final reads = db.inboundReads;
      db.failWrite = fail;
      await tester.tap(marker());
      await drain(tester);
      expectSettled(!fail);
      expect(db.inboundReads, reads);
      if (fail) expect(find.textContaining('更新结算状态失败'), findsOneWidget);
      await tester.runAsync(() async {
        final pending = await db.confirmInbound(
            trackingNumber: 'CONCURRENT-NEW',
            ocrStatus: OcrStatus.pending,
            items: const []);
        await db.updateInboundOcrResult(
            receiptId: pending.id,
            ocrStatus: OcrStatus.confirmed,
            items: const [
              InboundDraftItem(
                  productCode: 'SKU', productName: '商品', quantity: 3)
            ]);
      });
      held.complete();
      await drain(tester);
      expect(find.text('快递：CONCURRENT-NEW'), findsOneWidget);
      expectSettled(!fail);
      expect(db.inboundReads, reads + 1);
      expect((await tester.runAsync(db.loadStockTotals))!.single.quantity, 5);
      expect(find.textContaining('3 件货'), findsOneWidget);
      await tester.tap(find.text('库存管理'));
      await tester.pump();
      expect(find.text('库存：5'), findsOneWidget);
      await tester.tap(find.text('历史入库'));
      await tester.pump();
      if (!fail) {
        await tester.runAsync(() => db.externalSettlement(receipt.id, false));
        refresh();
        await drain(tester);
        expectSettled(false);
      }
      await finish(tester);
    });
  }

  testWidgets('核验车整批一次写入且不全量刷新，重新查询与返回主页状态一致', (tester) async {
    await open(tester);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final input = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.hintText?.startsWith('SF123') == true);
    await tester.enterText(input, receipt.trackingNumber);
    await tester.tap(find.text('查询入库单'));
    await tester.pumpAndSettle();
    final reads = [db.stockReads, db.inboundReads, db.outboundReads];
    await tester.tap(find.text('全部设为已结算'));
    await drain(tester);
    expect(db.settlementWrites, 1);
    expect(find.textContaining('已结算 1/1'), findsOneWidget);
    expect([db.stockReads, db.inboundReads, db.outboundReads], reads);
    await tester.tap(find.text('查询入库单'));
    await tester.pump();
    expect(find.textContaining('已结算 1/1'), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    expectSettled(true);
    await finish(tester);
  });

  testWidgets('页面卸载后迟到保存不会setState', (tester) async {
    await open(tester);
    db.writeGate = Completer<void>();
    await tester.tap(marker());
    await tester.pumpWidget(const SizedBox());
    db.writeGate!.complete();
    await drain(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('补刷新失败保留保存结果并提示，下一次刷新仍可恢复', (tester) async {
    await open(tester);
    db.readGate = Completer<void>();
    final held = db.readGate!;
    db.readEntered = Completer<void>();
    refresh();
    await drain(tester);
    expect(db.readEntered!.isCompleted, true);
    await tester.tap(marker());
    await drain(tester);
    expectSettled(true);
    db.failNextRead = true;
    held.complete();
    await drain(tester);
    expectSettled(true);
    expect(find.textContaining('后台数据刷新失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    refresh();
    await drain(tester);
    expectSettled(true);
    await finish(tester);
  });

  testWidgets('保存过程中切换数据库作用域不向旧页面应用迟到状态', (tester) async {
    await open(tester);
    db.writeGate = Completer<void>();
    await tester.tap(marker());
    await tester.pump();
    db.scopeOverride = Object();
    db.writeGate!.complete();
    await drain(tester);
    expectSettled(false);
    expect(tester.takeException(), isNull);
    db.scopeOverride = null;
    await finish(tester);
  });

  testWidgets('先开始后返回的旧刷新不能覆盖较新的完整快照，也不重复补读', (tester) async {
    await open(tester);
    db.readGate = Completer<void>();
    final held = db.readGate!;
    db.readEntered = Completer<void>();
    refresh();
    await drain(tester);
    expect(db.readEntered!.isCompleted, true);
    await tester.runAsync(() => db
            .confirmInbound(trackingNumber: 'NEWEST-REFRESH', items: const [
          InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: 1)
        ]));
    refresh();
    await drain(tester);
    expect(find.text('快递：NEWEST-REFRESH'), findsOneWidget);
    final reads = db.inboundReads;
    held.complete();
    await drain(tester);
    expect(find.text('快递：NEWEST-REFRESH'), findsOneWidget);
    expect(db.inboundReads, reads);
    await finish(tester);
  });
}
