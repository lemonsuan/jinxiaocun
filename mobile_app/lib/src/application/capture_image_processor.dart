import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import '../domain/express_capture.dart';

/// 图像后台裁剪与方向校准处理函数。
///
/// 在独立的计算隔离区（Isolate）中执行单一流程处理：
/// 1. 解码原始 JPEG 字节流；
/// 2. 烘焙并纠正 EXIF 拍摄方向旋转角度；
/// 3. 根据相机取景预览比例与裁剪框参数计算物理像素选区；
/// 4. 裁剪并重新编码为高画质（quality: 95）JPEG 二进制字节流；
/// 避免在 Flutter UI 主线程中执行耗时的像素级位图操作导致界面掉帧。
Uint8List cropCaptureJpeg(Map<String, Object> input) {
  final decoded = img.decodeImage(input['bytes'] as Uint8List);
  if (decoded == null) throw const FormatException('无法读取拍摄照片');
  final oriented = img.bakeOrientation(decoded);
  final quarterTurns = input['quarterTurns'] as int? ?? 0;
  final image = quarterTurns % 4 == 0
      ? oriented
      : img.copyRotate(oriented, angle: (quarterTurns % 4) * 90);
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

/// 拍摄图像后台异步处理器。
///
/// 负责读取原始抓拍照片文件，将计算繁重的旋转校准与选区裁剪委托给后台 Isolate，
/// 并通过原子写入（写临时文件后 rename 重命名）保证目标文件生成过程中防损坏。
class CaptureImageProcessor {
  /// 异步处理单张原始抓拍照片。
  ///
  /// [originalPath] 原始照片文件路径；
  /// [crop] 相对归一化裁剪矩形；
  /// [token] 本次处理的唯一流水标识；
  /// [previewAspect] 相机取景框的宽高比；
  /// [quarterTurns] 90度的倍数旋转步数；
  /// 返回裁剪校准后生成的新图片文件完整路径。
  Future<String> process(String originalPath, CaptureCrop crop, String token,
      {double? previewAspect, int quarterTurns = 0}) async {
    final source = File(originalPath);
    final bytes = await source.readAsBytes();
    final output = await compute(cropCaptureJpeg, <String, Object>{
      'bytes': bytes,
      'crop': crop.toMap(),
      'quarterTurns': quarterTurns,
      if (previewAspect != null) 'previewAspect': previewAspect
    });
    final result = File('$originalPath.$token.crop.jpg');
    final temp = File('${result.path}.tmp');
    await temp.writeAsBytes(output, flush: true);
    await temp.rename(result.path);
    return result.path;
  }
}
