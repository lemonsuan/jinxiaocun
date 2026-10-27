import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/platform/paddle_ocr_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('inventory_app/paddle_ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('keeps native raw text for editable OCR review', () async {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      expect(call.method, 'recognizeTable');
      expect(call.arguments, <String, Object?>{
        'imagePath': '/tmp/list.jpg',
        'rowMergeTolerance': 0.3,
      });
      return <String, Object?>{
        'rows': <List<String>>[
          <String>['A100', '测试商品', '2'],
        ],
        'rawText': '原始识别文本\nA100 测试商品 2',
      };
    });

    final result = await PaddleOcrChannel().recognizeTable('/tmp/list.jpg');

    expect(result.rawText, '原始识别文本\nA100 测试商品 2');
    expect(result.editableText, '原始识别文本\nA100 测试商品 2');
    expect(result.rows.single, <String>['A100', '测试商品', '2']);
  });

  test('falls back to grouped rows when native raw text is absent', () async {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      return <String, Object?>{
        'rows': <List<String>>[
          <String>['A100', '测试商品', '2'],
        ],
      };
    });

    final result = await PaddleOcrChannel().recognizeTable('/tmp/list.jpg');

    expect(result.rawText, isEmpty);
    expect(result.editableText, 'A100\t测试商品\t2');
  });

  test('passes custom OCR row merge tolerance to native', () async {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      expect(call.arguments, <String, Object?>{
        'imagePath': '/tmp/list.jpg',
        'rowMergeTolerance': 0.2,
      });
      return <String, Object?>{
        'rows': <List<String>>[],
        'rawText': '',
      };
    });

    await PaddleOcrChannel().recognizeTable(
      '/tmp/list.jpg',
      rowMergeTolerance: 0.12,
    );
  });

  test('native inference failure propagates instead of becoming product text',
      () async {
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      throw PlatformException(
          code: 'OCR_INFERENCE_FAILED', message: '识别失败，请重试');
    });
    await expectLater(
      PaddleOcrChannel().recognizeTable('/tmp/list.jpg'),
      throwsA(isA<PlatformException>()
          .having((e) => e.code, 'code', 'OCR_INFERENCE_FAILED')),
    );
  });
}
