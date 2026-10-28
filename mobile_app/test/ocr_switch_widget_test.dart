import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/captured_photo.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ui/app_home.dart';
import 'package:inventory_mobile_app/src/ui/custom_camera_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('仅图草稿在开关重新开启后仍待补录，原图绑定前不能确认', (tester) async {
    sqfliteFfiInit();
    final root = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('ocr-widget-')))!;
    final db =
        LocalInventoryDatabase(directory: root, factory: databaseFactoryFfi);
    await tester.runAsync(() async {
      await db.open();
      await db.saveOcrEnabled(false);
    });
    final photo = File('${root.path}/original.jpg');
    await tester.runAsync(() =>
        photo.writeAsBytes(img.encodeJpg(img.Image(width: 12, height: 16))));
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const camera = MethodChannel('plugins.flutter.io/camera');
    const ocr = MethodChannel('inventory_app/paddle_ocr');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(
        camera, (call) async => call.method == 'availableCameras' ? [] : null);
    var ocrCalls = 0;
    messenger.setMockMethodCallHandler(ocr, (_) async {
      ocrCalls++;
      return {'rows': [], 'rawText': ''};
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(camera, null);
      messenger.setMockMethodCallHandler(ocr, null);
      await db.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(home: AppHome(database: db)));
    for (var i = 0; i < 60 && find.text('拍照保存').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump();
    }
    expect(find.text('拍照保存'), findsOneWidget);
    final tracking = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '输入或扫描快递单号');
    await tester.enterText(tracking, 'OTHER-COURIER-WIDGET');
    await tester.tap(find.text('拍照保存'));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.byType(CustomCameraPage)))
        .pop(CapturedPhoto(imagePath: photo.path));
    await tester.pump();
    final confirm = find.ancestor(
        of: find.text('确认入库'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton));
    expect(tester.widget<OutlinedButton>(confirm).onPressed, isNull);
    for (var i = 0;
        i < 80 && tester.widget<OutlinedButton>(confirm).onPressed == null;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(ocrCalls, 0);
    expect(tester.widget<OutlinedButton>(confirm).onPressed, isNotNull);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('ocr-enabled-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump();
      if (await tester.runAsync(db.loadOcrEnabled) == true) break;
    }
    await tester.pumpAndSettle();
    expect(await tester.runAsync(db.loadOcrEnabled), true);
    await tester.tap(find.text('扫码入库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认入库'));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump();
      if ((await tester.runAsync(db.loadInboundHistory))!.isNotEmpty) break;
    }
    final receipt = (await tester.runAsync(db.loadInboundHistory))!.single;
    expect(receipt.ocrStatus, OcrStatus.needsReview);
    expect(receipt.trackingNumber, 'OTHER-COURIER-WIDGET');
    expect(receipt.items, isEmpty);
    expect(await tester.runAsync(() => File(receipt.imagePath!).readAsBytes()),
        await tester.runAsync(photo.readAsBytes));
    expect(await tester.runAsync(db.loadStockTotals), isEmpty);
    expect(ocrCalls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
