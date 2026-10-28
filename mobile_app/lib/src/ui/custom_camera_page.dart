import 'dart:async';

import '../application/capture_work_coordinator.dart';
import '../domain/captured_photo.dart';
import '../application/camera_preferences.dart';
import '../domain/express_capture.dart';
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

class _CustomCameraPageState extends State<CustomCameraPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isTakingPicture = false;
  bool _cameraActive = true;
  int _initializationGeneration = 0;

  FlashMode _flashMode = FlashMode.off;

  String _statusMessage = '正在初始化相机...';

  // 保存成功只更新局部控件，避免整屏闪烁。
  late final VoidCallback _releaseCapturePriority;
  bool _photoSaved = false;
  Offset? _focusPoint;
  bool _showFocusIndicator = false;

  // 记录逻辑预览区的宽高，用于物理图片坐标映射裁剪
  double _logicalWidth = 0.0;
  double _logicalHeight = 0.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _releaseCapturePriority = CaptureWorkCoordinator.instance.acquire();
    _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _initializationGeneration++;
    _controller?.dispose();
    _releaseCapturePriority();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _cameraActive = false;
      if (_isTakingPicture) return;
      _initializationGeneration++;
      final controller = _controller;
      _controller = null;
      unawaited(controller?.dispose());
      if (mounted) setState(() => _isInitialized = false);
    } else if (state == AppLifecycleState.resumed) {
      _cameraActive = true;
      if (!_isTakingPicture && !_photoSaved) unawaited(_initializeCamera());
    }
  }

  Future<void> _initializeCamera() async {
    final generation = ++_initializationGeneration;
    bool isCurrent() =>
        mounted && _cameraActive && generation == _initializationGeneration;
    final torch = await CameraPreferences.loadTorch();
    if (!isCurrent()) return;
    _flashMode = torch ? FlashMode.torch : FlashMode.off;
    setState(() {
      _isInitialized = false;
      _statusMessage = '正在检测摄像头硬件...';
    });

    CameraController? createdController;
    try {
      _cameras = await availableCameras();
      if (!isCurrent()) return;
      if (_cameras.isEmpty) {
        setState(() => _statusMessage = '未检测到可用摄像头');
        return;
      }
      final backCamera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      final previous = _controller;
      _controller = null;
      await previous?.dispose();
      if (!isCurrent()) return;
      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      createdController = controller;
      _controller = controller;
      await controller.initialize();
      if (!isCurrent()) return;
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (!isCurrent()) return;
      try {
        await controller.setFlashMode(_flashMode);
      } catch (error) {
        debugPrint('恢复闪光灯状态异常: $error');
      }
      if (!isCurrent()) return;
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (error) {
        debugPrint('自动对焦预热异常: $error');
      }
      if (isCurrent()) setState(() => _isInitialized = true);
    } catch (error) {
      if (isCurrent()) setState(() => _statusMessage = '相机初始化失败: $error');
    } finally {
      // 离开页面或后台切换后完成的旧初始化不能重新占有摄像头。
      if (!isCurrent() && createdController != null) {
        if (identical(_controller, createdController)) _controller = null;
        await createdController.dispose();
      }
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_isInitialized) return;

    final nextMode =
        _flashMode == FlashMode.off ? FlashMode.torch : FlashMode.off;
    try {
      await _controller!.setFlashMode(nextMode);
      await CameraPreferences.saveTorch(nextMode == FlashMode.torch);
      if (mounted) {
        setState(() {
          _flashMode = nextMode;
        });
      }
    } catch (e) {
      debugPrint('切换闪光灯失败: $e');
    }
  }

  Future<void> _onTapToFocus(
      TapDownDetails details, double maxWidth, double maxHeight) async {
    if (_controller == null ||
        !_isInitialized ||
        _isTakingPicture ||
        maxWidth <= 0 ||
        maxHeight <= 0) {
      return;
    }

    final Offset pos = details.localPosition;
    final double dx = (pos.dx / maxWidth).clamp(0.0, 1.0);
    final double dy = (pos.dy / maxHeight).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = pos;
      _showFocusIndicator = true;
    });

    try {
      await _controller!.setFocusPoint(Offset(dx, dy));
      await _controller!.setFocusMode(FocusMode.auto);
      HapticFeedback.selectionClick();
    } catch (e) {
      debugPrint('对焦设置异常: $e');
    }

    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _showFocusIndicator = false;
        });
      }
    });
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null ||
        !_isInitialized ||
        _isTakingPicture ||
        _photoSaved) {
      return;
    }

    final capture = Stopwatch()..start();
    // 锁定本次取景参数，避免异步保存期间的布局变化改写照片裁剪。
    const inset = (1 - (0.65 / 0.82)) / 2;
    final crop = _logicalWidth > 0 && _logicalHeight > 0
        ? const CaptureCrop(0, inset, 1, 1 - inset)
        : CaptureCrop.full;
    final aspect = _logicalWidth > 0 && _logicalHeight > 0
        ? _logicalWidth / _logicalHeight
        : null;
    setState(() {
      _isTakingPicture = true;
      _photoSaved = false;
    });

    try {
      final file = await controller.takePicture();
      if (await file.length() <= 0) throw StateError('照片文件为空');
      final savedAt = capture.elapsedMilliseconds;
      if (!mounted) return;
      // 插件保存完成后才轻触觉反馈；不等待裁剪或重新编码。
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
      setState(() => _photoSaved = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      // 同一同步步骤内解锁并返回，避免反馈帧期间取消造成重复返回。
      setState(() => _isTakingPicture = false);
      debugPrint(
          'Camera take_picture_ms=$savedAt saved_to_return_ms=${capture.elapsedMilliseconds - savedAt}');
      Navigator.of(context).pop(CapturedPhoto(
        imagePath: file.path,
        crop: crop,
        previewAspect: aspect,
      ));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: const Color(0xFF1E293B),
          content: Text('照片保存失败，请重拍：$error'),
        ));
      }
    } finally {
      if (mounted) setState(() => _isTakingPicture = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: !_isTakingPicture,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Column(
              children: [
                _buildAppBar(),
                Expanded(
                  child: _isInitialized && _controller != null
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) => _onTapToFocus(
                                details,
                                constraints.maxWidth,
                                constraints.maxHeight,
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  CameraPreview(_controller!),
                                  _buildTargetOverlay(),
                                  if (_showFocusIndicator &&
                                      _focusPoint != null)
                                    Positioned(
                                      left: _focusPoint!.dx - 27,
                                      top: _focusPoint!.dy - 27,
                                      child: IgnorePointer(
                                        child: Container(
                                          width: 54,
                                          height: 54,
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.amber,
                                              width: 1.5,
                                            ),
                                            borderRadius:
                                                BorderRadius.circular(2),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        )
                      : Center(
                          child: Text(
                            _statusMessage,
                            style: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 13,
                                letterSpacing: 0.5),
                          ),
                        ),
                ),
                _buildBottomActionBar(),
              ],
            ),
          ),
        ));
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
            onTap: _isTakingPicture ? null : () => Navigator.of(context).pop(),
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

        final double boxWidth = width;
        final double boxHeight = height * (0.65 / 0.82);

        const double left = 0.0;
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
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
            onTap: _isTakingPicture ? null : _toggleFlash,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF1E293B), width: 0.8),
              ),
              child: Icon(
                _flashMode == FlashMode.torch
                    ? Icons.flash_on_outlined
                    : Icons.flash_off_outlined,
                color:
                    _flashMode == FlashMode.torch ? Colors.amber : Colors.white,
                size: 20,
              ),
            ),
          ),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildShutterButton(),
              const SizedBox(height: 6),
              Text(
                _photoSaved
                    ? '已拍好，可以移开'
                    : _isTakingPicture
                        ? '正在保存，请保持稳定'
                        : '拍照',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
          GestureDetector(
            onTap: _isTakingPicture ? null : () => Navigator.of(context).pop(),
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
      onTap: _isTakingPicture || _photoSaved ? null : _takePicture,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 1.5),
        ),
        padding: const EdgeInsets.all(6),
        child: Container(
          color: Colors.white,
          child: Center(
            child: _isTakingPicture && !_photoSaved
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black),
                  )
                : Icon(
                    _photoSaved ? Icons.check : Icons.camera_alt_outlined,
                    color: Colors.black,
                    size: 24,
                  ),
          ),
        ),
      ),
    );
  }
}
