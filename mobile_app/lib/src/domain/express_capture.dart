import 'dart:convert';

class CaptureCrop {
  const CaptureCrop(this.left, this.top, this.right, this.bottom);
  static const full = CaptureCrop(0, 0, 1, 1);
  final double left, top, right, bottom;
  Map<String, double> toMap() => {
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
      };
  factory CaptureCrop.fromMap(Map<dynamic, dynamic>? value) {
    if (value == null) return full;
    double read(String key, double fallback) =>
        (value[key] is num ? (value[key] as num).toDouble() : fallback);
    final crop = CaptureCrop(
        read('left', 0), read('top', 0), read('right', 1), read('bottom', 1));
    if (![crop.left, crop.top, crop.right, crop.bottom]
            .every((v) => v.isFinite && v >= 0 && v <= 1) ||
        crop.left >= crop.right ||
        crop.top >= crop.bottom) {
      return full;
    }
    return crop;
  }
}

class ExpressImageJob {
  const ExpressImageJob(
      {required this.receiptId,
      required this.imagePath,
      required this.token,
      this.crop = CaptureCrop.full});
  final String receiptId, imagePath, token;
  final CaptureCrop crop;
  String get settingKey => 'express_image_job:$receiptId';
  String encode() => jsonEncode({
        'receiptId': receiptId,
        'imagePath': imagePath,
        'token': token,
        'crop': crop.toMap()
      });
  factory ExpressImageJob.decode(String value) {
    final map = jsonDecode(value) as Map<String, dynamic>;
    if (map['receiptId'] is! String ||
        (map['receiptId'] as String).isEmpty ||
        map['imagePath'] is! String ||
        (map['imagePath'] as String).isEmpty ||
        map['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(map['token'] as String)) {
      throw const FormatException('Invalid durable image job');
    }
    return ExpressImageJob(
        receiptId: map['receiptId'] as String,
        imagePath: map['imagePath'] as String,
        token: map['token'] as String,
        crop: CaptureCrop.fromMap(map['crop'] as Map?));
  }
}
