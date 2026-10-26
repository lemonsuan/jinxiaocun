import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../domain/express_capture.dart';

/// A single decode, EXIF orientation correction, crop and JPEG encode off the UI isolate.
Uint8List cropCaptureJpeg(Map<String, Object> input) {
  final decoded = img.decodeImage(input['bytes'] as Uint8List);
  if (decoded == null) throw const FormatException('无法读取拍摄照片');
  final image = img.bakeOrientation(decoded);
  var crop = CaptureCrop.fromMap(input['crop'] as Map);
  final previewAspect = input['previewAspect'] as double?;
  if (previewAspect != null && previewAspect > 0) {
    final physicalAspect = image.width / image.height;
    if (previewAspect > physicalAspect) {
      final visibleHeight = physicalAspect / previewAspect;
      final offset = (1 - visibleHeight) / 2;
      crop = CaptureCrop(crop.left, offset + crop.top * visibleHeight,
          crop.right, offset + crop.bottom * visibleHeight);
    } else {
      final visibleWidth = previewAspect / physicalAspect;
      final offset = (1 - visibleWidth) / 2;
      crop = CaptureCrop(offset + crop.left * visibleWidth, crop.top,
          offset + crop.right * visibleWidth, crop.bottom);
    }
  }
  final x = (crop.left * image.width).round().clamp(0, image.width - 1);
  final y = (crop.top * image.height).round().clamp(0, image.height - 1);
  final right = (crop.right * image.width).round().clamp(x + 1, image.width);
  final bottom =
      (crop.bottom * image.height).round().clamp(y + 1, image.height);
  final result =
      img.copyCrop(image, x: x, y: y, width: right - x, height: bottom - y);
  return Uint8List.fromList(img.encodeJpg(result, quality: 95));
}

class CaptureImageProcessor {
  Future<String> process(String originalPath, CaptureCrop crop, String token,
      {double? previewAspect}) async {
    final source = File(originalPath);
    final bytes = await source.readAsBytes();
    final output = await compute(cropCaptureJpeg, <String, Object>{
      'bytes': bytes,
      'crop': crop.toMap(),
      if (previewAspect != null) 'previewAspect': previewAspect
    });
    final result = File('$originalPath.$token.crop.jpg');
    final temp = File('${result.path}.tmp');
    await temp.writeAsBytes(output, flush: true);
    await temp.rename(result.path);
    return result.path;
  }
}
