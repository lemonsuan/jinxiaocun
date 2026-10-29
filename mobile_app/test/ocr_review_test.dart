import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ui/app_home.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('独立内存设备不共享OCR开关，同一数据库包装保留关闭状态', () async {
    final connections = <Database>[];
    addTearDown(() async {
      for (final connection in connections) {
        await connection.close();
      }
    });
    Future<LocalInventoryDatabase> open() async {
      final sqlite = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false));
      connections.add(sqlite);
      for (final sql in LocalDatabaseSchema.createStatements) {
        await sqlite.execute(sql);
      }
      return LocalInventoryDatabase(database: sqlite);
    }

    final first = await open();
    final second = await open();
    await first.saveOcrEnabled(false);
    expect(await first.loadOcrEnabled(), false);
    expect(await second.loadOcrEnabled(), true);
    final sameDevice = LocalInventoryDatabase(database: connections.first);
    expect(await sameDevice.loadOcrEnabled(), false);
  });

  for (final forceClose in [false, true]) {
    testWidgets(
        forceClose
            ? '历史弹窗强制返回后，退出动画期间迟到结果不再更新界面'
            : '历史重识别处理中系统返回不关闭弹窗，结果返回后可安全退出', (tester) async {
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      final directory = (await tester
          .runAsync(() => Directory.systemTemp.createTemp('ocr-dialog-')))!;
      final database = LocalInventoryDatabase(
          directory: directory, factory: databaseFactoryFfi);
      final source = File('${directory.path}/original.jpg');
      await tester.runAsync(() async {
        await database.open();
        await source
            .writeAsBytes(img.encodeJpg(img.Image(width: 16, height: 24)));
        await database.confirmInbound(
            trackingNumber: 'REVIEW-GUARD-001',
            items: const [
              InboundDraftItem(
                  productCode: '100001', productName: '测试商品', quantity: 2)
            ],
            imagePath: source.path);
      });
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const ocr = MethodChannel('inventory_app/paddle_ocr');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final entered = Completer<void>();
      final response = Completer<Map<String, Object>>();
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      messenger.setMockMethodCallHandler(ocr, (_) {
        entered.complete();
        return response.future;
      });
      addTearDown(() async {
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(ocr, null);
        await database.close();
        await directory.delete(recursive: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(MaterialApp(home: AppHome(database: database)));
      for (var attempt = 0;
          attempt < 80 && find.text('拍照识别').evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump();
      }
      await tester.tap(find.text('历史入库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('快递：REVIEW-GUARD-001'));
      await tester.pumpAndSettle();
      final recognize = find.text('重新识别');
      await tester.ensureVisible(recognize);
      await tester.tap(recognize);
      await tester.pumpAndSettle();
      expect(find.text('图片旋转与二次识别'), findsOneWidget);
      await tester.tap(find.text('开始识别'));
      for (var attempt = 0; attempt < 80 && !entered.isCompleted; attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)));
        await tester.pump();
      }
      expect(entered.isCompleted, true);
      await tester.pump();
      if (forceClose) {
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pump();
      expect(find.text('图片旋转与二次识别'), findsOneWidget);
      response.complete({
        'rows': [
          ['100001', '测试商品', '2']
        ],
        'rawText': '100001 测试商品 2'
      });
      if (forceClose) {
        // 不推进退出动画，验证路由已返回而组件尚挂载的时间窗。
        for (var attempt = 0; attempt < 20; attempt++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 2)));
          await tester.pump();
        }
        expect(find.text('确认覆写清单'), findsNothing);
        await tester.pumpAndSettle();
      } else {
        for (var attempt = 0;
            attempt < 80 && find.text('确认覆写清单').evaluate().isEmpty;
            attempt++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 2)));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(find.text('确认覆写清单'), findsOneWidget);
        await tester.tap(find.descendant(
            of: find.byType(Dialog), matching: find.byIcon(Icons.close)));
        await tester.pumpAndSettle();
      }
      expect(find.text('图片旋转与二次识别'), findsNothing);
      expect((await tester.runAsync(database.loadStockTotals))!.single.quantity,
          2);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
