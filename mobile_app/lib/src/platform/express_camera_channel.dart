import 'package:flutter/services.dart';
import '../domain/express_capture.dart';

class SavedExpressCapture {
  const SavedExpressCapture(
      {required this.captureId,
      required this.trackingNumber,
      required this.imagePath,
      required this.shutterToSavedMs,
      required this.crop});
  final String captureId, trackingNumber, imagePath;
  final int shutterToSavedMs;
  final CaptureCrop crop;
}

/// Parses only the project-owned native bridge, never camera preview frames.
class ExpressCameraChannel {
  ExpressCameraChannel(int viewId)
      : channel = MethodChannel('inventory_app/express_camera/$viewId');
  static const viewType = 'inventory_app/express_camera';
  final MethodChannel channel;
  void Function()? onReady;
  void Function(String)? onTracking;
  void Function(SavedExpressCapture)? onCaptured;
  void Function(String code, String message, String? captureId)? onError;
  bool _disposed = false;
  void listen() => channel.setMethodCallHandler((call) async {
        if (_disposed) return;
        final args = call.arguments is Map ? call.arguments as Map : const {};
        switch (call.method) {
          case 'onReady':
            onReady?.call();
          case 'onTracking':
            final tracking = args['trackingNumber'];
            if (tracking is String && tracking.trim().isNotEmpty) {
              onTracking?.call(tracking.trim());
            }
          case 'onCaptured':
            final id = args['captureId'];
            final tracking = args['trackingNumber'];
            final path = args['imagePath'];
            if (id is! String ||
                tracking is! String ||
                path is! String ||
                id.isEmpty ||
                tracking.isEmpty ||
                path.isEmpty) {
              onError?.call('INVALID_CAPTURE', '相机返回的照片信息不完整，请重试', null);
              return;
            }
            if ((args['shutterToSavedMs'] != null &&
                    args['shutterToSavedMs'] is! num) ||
                (args['crop'] != null && args['crop'] is! Map)) {
              onError?.call('INVALID_CAPTURE', '照片参数异常，请重试拍摄', id);
              return;
            }
            onCaptured?.call(SavedExpressCapture(
                captureId: id,
                trackingNumber: tracking,
                imagePath: path,
                shutterToSavedMs:
                    (args['shutterToSavedMs'] as num?)?.toInt() ?? 0,
                crop: CaptureCrop.fromMap(args['crop'] as Map?)));
          case 'onError':
            onError?.call(
                args['code']?.toString() ?? 'CAMERA_ERROR',
                args['message']?.toString() ?? '相机异常，请重试',
                args['captureId']?.toString());
        }
      });
  Future<void> capture(String id, String tracking, CaptureCrop crop) =>
      channel.invokeMethod('capture',
          {'captureId': id, 'trackingNumber': tracking, 'crop': crop.toMap()});
  Future<void> reset() => channel.invokeMethod('reset');
  Future<void> setTorch(bool enabled) =>
      channel.invokeMethod('setTorch', {'enabled': enabled});
  Future<void> focus(double x, double y) =>
      channel.invokeMethod('focus', {'x': x, 'y': y});
  Future<void> pause() => channel.invokeMethod('pause');
  Future<void> resume() => channel.invokeMethod('resume');
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await channel.invokeMethod('dispose');
    } finally {
      channel.setMethodCallHandler(null);
    }
  }
}
