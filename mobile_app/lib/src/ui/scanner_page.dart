import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage>
    with SingleTickerProviderStateMixin {
  static const List<BarcodeFormat> _linearBarcodeFormats = [
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.codabar,
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.itf2of5,
    BarcodeFormat.itf2of5WithChecksum,
    BarcodeFormat.itf14,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
  ];

  final MobileScannerController _controller = MobileScannerController(
    formats: _linearBarcodeFormats,
  );
  bool _hasResult = false;

  late AnimationController _animationController;
  late Animation<double> _scanAnimation;

  @override
  void initState() {
    super.initState();
    // 呼吸式扫描线动画
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _scanAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    // 纯白作为扫描线与边角色
    final lineColor = Colors.white.withOpacity(0.9);

    const double scanWidth = 280;
    const double scanHeight = 180;
    final double scanLeft = (size.width - scanWidth) / 2;
    final double scanTop = (size.height - scanHeight) / 2.2;
    final scanRect = Rect.fromLTWH(scanLeft, scanTop, scanWidth, scanHeight);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. 扫码相机底层
          Positioned.fill(
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                if (_hasResult) return;
                final List<Barcode> barcodes = capture.barcodes;
                for (final barcode in barcodes) {
                  final rawValue = barcode.rawValue;
                  if (rawValue != null && rawValue.isNotEmpty) {
                    _hasResult = true;
                    Navigator.of(context).pop(rawValue);
                    break;
                  }
                }
              },
            ),
          ),

          // 2. 黑色半透明遮罩镂空视窗
          Positioned.fill(
            child: CustomPaint(
              painter: _ScannerMaskPainter(scanRect: scanRect),
            ),
          ),

          // 3. 极简定位直角与呼吸激光扫描线
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _scanAnimation,
              builder: (context, child) {
                return CustomPaint(
                  painter: _ScannerOverlayPainter(
                    scanRect: scanRect,
                    lineColor: lineColor,
                    animationValue: _scanAnimation.value,
                  ),
                );
              },
            ),
          ),

          // 4. 顶部直角毛玻璃返回键
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: _glassButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icons.arrow_back_ios_new,
            ),
          ),

          // 5. 底部直角毛玻璃控制面板（闪光灯、摄像头翻转）
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 36,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _glassButton(
                  onPressed: () => _controller.toggleTorch(),
                  icon: Icons.flashlight_on_outlined,
                  label: '闪光灯',
                ),
                const SizedBox(width: 24),
                _glassButton(
                  onPressed: () => _controller.switchCamera(),
                  icon: Icons.flip_camera_android_outlined,
                  label: '翻转',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _glassButton({
    required VoidCallback onPressed,
    required IconData icon,
    String? label,
  }) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: label != null ? 84 : 46,
          height: label != null ? 72 : 46,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            border: Border.all(color: Colors.white.withOpacity(0.2), width: 0.8),
            borderRadius: BorderRadius.zero,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 20),
                  if (label != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 绘制半透明遮罩与镂空矩形直角视窗
class _ScannerMaskPainter extends CustomPainter {
  final Rect scanRect;

  _ScannerMaskPainter({required this.scanRect});

  @override
  void paint(Canvas canvas, Size size) {
    final maskPaint = Paint()..color = Colors.black.withOpacity(0.7);

    // 使用 Path.combine 镂空直角扫描框
    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = Path()
      ..addRect(scanRect);

    final cutPath =
        Path.combine(PathOperation.difference, backgroundPath, holePath);
    canvas.drawPath(cutPath, maskPaint);
  }

  @override
  bool shouldRepaint(covariant _ScannerMaskPainter oldDelegate) =>
      oldDelegate.scanRect != scanRect;
}

// 绘制纯直角定位器与渐变激光扫描线
class _ScannerOverlayPainter extends CustomPainter {
  final Rect scanRect;
  final Color lineColor;
  final double animationValue;

  _ScannerOverlayPainter({
    required this.scanRect,
    required this.lineColor,
    required this.animationValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    const double cornerLength = 20.0;

    // 绘制四个尖锐直角定位线段
    // 左上
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.left, scanRect.top + cornerLength)
        ..lineTo(scanRect.left, scanRect.top)
        ..lineTo(scanRect.left + cornerLength, scanRect.top),
      borderPaint,
    );
    // 右上
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.right - cornerLength, scanRect.top)
        ..lineTo(scanRect.right, scanRect.top)
        ..lineTo(scanRect.right, scanRect.top + cornerLength),
      borderPaint,
    );
    // 左下
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.left, scanRect.bottom - cornerLength)
        ..lineTo(scanRect.left, scanRect.bottom)
        ..lineTo(scanRect.left + cornerLength, scanRect.bottom),
      borderPaint,
    );
    // 右下
    canvas.drawPath(
      Path()
        ..moveTo(scanRect.right - cornerLength, scanRect.bottom)
        ..lineTo(scanRect.right, scanRect.bottom)
        ..lineTo(scanRect.right, scanRect.bottom - cornerLength),
      borderPaint,
    );

    // 绘制极简纯白呼吸式渐变扫描激光线
    final double lineY =
        scanRect.top + 4 + (scanRect.height - 8) * animationValue;
    final Paint linePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          lineColor.withOpacity(0.01),
          lineColor.withOpacity(0.7),
          lineColor.withOpacity(0.01),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(
        Rect.fromLTWH(scanRect.left + 4, lineY - 2, scanRect.width - 8, 4),
      );

    canvas.drawRect(
      Rect.fromLTWH(scanRect.left + 8, lineY - 1, scanRect.width - 16, 2),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) =>
      oldDelegate.animationValue != animationValue ||
      oldDelegate.scanRect != scanRect ||
      oldDelegate.lineColor != lineColor;
}
