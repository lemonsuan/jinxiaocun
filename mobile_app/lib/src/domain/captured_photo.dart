import 'express_capture.dart';

/// 相机抓拍完成的原始交接对象。
///
/// 遵循极速录单解耦原则：相机原生捕获完成并写入本地原图后立即返回此对象，
/// 仅携带已落盘的原图路径与取景框参数，繁重的像素级裁剪与 OCR 识别交由调用方后台延迟队列处理。
class CapturedPhoto {
  const CapturedPhoto({
    required this.imagePath,
    this.crop = CaptureCrop.full,
    this.previewAspect,
  });

  /// 原始照片在本地文件系统中的绝对路径。
  final String imagePath;

  /// 相对归一化裁剪矩形（0.0 ~ 1.0）。
  final CaptureCrop crop;

  /// 相机取景框的宽高比例，用于后续裁剪时校准变形。
  final double? previewAspect;
}
