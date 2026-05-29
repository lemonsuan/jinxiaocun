import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> with SingleTickerProviderStateMixin {
  static const List<BarcodeFormat> _linearBarcodeFormats = [
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.codabar,
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.itf,
    BarcodeFormat.upca,
    BarcodeFormat.upce,
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
    final colorScheme = Theme.of(context).colorScheme;
    
    // 莫兰迪青蓝色作为扫描线与边角色
    final lineColor = Colors.teal.shade300;

    final double scanWidth = 280;
    final double scanHeight = 180;
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

          // 3. 霓虹定位直角与呼吸激光扫描线
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

          // 4. 顶部毛玻璃悬浮返回键
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: _glassButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icons.arrow_back_ios_new,
            ),
          ),

          // 5. 底部毛玻璃控制面板（闪光灯、摄像头翻转）
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
                  label: "闪光灯",
                ),
                const SizedBox(width: 32),
                _glassButton(
                  onPressed: () => _controller.switchCamera(),
                  icon: Icons.flip_camera_android_outlined,
                  label: "翻转",
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
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: label != null ? 80 : 50,
          height: label != null ? 80 : 50,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
            shape: BoxShape.circle,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onPressed,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 24),
                  if (label != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
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

// 绘制半透明遮罩与镂空矩形圆角视窗
class _ScannerMaskPainter extends CustomPainter {
  final Rect scanRect;

  _ScannerMaskPainter({required this.scanRect});

  @override
  void paint(Canvas canvas, Size size) {
    final maskPaint = Paint()..color = Colors.black.withOpacity(0.65);
    
    // 使用 Path.combine 镂空扫描框
    final backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final holePath = Path()
      ..addRRect(RRect.fromRectAndRadius(scanRect, const Radius.circular(16)));

    final cutPath = Path.combine(PathOperation.difference, backgroundPath, holePath);
    canvas.drawPath(cutPath, maskPaint);
  }

  @override
  bool shouldRepaint(covariant _ScannerMaskPainter oldDelegate) =>
      oldDelegate.scanRect != scanRect;
}

// 绘制边角与渐变激光扫描线
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
      ..strokeWidth = 4.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final double cornerSize = 24.0;
    final rrect = RRect.fromRectAndRadius(scanRect, const Radius.circular(16));

    // 绘制四个角定位线段
    // 左上
    canvas.drawPath(
      Path()
        ..moveTo(rrect.left, rrect.top + cornerSize)
        ..lineTo(rrect.left, rrect.top)
        ..lineTo(rrect.left + cornerSize, rrect.top),
      borderPaint,
    );
    // 右上
    canvas.drawPath(
      Path()
        ..moveTo(rrect.right - cornerSize, rrect.top)
        ..lineTo(rrect.right, rrect.top)
        ..lineTo(rrect.right, rrect.top + cornerSize),
      borderPaint,
    );
    // 左下
    canvas.drawPath(
      Path()
        ..moveTo(rrect.left, rrect.bottom - cornerSize)
        ..lineTo(rrect.left, rrect.bottom)
        ..lineTo(rrect.left + cornerSize, rrect.bottom),
      borderPaint,
    );
    // 右下
    canvas.drawPath(
      Path()
        ..moveTo(rrect.right - cornerSize, rrect.bottom)
        ..lineTo(rrect.right, rrect.bottom)
        ..lineTo(rrect.right, rrect.bottom - cornerSize),
      borderPaint,
    );

    // 绘制呼吸式渐变扫描激光线
    final double lineY = scanRect.top + 8 + (scanRect.height - 16) * animationValue;
    final Paint linePaint = Paint()
      ..shader = LinearGradient(
        colors: [
          lineColor.withOpacity(0.01),
          lineColor.withOpacity(0.9),
          lineColor.withOpacity(0.01),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(
        Rect.fromLTWH(scanRect.left + 8, lineY - 4, scanRect.width - 16, 8),
      );

    canvas.drawRect(
      Rect.fromLTWH(scanRect.left + 12, lineY - 3, scanRect.width - 24, 6),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) =>
      oldDelegate.animationValue != animationValue ||
      oldDelegate.scanRect != scanRect ||
      oldDelegate.lineColor != lineColor;
}