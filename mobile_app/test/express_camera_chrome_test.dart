import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/domain/express_capture.dart';
import 'package:inventory_mobile_app/src/ui/express_camera_chrome.dart';

const crop = CaptureCrop(.04, .12, .96, .88);

void main() {
  testWidgets('完整长单号居中换行，窄屏大字体不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tracking = List.filled(5, 'SF1234567890123456789').join();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: Scaffold(body: ExpressTrackingHeader(trackingNumber: tracking)),
      ),
    ));
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('express_tracking_number')));
    expect(text.data, tracking);
    expect(text.textAlign, TextAlign.center);
    expect(text.softWrap, true);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.takeException(), isNull);
  });

  testWidgets('扫码锁号及保存只更新覆盖层，不重建或调整原生预览尺寸', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform_views,
        (call) async {
      calls.add(call);
      if (call.method == 'create') return 1;
      if (call.method == 'resize') {
        final data = call.arguments as Map;
        return {'width': data['width'], 'height': data['height']};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(
        SystemChannels.platform_views, null));
    Widget page(bool locked, bool saved) => MaterialApp(
            home: Scaffold(
          body: Center(
              child: SizedBox(
            width: 328,
            height: 440,
            child: ExpressCameraFrame(
              locked: locked,
              crop: crop,
              showSaved: saved,
              child: const AndroidView(
                  key: ValueKey('same_camera'), viewType: 'test-camera'),
            ),
          )),
        ));
    await tester.pumpWidget(page(false, false));
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(AndroidView));
    final size = tester.getSize(find.byType(AndroidView));
    expect(calls.where((call) => call.method == 'create'), hasLength(1));
    for (final state in [(true, false), (true, true), (false, false)]) {
      await tester.pumpWidget(page(state.$1, state.$2));
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(AndroidView)), same(element));
      expect(tester.getSize(find.byType(AndroidView)), size);
    }
    expect(calls.where((call) => call.method == 'create'), hasLength(1));
    expect(calls.where((call) => call.method == 'resize'), isEmpty);
    final painter = tester
        .widget<CustomPaint>(find.byKey(const ValueKey('express_camera_guide')))
        .painter as ExpressCameraGuidePainter;
    expect(painter.locked, false);
    const lockedPainter = ExpressCameraGuidePainter(locked: true, crop: crop);
    expect(
        lockedPainter.frameFor(size),
        Rect.fromLTRB(size.width * .04, size.height * .12, size.width * .96,
            size.height * .88));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('导出扫码与居中单号视觉样张', (tester) async {
    await tester.runAsync(() async {
      // 本机样张使用系统字体；其他平台不依赖该可选文件。
      final font = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
      if (await font.exists()) {
        final loader = FontLoader('ExpressPreview')
          ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundaryKey = GlobalKey();
    for (final locked in [false, true]) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(useMaterial3: true, fontFamily: 'ExpressPreview'),
        home: RepaintBoundary(
            key: boundaryKey,
            child: Scaffold(
              backgroundColor: Colors.white,
              appBar: AppBar(
                  backgroundColor: Colors.white,
                  surfaceTintColor: Colors.transparent,
                  centerTitle: true,
                  title: const Text('极速入库', style: TextStyle(fontSize: 15)),
                  leading: const Icon(Icons.arrow_back)),
              body: SafeArea(
                  top: false,
                  child: Column(children: [
                    ExpressTrackingHeader(
                        trackingNumber:
                            locked ? 'SF1234567890123456789' : null),
                    Expanded(
                        child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ExpressCameraFrame(
                          locked: locked,
                          crop: crop,
                          child: const ColoredBox(color: Color(0xFF5B625B))),
                    )),
                    SizedBox(
                        height: 48,
                        child: Center(
                            child: Text(locked ? '单号已锁定' : '等待识别快递单号',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF777773))))),
                    SizedBox(
                        height: 80,
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              const Icon(Icons.flash_off, size: 22),
                              if (locked)
                                const CircleAvatar(
                                    radius: 35,
                                    backgroundColor: Color(0xFF252525),
                                    child: Icon(Icons.camera_alt_outlined,
                                        color: Colors.white, size: 28))
                              else
                                const Text('等待识别',
                                    style: TextStyle(
                                        color: Colors.grey, fontSize: 12)),
                              Icon(
                                  locked
                                      ? Icons.qr_code_scanner
                                      : Icons.flash_off,
                                  color: locked
                                      ? const Color(0xFF555551)
                                      : Colors.transparent,
                                  size: 22),
                            ])),
                    const SizedBox(
                        height: 74,
                        child: Center(
                            child: Text('最近入库 · 暂无记录',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey)))),
                  ])),
            )),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/express-ui-${locked ? 'locked' : 'scan'}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
