import 'package:flutter/material.dart';
import '../domain/express_capture.dart';

/// 顶部信息保持固定高度，扫码与锁号切换不挤动原生相机。
class ExpressTrackingHeader extends StatelessWidget {
  const ExpressTrackingHeader({super.key, this.trackingNumber});
  final String? trackingNumber;

  @override
  Widget build(BuildContext context) {
    final tracking = trackingNumber;
    return SizedBox(
      height: 96,
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: tracking == null
            ? const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_scanner,
                      color: Color(0xFF7B7B77), size: 22),
                  SizedBox(height: 8),
                  Text('等待扫描快递条码',
                      style: TextStyle(
                          color: Color(0xFF252525),
                          fontSize: 16,
                          fontWeight: FontWeight.w500)),
                ],
              )
            : Column(
                children: [
                  const Text('快递单号',
                      style: TextStyle(color: Color(0xFF7B7B77), fontSize: 11)),
                  const SizedBox(height: 5),
                  Expanded(
                    child: SingleChildScrollView(
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(tracking,
                            key: const ValueKey('express_tracking_number'),
                            textAlign: TextAlign.center,
                            softWrap: true,
                            style: TextStyle(
                                color: const Color(0xFF252525),
                                fontSize: tracking.length > 32 ? 16 : 22,
                                height: 1.2,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 只重绘轻量遮罩与角标，底层相机子树在不同状态下始终留在原位。
class ExpressCameraFrame extends StatelessWidget {
  const ExpressCameraFrame({
    super.key,
    required this.child,
    required this.locked,
    required this.crop,
    this.showSaved = false,
  });
  final Widget child;
  final bool locked;
  final CaptureCrop crop;
  final bool showSaved;

  @override
  Widget build(BuildContext context) => ClipRect(
        child: Stack(fit: StackFit.expand, children: [
          child,
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('express_camera_guide'),
                painter: ExpressCameraGuidePainter(locked: locked, crop: crop),
              ),
            ),
          ),
          if (showSaved)
            const IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xD9252525)),
                    child: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_circle_outline,
                            color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text('已拍好，可以移开',
                            style:
                                TextStyle(color: Colors.white, fontSize: 12)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class ExpressCameraGuidePainter extends CustomPainter {
  const ExpressCameraGuidePainter({required this.locked, required this.crop});
  final bool locked;
  final CaptureCrop crop;

  /// 拍摄框直接使用发给原生相机的归一化裁剪参数。
  Rect frameFor(Size size) => locked
      ? Rect.fromLTRB(crop.left * size.width, crop.top * size.height,
          crop.right * size.width, crop.bottom * size.height)
      : Rect.fromLTWH(size.width * .05, size.height * .34, size.width * .9,
          size.height * .32);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = frameFor(size);
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(rect);
    canvas.drawPath(mask, Paint()..color = const Color(0x99000000));
    final line = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = .7
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, line);
    final corner = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final length = rect.shortestSide.clamp(0, 24).toDouble();
    final corners = Path()
      ..moveTo(rect.left, rect.top + length)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + length, rect.top)
      ..moveTo(rect.right - length, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + length)
      ..moveTo(rect.right, rect.bottom - length)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - length, rect.bottom)
      ..moveTo(rect.left + length, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - length);
    canvas.drawPath(corners, corner);
  }

  @override
  bool shouldRepaint(ExpressCameraGuidePainter oldDelegate) =>
      locked != oldDelegate.locked ||
      crop.left != oldDelegate.crop.left ||
      crop.top != oldDelegate.crop.top ||
      crop.right != oldDelegate.crop.right ||
      crop.bottom != oldDelegate.crop.bottom;
}
