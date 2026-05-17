import 'package:flutter/services.dart';

class ScannerChannel {
  static const MethodChannel _channel = MethodChannel('inventory_app/scanner');

  Future<String?> scanTrackingNumber() async {
    final value = await _channel.invokeMethod<String>('scanTrackingNumber');
    return value?.trim();
  }
}
