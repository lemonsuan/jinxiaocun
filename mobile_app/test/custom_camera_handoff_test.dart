import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/application/capture_work_coordinator.dart';
import 'package:inventory_mobile_app/src/domain/captured_photo.dart';
import 'package:inventory_mobile_app/src/ui/custom_camera_page.dart';

void main() {
  testWidgets('普通相机失败可重试，保存前无成功反馈，原图交接后释放租约', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const camera = MethodChannel('plugins.flutter.io/camera');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final directory = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('camera_handoff_')))!;
    final raw = File('${directory.path}/original.jpg');
    await tester.runAsync(() => raw.writeAsBytes([0xff, 0xd8, 0xff, 0xd9]));
    final ready = Completer<void>();
    var saved = Completer<String>();
    final haptics = <String>[];
    final cameraCalls = <String>[];
    var captureCalls = 0;
    CapturedPhoto? result;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(camera, (call) async {
      cameraCalls.add(call.method);
      switch (call.method) {
        case 'availableCameras':
          return [
            {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90}
          ];
        case 'create':
          return {'cameraId': 22};
        case 'initialize':
          final done = Completer<void>();
          messenger.handlePlatformMessage(
              'flutter.io/cameraPlugin/camera22',
              const StandardMethodCodec()
                  .encodeMethodCall(const MethodCall('initialized', {
                'previewWidth': 1280.0,
                'previewHeight': 720.0,
                'exposureMode': 'auto',
                'exposurePointSupported': true,
                'focusMode': 'auto',
                'focusPointSupported': true,
              })),
              (_) => done.complete());
          await done.future;
          return null;
        case 'setFocusMode':
          if (!ready.isCompleted) ready.complete();
          return null;
        case 'takePicture':
          captureCalls++;
          return saved.future;
        default:
          return null;
      }
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(camera, null);
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        result = await Navigator.of(context)
                            .push<CapturedPhoto>(MaterialPageRoute(
                                builder: (_) => const CustomCameraPage()));
                      },
                      child: const Text('打开相机')),
                ))));
    await tester.tap(find.text('打开相机'));
    await tester.pump();
    for (var attempt = 0; attempt < 30 && !ready.isCompleted; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump();
    }
    expect(ready.isCompleted, true, reason: '相机调用：$cameraCalls');
    await tester.pumpAndSettle();
    expect(CaptureWorkCoordinator.instance.isActive, true);
    await tester.tap(find.byIcon(Icons.camera_alt_outlined));
    await tester.pump();
    expect(captureCalls, 1);
    expect(haptics, isEmpty);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.text('已拍好，可以移开'), findsNothing);
    expect(find.text('正在保存，请保持稳定'), findsOneWidget);
    saved.completeError(
        PlatformException(code: 'SAVE_FAILED', message: '测试保存失败'));
    await tester.pump();
    expect(haptics, isEmpty);
    expect(result, isNull);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(CaptureWorkCoordinator.instance.isActive, true);
    saved = Completer<String>();
    await tester.tap(find.byIcon(Icons.camera_alt_outlined));
    await tester.pump();
    expect(captureCalls, 2);
    expect(haptics, isEmpty);
    saved.complete(raw.path);
    for (var attempt = 0; attempt < 60 && result == null; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(result?.imagePath, raw.path);
    expect(result?.previewAspect, greaterThan(0));
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(CaptureWorkCoordinator.instance.isActive, false);
    expect(raw.readAsBytesSync(), [0xff, 0xd8, 0xff, 0xd9]);
    expect(tester.takeException(), isNull);
  });
}
