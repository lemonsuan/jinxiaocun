import 'dart:io';
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

    // 当 App 失去焦点或进入后台时释放相机，返回时重新初始化
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

      // 优先寻找后置摄像头
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
      
      // 物理锁定快门捕获方向为 portraitUp，保证图片百分之百是竖的
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      
      // 默认关闭闪光灯
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
      if (mounted) {
        Navigator.of(context).pop(file);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1E293B),
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            content: Text('拍摄失败: $e', style: const TextStyle(color: Colors.white, fontSize: 13)),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // 1. Notion 极简白色直角导航栏
            _buildAppBar(),
            
            // 2. 沉浸式预览区 + 物理框对齐遮罩
            Expanded(
              child: _isInitialized && _controller != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(_controller!),
                        // 居中的直角定位框 Overlay
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
            
            // 3. 底部黑色 Notion 拍照控制区
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
          // 占位
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildTargetOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;
        
        // 目标框的大小：宽度的 80%，高度的 60%
        final double boxWidth = width * 0.82;
        final double boxHeight = height * 0.65;
        
        final double left = (width - boxWidth) / 2;
        final double top = (height - boxHeight) / 2;

        return Stack(
          children: [
            // 半透明遮罩
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
                        color: Colors.black, // 源模式会挖空它
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 四个高对比度直角边框
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
            // 加粗的直角边角
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
            // 框内文字引导
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
                      '锁定垂直照片，保障高精度解析',
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
          // 左侧闪光灯切换
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
          
          // 中间 Notion 风格直角快门按钮
          _buildShutterButton(),

          // 右侧取消占位/或提示
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
