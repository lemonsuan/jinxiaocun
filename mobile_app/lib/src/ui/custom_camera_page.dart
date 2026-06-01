import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomCameraPage extends StatefulWidget {
  final String title;

  const CustomCameraPage({
    super.key,
    this.title = '拍照识别',
  });

  @override
  State<CustomCameraPage> createState() => _CustomCameraPageState();
}

class _CustomCameraPageState extends State<CustomCameraPage> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isTakingPicture = false;
  FlashMode _flashMode = FlashMode.off;
  String _statusMessage = '正在初始化相机...';

  // 记录逻辑预览区的宽高，用于物理图片坐标映射裁剪
  double _logicalWidth = 0.0;
  double _logicalHeight = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
      setState(() {
        _isInitialized = false;
      });
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    setState(() {
      _isInitialized = false;
      _statusMessage = '正在检测摄像头硬件...';
    });

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _statusMessage = '未检测到可用摄像头';
        });
        return;
      }

      final backCamera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _controller = controller;

      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await controller.setFlashMode(_flashMode);

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = '相机初始化失败: $e';
        });
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_isInitialized) return;

    final nextMode = _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _controller!.setFlashMode(nextMode);
      setState(() {
        _flashMode = nextMode;
      });
    } catch (e) {
      debugPrint('切换闪光灯失败: $e');
    }
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_isInitialized || _isTakingPicture) return;

    setState(() {
      _isTakingPicture = true;
    });

    try {
      final XFile file = await _controller!.takePicture();
      
      // 物理图片裁剪：只保留取景框范围内的图片内容
      if (_logicalWidth > 0 && _logicalHeight > 0) {
        final File rawFile = File(file.path);
        if (rawFile.existsSync()) {
          final Uint8List bytes = await rawFile.readAsBytes();
          
          // 1. 获取物理图片的原始宽高
          final ui.Codec codec = await ui.instantiateImageCodec(bytes);
          final ui.FrameInfo frameInfo = await codec.getNextFrame();
          final ui.Image image = frameInfo.image;
          
          final double pWidth = image.width.toDouble();
          final double pHeight = image.height.toDouble();
          image.dispose(); // 尽早释放句柄

          // 2. 根据比率计算取景框的逻辑大小和位置
          final double boxWidth = _logicalWidth * 0.82;
          final double boxHeight = _logicalHeight * 0.65;
          final double left = (_logicalWidth - boxWidth) / 2;
          final double top = (_logicalHeight - boxHeight) / 2;

          // 3. 计算 BoxFit.cover 模式下，物理图片映射至逻辑预览区的 scale 和 offset
          final double lRatio = _logicalWidth / _logicalHeight;
          final double pRatio = pWidth / pHeight;
          double scale;
          double offsetX = 0;
          double offsetY = 0;

          if (lRatio > pRatio) {
            scale = _logicalWidth / pWidth;
            offsetY = (_logicalHeight - pHeight * scale) / 2;
          } else {
            scale = _logicalHeight / pHeight;
            offsetX = (_logicalWidth - pWidth * scale) / 2;
          }

          // 4. 将逻辑取景框边界精确映射到物理图片的像素坐标上
          final double cropLeftPhys = (left - offsetX) / scale;
          final double cropTopPhys = (top - offsetY) / scale;
          final double cropWidthPhys = boxWidth / scale;
          final double cropHeightPhys = boxHeight / scale;

          final int x = cropLeftPhys.round().clamp(0, pWidth.toInt() - 1);
          final int y = cropTopPhys.round().clamp(0, pHeight.toInt() - 1);
          final int w = cropWidthPhys.round().clamp(1, pWidth.toInt() - x);
          final int h = cropHeightPhys.round().clamp(1, pHeight.toInt() - y);

          // 5. 底层裁剪并覆写图片
          await _performPhysicalCrop(file.path, x, y, w, h);
        }
      }

      if (mounted) {
        Navigator.of(context).pop(file);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1E293B),
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text('拍摄并裁剪失败: $e', style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTakingPicture = false;
        });
      }
    }
  }

  // 使用 dart:ui 模块的 Skia 画布在物理层面上对图片进行像素裁剪，杜绝性能溢出
  Future<void> _performPhysicalCrop(String path, int x, int y, int width, int height) async {
    try {
      final File file = File(path);
      if (!file.existsSync()) return;

      final Uint8List bytes = await file.readAsBytes();
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image image = frameInfo.image;

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);

      final Rect src = Rect.fromLTWH(x.toDouble(), y.toDouble(), width.toDouble(), height.toDouble());
      final Rect dst = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      canvas.drawImageRect(image, src, dst, ui.Paint());

      final ui.Picture picture = recorder.endRecording();
      final ui.Image croppedImage = await picture.toImage(width, height);
      final ByteData? byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);

      if (byteData != null) {
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      }

      image.dispose();
      croppedImage.dispose();
      
      // 清除该文件的 Flutter 图片缓存，促使 UI 重新从磁盘加载更新后的图片
      PaintingBinding.instance.imageCache.evict(FileImage(file));
    } catch (e) {
      debugPrint('底层物理裁剪异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            Expanded(
              child: _isInitialized && _controller != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(_controller!),
                        _buildTargetOverlay(),
                        if (_isTakingPicture)
                          Container(
                            color: Colors.black.withOpacity(0.5),
                            child: const Center(
                              child: CircularProgressIndicator(
                                strokeWidth: 2.0,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    )
                  : Center(
                      child: Text(
                        _statusMessage,
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13, letterSpacing: 0.5),
                      ),
                    ),
            ),
            _buildBottomActionBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Container(
      height: 56,
      decoration: const BoxDecoration(
        color: Colors.black,
        border: Border(
          bottom: BorderSide(
            color: Color(0xFF1E293B),
            width: 0.8,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: const Row(
              children: [
                Icon(Icons.arrow_back_ios_new, size: 14, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  '返回',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
          Text(
            widget.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w400,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildTargetOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 在渲染时实时记录最新的预览容器大小，用于拍照时的裁剪映射
        _logicalWidth = constraints.maxWidth;
        _logicalHeight = constraints.maxHeight;
        
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;
        
        final double boxWidth = width * 0.82;
        final double boxHeight = height * 0.65;
        
        final double left = (width - boxWidth) / 2;
        final double top = (height - boxHeight) / 2;

        return Stack(
          children: [
            ColorFiltered(
              colorFilter: ColorFilter.mode(
                Colors.black.withOpacity(0.5),
                BlendMode.srcOut,
              ),
              child: Stack(
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.transparent,
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    width: boxWidth,
                    height: boxHeight,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: boxWidth,
              height: boxHeight,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 0.8,
                  ),
                ),
              ),
            ),
            Positioned(
              left: left - 2,
              top: top - 2,
              child: _buildCorner(top: true, left: true),
            ),
            Positioned(
              right: left - 2,
              top: top - 2,
              child: _buildCorner(top: true, left: false),
            ),
            Positioned(
              left: left - 2,
              bottom: top - 2,
              child: _buildCorner(top: false, left: true),
            ),
            Positioned(
              right: left - 2,
              bottom: top - 2,
              child: _buildCorner(top: false, left: false),
            ),
            Positioned(
              left: left,
              right: left,
              top: top + boxHeight / 2 - 20,
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      color: Colors.black.withOpacity(0.6),
                      child: const Text(
                        '请将清单/单据放入框内',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w300,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '自动精准裁剪取景框内画面进行识别',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.5),
                        fontSize: 9,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCorner({required bool top, required bool left}) {
    const double length = 20.0;
    const double thickness = 3.0;
    const Color color = Colors.white;

    return SizedBox(
      width: length,
      height: length,
      child: Stack(
        children: [
          Positioned(
            top: top ? 0 : null,
            bottom: top ? null : 0,
            left: 0,
            right: 0,
            child: Container(
              height: thickness,
              color: color,
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            left: left ? 0 : null,
            right: left ? null : 0,
            child: Container(
              width: thickness,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActionBar() {
    return Container(
      height: 120,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: _toggleFlash,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF1E293B), width: 0.8),
              ),
              child: Icon(
                _flashMode == FlashMode.torch ? Icons.flash_on_outlined : Icons.flash_off_outlined,
                color: _flashMode == FlashMode.torch ? Colors.amber : Colors.white,
                size: 20,
              ),
            ),
          ),
          _buildShutterButton(),
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF1E293B), width: 0.8),
              ),
              child: const Text(
                '取消',
                style: TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShutterButton() {
    return GestureDetector(
      onTap: _takePicture,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        padding: const EdgeInsets.all(6),
        child: Container(
          color: Colors.white,
          child: const Center(
            child: Icon(
              Icons.camera_alt_outlined,
              color: Colors.black,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
