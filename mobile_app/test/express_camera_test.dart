import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inventory_mobile_app/src/application/capture_image_processor.dart';
import 'package:inventory_mobile_app/src/application/express_capture_state.dart';
import 'package:inventory_mobile_app/src/application/express_receipt_committer.dart';
import 'package:inventory_mobile_app/src/application/express_processing_queue.dart';
import 'package:inventory_mobile_app/src/domain/express_capture.dart';
import 'package:inventory_mobile_app/src/platform/express_camera_channel.dart';

SavedExpressCapture photo(String id, String tracking) => SavedExpressCapture(
    captureId: id,
    trackingNumber: tracking,
    imagePath: '/app/$id.jpg',
    shutterToSavedMs: 100,
    crop: CaptureCrop.full);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'concurrent receipt retries share one save and failed save remains retryable',
      () async {
    final committer = ExpressReceiptCommitter();
    final blocked = Completer<void>();
    var calls = 0;
    Future<void> save() {
      calls++;
      return blocked.future;
    }

    final first = committer.saveOnce('same', save);
    final second = committer.saveOnce('same', save);
    expect(calls, 1);
    blocked.complete();
    await Future.wait([first, second]);
    expect(committer.isSaved('same'), true);
  });
  test('scanner reset failure never repeats a committed receipt', () async {
    final committer = ExpressReceiptCommitter();
    var inserts = 0;
    Future<void> save() async {
      inserts++;
    }

    await committer.saveOnce('capture1', save);
    Future<void> unlock() async {
      throw StateError('camera unavailable');
    }

    await expectLater(unlock(), throwsStateError);
    await committer.saveOnce('capture1', save);
    expect(inserts, 1);
    await committer.saveOnce('capture2', save);
    expect(inserts, 2);
  });
  test('failed receipt insert can retry the same saved capture', () async {
    final committer = ExpressReceiptCommitter();
    await expectLater(
        committer.saveOnce('capture', () async {
          throw StateError('disk');
        }),
        throwsStateError);
    expect(committer.isSaved('capture'), false);
    await committer.saveOnce('capture', () async {});
    expect(committer.isSaved('capture'), true);
  });
  test(
      'saved-photo event must match capture and tracking; errors never mean success',
      () {
    final s = ExpressCaptureState()..ready();
    expect(s.lock('SF12345678901234567890'), true);
    expect(s.begin('first'), true);
    expect(s.savedCapture, isNull);
    expect(s.begin('double'), false);
    expect(s.accept(photo('old', 'SF12345678901234567890')), false);
    expect(s.accept(photo('first', 'wrong')), false);
    s.failed();
    expect(s.savedCapture, isNull);
    expect(s.begin('retry'), true);
    expect(s.accept(photo('retry', 'SF12345678901234567890')), true);
    expect(s.phase, ExpressCapturePhase.saving);
    expect(s.accept(photo('retry', 'SF12345678901234567890')), false);
    s.reset();
    expect(s.trackingNumber, 'SF12345678901234567890');
    s.committed();
    s.reset();
    expect(s.trackingNumber, isNull);
    expect(s.savedCapture, isNull);
    expect(s.lock('next'), true);
    expect(s.trackingNumber, 'next');
  });
  test('cancel clears identity; commit failure retains saved photo for retry',
      () {
    final s = ExpressCaptureState()
      ..ready()
      ..lock('old');
    s.reset();
    expect(s.trackingNumber, isNull);
    s.lock('new');
    s.begin('image');
    s.accept(photo('image', 'new'));
    s.failed();
    expect(s.savedCapture!.trackingNumber, 'new');
    expect(s.begin('reshoot'), false);
  });
  test('capture request acknowledgement is not success; only saved event is',
      () async {
    final camera = ExpressCameraChannel(13);
    var success = 0;
    var errors = 0;
    camera.onError = (_, __, ___) => errors++;
    camera.onCaptured = (_) => success++;
    camera.listen();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(camera.channel, (_) async => null);
    await camera.capture('id', 'SF123', CaptureCrop.full);
    expect(success, 0);
    Future<void> event(String name, Map<String, Object> args) async {
      final c = Completer<void>();
      messenger.handlePlatformMessage(
          camera.channel.name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(name, args)),
          (_) => c.complete());
      await c.future;
    }

    await event(
        'onError', {'code': 'FAILED', 'message': 'failure', 'captureId': 'id'});
    expect(success, 0);
    await event('onCaptured', {
      'captureId': 'id',
      'trackingNumber': 'SF123',
      'imagePath': '/app/id.jpg',
      'shutterToSavedMs': 240,
      'crop': CaptureCrop.full.toMap()
    });
    expect(success, 1);
    await camera.dispose();
    messenger.setMockMethodCallHandler(camera.channel, null);
  });
  test('durable runner bounds concurrency to one and drains arriving backlog',
      () async {
    final pending = [1];
    final first = Completer<void>();
    var active = 0;
    var maxActive = 0;
    final done = <int>[];
    final runner = DurableSerialRunner<int>(
        next: () async => pending.isEmpty ? null : pending.removeAt(0),
        process: (job) async {
          active++;
          if (active > maxActive) {
            maxActive = active;
          }
          if (job == 1) {
            await first.future;
          }
          done.add(job);
          active--;
        },
        onError: (e, _) => fail('$e'));
    final drain = runner.kick();
    await Future<void>.delayed(Duration.zero);
    pending.addAll(List.generate(20, (i) => i + 2));
    unawaited(runner.kick());
    first.complete();
    await drain;
    expect(maxActive, 1);
    expect(done, List.generate(21, (i) => i + 1));
  });
  test(
      'crop is JPEG and preserves requested region; invalid coordinates keep full frame',
      () {
    final image = img.Image(width: 80, height: 60);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    img.fillRect(image,
        x1: 40, y1: 0, x2: 79, y2: 59, color: img.ColorRgb8(0, 0, 255));
    final bytes = Uint8List.fromList(img.encodeJpg(image, quality: 100));
    final output = cropCaptureJpeg(
        {'bytes': bytes, 'crop': const CaptureCrop(.5, 0, 1, 1).toMap()});
    expect(output.take(2).toList(), [0xff, 0xd8]);
    final crop = img.decodeJpg(output)!;
    expect(crop.width, 40);
    expect(crop.height, 60);
    expect(crop.getPixel(20, 30).b, greaterThan(240));
    final full = cropCaptureJpeg({
      'bytes': bytes,
      'crop': {'left': double.nan}
    });
    expect(img.decodeJpg(full)!.width, 80);
  });
  test('EXIF rotation is baked before crop coordinates', () {
    final image = img.Image(width: 80, height: 60);
    image.exif.imageIfd.orientation = 6;
    final output = cropCaptureJpeg({
      'bytes': Uint8List.fromList(img.encodeJpg(image)),
      'crop': CaptureCrop.full.toMap()
    });
    final decoded = img.decodeJpg(output)!;
    expect(decoded.width, 60);
    expect(decoded.height, 80);
    expect(decoded.exif.imageIfd.orientation, isNot(6));
  });
}
