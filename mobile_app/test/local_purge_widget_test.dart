import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ui/data_management_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late LocalInventoryDatabase database;
  late String receiptId;
  var acquired = 0;
  var released = 0;
  var refreshed = 0;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('purge-widget-');
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    database = LocalInventoryDatabase(
        directory: directory, factory: databaseFactoryFfi);
    await database.open();
    final receipt = await database.confirmInbound(
      trackingNumber: 'SF123456',
      isSettled: true,
      items: [
        const InboundDraftItem(
            productCode: 'SKU', productName: '商品', quantity: 2)
      ],
    );
    receiptId = receipt.id;
    acquired = released = refreshed = 0;
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: DataManagementPage(
        database: database,
        acquireMaintenance: () async {
          acquired++;
          return () {
            released++;
          };
        },
        onDatabaseRestored: () {
          refreshed++;
        },
      )));
    });
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('预览清理范围'));
    await tester.runAsync(() => tester.tap(find.text('预览清理范围')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.text('确认清理范围（1/2）'), findsOneWidget);
  }

  Future<void> settleIo(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('零匹配只展示提示且不执行', (tester) async {
    await tester.runAsync(() => database.setReceiptSettled(receiptId, false));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: DataManagementPage(
        database: database,
        acquireMaintenance: () async {
          acquired++;
          return () {
            released++;
          };
        },
        onDatabaseRestored: () {
          refreshed++;
        },
      )));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('预览清理范围'));
    await tester.runAsync(() => tester.tap(find.text('预览清理范围')));
    await settleIo(tester);
    expect(find.text('没有可清理的记录'), findsOneWidget);
    expect(find.text('彻底清除'), findsNothing);
    await tester.tap(find.text('知道了'));
    await settleIo(tester);
    expect((await tester.runAsync(database.loadInboundHistory))!.length, 1);
    expect(refreshed, 0);
    expect(released, 1);
  });

  testWidgets('取消第一确认不删除且恢复维护租约', (tester) async {
    await open(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(database.loadInboundHistory))!.length, 1);
    expect(acquired, 1);
    expect(released, 1);
    expect(refreshed, 0);
  });

  testWidgets('取消第二确认不删除且恢复维护租约', (tester) async {
    await open(tester);
    await tester.tap(find.text('继续确认'));
    await settleIo(tester);
    expect(find.text('彻底清除本机数据（2/2）'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(database.loadInboundHistory))!.length, 1);
    expect(released, 1);
    expect(refreshed, 0);
  });

  testWidgets('仅第二确认执行一次并保留库存', (tester) async {
    await open(tester);
    await tester.tap(find.text('继续确认'));
    await settleIo(tester);
    expect((await tester.runAsync(database.loadInboundHistory))!.length, 1);
    await tester.runAsync(() => tester.tap(find.text('彻底清除')));
    await settleIo(tester);
    expect(find.text('本机清理完成'), findsOneWidget);
    expect(await tester.runAsync(database.loadInboundHistory), isEmpty);
    expect(
        (await tester.runAsync(database.loadStockTotals))!.single.quantity, 2);
    expect(refreshed, 1);
    await tester.tap(find.text('完成'));
    await settleIo(tester);
    expect(released, 1);
  });

  testWidgets('预览后记录变化拒绝执行并恢复租约', (tester) async {
    await open(tester);
    await tester.tap(find.text('继续确认'));
    await settleIo(tester);
    await tester.runAsync(() => database.setReceiptSettled(receiptId, false));
    await tester.runAsync(() => tester.tap(find.text('彻底清除')));
    await settleIo(tester);
    expect(find.text('记录已经变化，未执行清理。请重新预览确认。'), findsOneWidget);
    expect((await tester.runAsync(database.loadInboundHistory))!.length, 1);
    expect(refreshed, 0);
    expect(released, 1);
  });
}
