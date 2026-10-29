import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../application/camera_preferences.dart';
import '../application/express_capture_state.dart';
import '../application/express_receipt_committer.dart';
import '../application/express_processing_queue.dart';
import '../application/capture_work_coordinator.dart';
import '../application/ocr_access_policy.dart';
import '../data/local_inventory_database.dart';
import '../domain/express_capture.dart';
import '../domain/models.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/express_camera_channel.dart';
import '../platform/paddle_ocr_channel.dart';
import 'express_camera_chrome.dart';

class ExpressInboundPage extends StatefulWidget {
  const ExpressInboundPage(
      {super.key,
      required this.database,
      required this.paddleOcr,
      required this.postProcessor,
      required this.ocrRowMergeTolerance,
      required this.onRefreshHomeData});
  final LocalInventoryDatabase database;
  final PaddleOcrChannel paddleOcr;
  final PpStructurePostProcessor postProcessor;
  final double ocrRowMergeTolerance;
  final VoidCallback onRefreshHomeData;
  @override
  State<ExpressInboundPage> createState() => _ExpressInboundPageState();
}

class _ExpressInboundPageState extends State<ExpressInboundPage>
    with WidgetsBindingObserver {
  final _capture = ExpressCaptureState();
  ExpressCameraChannel? _camera;
  late final ExpressProcessingQueue _queue;
  List<InboundReceipt> _recent = [];
  String? _directory;
  String _message = '正在准备相机…';
  bool _torch = false;
  bool _leaving = false;
  bool _active = true;
  bool _showSaved = false;
  bool _ocrEnabled = true;
  VoidCallback? _releaseCapture;
  VoidCallback? _releaseQueue;
  final _committer = ExpressReceiptCommitter();
  int _viewGeneration = 0;
  Stopwatch? _cycle;
  static const _crop = CaptureCrop(0.04, 0.12, 0.96, 0.88);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _releaseCapture = CaptureWorkCoordinator.instance.acquire();
    _queue = ExpressProcessingQueue.forDatabase(widget.database);
    _releaseQueue = _queue.retain();
    _queue.listeners.add(_refreshRecent);
    unawaited(_prepare());
    unawaited(_queue.kick());
  }

  Future<void> _prepare() async {
    try {
      final directory = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/inbound_images');
      await directory.create(recursive: true);
      final torch = await CameraPreferences.loadTorch();
      final ocrEnabled = await widget.database.loadOcrEnabled();
      if (!mounted) return;
      setState(() {
        _directory = directory.path;
        _torch = torch;
        _ocrEnabled = ocrEnabled;
      });
      await _refreshRecent();
    } catch (e) {
      _error('准备相机失败，请退出后重试');
    }
  }

  Future<void> _refreshRecent() async {
    final rows = await widget.database.loadRecentInboundReceipts(5);
    if (mounted) setState(() => _recent = rows);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    final camera = _camera;
    if (camera == null) return;
    unawaited(
        (_active ? camera.resume() : camera.pause()).catchError((Object e) {
      if (mounted) _error('相机暂不可用，请重试');
    }));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _queue.listeners.remove(_refreshRecent);
    _releaseCapture?.call();
    _releaseQueue?.call();
    unawaited(_camera?.dispose().catchError((Object _) {}) ?? Future.value());
    super.dispose();
  }

  void _error(String text) {
    if (!mounted) return;
    setState(() {
      _capture.failed();
      _message = text;
      _showSaved = false;
    });
  }

  void _attach(int viewId) {
    final camera = ExpressCameraChannel(viewId);
    _camera = camera;
    camera.onReady = () {
      if (!mounted) return;
      setState(() {
        _capture.ready();
        if (_capture.trackingNumber == null) _message = '对准快递条码，识别后拍摄清单';
      });
    };
    camera.onTracking = (tracking) {
      if (!mounted || !_active || !_capture.lock(tracking)) return;
      _cycle = Stopwatch()..start();
      setState(() {
        _showSaved = false;
        _message = '单号已锁定，请将清单放入框内后拍照';
      });
    };
    camera.onCaptured = (photo) {
      if (!_capture.accept(photo)) return;
      // 只有正式照片保存完成才能提示可以移开。
      HapticFeedback.lightImpact();
      if (mounted) {
        setState(() {
          _showSaved = true;
          _message = '已拍好，可以移开 · 正在记录入库';
        });
      }
      debugPrint('Express capture saved_ms=${photo.shutterToSavedMs}');
      unawaited(_commit(photo));
    };
    camera.onError = (code, message, captureId) {
      if (captureId != null && captureId != _capture.captureId) return;
      _error(message);
    };
    camera.listen();
    unawaited(camera.resume().catchError((Object _) => _error('启动相机失败，请重试')));
  }

  Future<void> _takePhoto() async {
    final camera = _camera;
    if (camera == null || !_active || _leaving) return;
    final id = 'express_${DateTime.now().microsecondsSinceEpoch}';
    if (!_capture.begin(id)) return;
    setState(() {
      _showSaved = false;
      _message = '正在拍摄，请保持稳定…';
    });
    try {
      await camera.capture(id, _capture.trackingNumber!, _crop);
    } catch (_) {
      _error('拍摄失败，请保持手机稳定后重试');
    }
  }

  Future<void> _commit(SavedExpressCapture photo) async {
    try {
      if (!await File(photo.imagePath).exists()) {
        throw const FileSystemException('照片保存失败');
      }
      final ocrEnabled = await widget.database.loadOcrEnabled();
      _ocrEnabled = ocrEnabled;
      await _committer.saveOnce(photo.captureId, () async {
        await widget.database.confirmInbound(
            trackingNumber: photo.trackingNumber,
            items: const [],
            imagePath: photo.imagePath,
            ocrStatus: ocrEnabled ? OcrStatus.pending : OcrStatus.needsReview,
            expressCrop: photo.crop,
            expressToken: ocrEnabled ? photo.captureId : null);
      });
      _capture.committed();
      debugPrint(
          'Express receipt_committed_ms=${_cycle?.elapsedMilliseconds ?? 0}');
      unawaited(_queue.kick());
      // Arm local state before native reset can deliver a new barcode.
      _capture.reset();
      if (mounted) {
        setState(() => _message =
            ocrEnabled ? '已录入，继续扫描下一单 · 退出拍摄后识别' : '已录入，OCR已关闭 · 仅保存照片，待手工补录');
      }
      try {
        await _camera?.reset();
      } catch (_) {
        _error('单据已保存，恢复扫码失败，请重试相机');
      }
      if (!mounted) return;
      debugPrint(
          'Express ready_for_next_ms=${_cycle?.elapsedMilliseconds ?? 0}');
      unawaited(_refreshRecent());
    } catch (e) {
      _error('入库记录失败：$e\n照片已保留，可重试保存或取消本单');
    }
  }

  Future<void> _reset() async {
    if (_capture.busy || _leaving) return;
    try {
      final unused = _capture.savedCapture?.imagePath;
      _capture.reset();
      await _camera?.reset();
      if (unused != null &&
          !await widget.database.isImagePathReferenced(unused)) {
        final file = File(unused);
        if (await file.exists()) await file.delete();
      }
      if (mounted) {
        setState(() {
          _showSaved = false;
          _message = '已取消，请扫描快递条码';
        });
      }
    } catch (_) {
      _error('恢复扫码失败，请重试');
    }
  }

  Future<void> _leave() async {
    if (_capture.busy || _leaving) return;
    if (_capture.savedCapture != null &&
        !_committer.isSaved(_capture.savedCapture!.captureId)) {
      setState(() => _message = '照片尚未入库，请重试保存或取消本单后退出');
      return;
    }
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _camera?.dispose();
    } finally {
      widget.onRefreshHomeData();
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _camera?.setTorch(!_torch);
      final value = !_torch;
      await CameraPreferences.saveTorch(value);
      if (mounted) setState(() => _torch = value);
    } catch (_) {
      if (mounted) setState(() => _message = '补光灯暂不可用');
    }
  }

  Future<void> _retryCamera() async {
    if (_capture.busy || _leaving) return;
    if (_capture.savedCapture != null) {
      setState(() {
        _capture.phase = ExpressCapturePhase.saving;
        _message = '正在重试保存单据…';
      });
      await _commit(_capture.savedCapture!);
      return;
    }
    if (_capture.trackingNumber != null) {
      await _takePhoto();
      return;
    }
    try {
      await _camera?.dispose();
      _camera = null;
      if (mounted) {
        setState(() {
          _capture.phase = ExpressCapturePhase.initializing;
          _viewGeneration++;
        });
      }
    } catch (_) {
      _error('重启相机失败，请退出后重试');
    }
  }

  Future<void> _showPhoto(InboundReceipt receipt) async {
    final path = receipt.imagePath;
    if (path == null || !await File(path).exists() || !mounted) return;
    try {
      await _camera?.pause();
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(title: Text(receipt.trackingNumber)),
                body: Center(
                    child: InteractiveViewer(
                        maxScale: 5, child: Image.file(File(path)))),
              )));
    } finally {
      if (mounted && _active) await _camera?.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _capture.trackingNumber != null;
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF252525),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: const Text('极速入库',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w400, letterSpacing: 1)),
          leading: IconButton(
              onPressed: _capture.busy ? null : _leave,
              icon: const Icon(Icons.arrow_back)),
        ),
        body: SafeArea(
          top: false,
          child: Column(children: [
            ExpressTrackingHeader(trackingNumber: _capture.trackingNumber),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ColoredBox(
                  color: Colors.black,
                  child: _directory == null
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white))
                      : !Platform.isAndroid
                          ? const Center(
                              child: Text('极速相机目前支持 Android，请使用普通入库',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white, fontSize: 12)))
                          : LayoutBuilder(
                              builder: (context, size) => GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) {
                                  if (_capture.busy) return;
                                  unawaited((_camera?.focus(
                                              details.localPosition.dx /
                                                  size.maxWidth,
                                              details.localPosition.dy /
                                                  size.maxHeight) ??
                                          Future.value())
                                      .catchError((Object _) {}));
                                },
                                child: ExpressCameraFrame(
                                  locked: locked,
                                  crop: _crop,
                                  showSaved: _showSaved,
                                  child: AndroidView(
                                    key: ValueKey(_viewGeneration),
                                    viewType: ExpressCameraChannel.viewType,
                                    creationParams: {
                                      'outputDirectory': _directory,
                                      'torchEnabled': _torch,
                                    },
                                    creationParamsCodec:
                                        const StandardMessageCodec(),
                                    onPlatformViewCreated: _attach,
                                  ),
                                ),
                              ),
                            ),
                ),
              ),
            ),
            SizedBox(
              height: 48,
              child: SingleChildScrollView(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Text(_message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFF777773),
                          fontSize: 12,
                          height: 1.35)),
                ),
              ),
            ),
            SizedBox(
              height: 80,
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _cameraControl(
                      icon: _torch ? Icons.flash_on : Icons.flash_off,
                      label: _torch ? '补光已开' : '补光',
                      onPressed: _capture.busy ? null : _toggleTorch,
                    ),
                    SizedBox(
                      width: 108,
                      child: Center(
                        child: locked
                            ? Semantics(
                                button: true,
                                label: _capture.savedCapture != null
                                    ? '重试保存'
                                    : '拍照',
                                child: SizedBox(
                                  width: 70,
                                  height: 70,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      foregroundColor: Colors.white,
                                      backgroundColor: const Color(0xFF252525),
                                      disabledBackgroundColor:
                                          const Color(0xFF666666),
                                      disabledForegroundColor: Colors.white,
                                      side: const BorderSide(
                                          color: Color(0xFF252525), width: 1),
                                      shape: const CircleBorder(),
                                    ),
                                    onPressed: _capture.busy
                                        ? null
                                        : (_capture.phase ==
                                                ExpressCapturePhase.error
                                            ? _retryCamera
                                            : _takePhoto),
                                    child: _capture.busy
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white))
                                        : Icon(
                                            _showSaved
                                                ? Icons.check
                                                : Icons.camera_alt_outlined,
                                            size: 28),
                                  ),
                                ),
                              )
                            : const Text('等待识别',
                                style: TextStyle(
                                    color: Color(0xFF969692), fontSize: 12)),
                      ),
                    ),
                    locked
                        ? _cameraControl(
                            icon: Icons.qr_code_scanner,
                            label: '重扫',
                            onPressed: _capture.busy ? null : _reset)
                        : _capture.phase == ExpressCapturePhase.error
                            ? _cameraControl(
                                icon: Icons.refresh,
                                label: '重试相机',
                                onPressed: _retryCamera)
                            : const SizedBox(width: 72),
                  ]),
            ),
            SizedBox(
              height: 74,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('最近入库',
                                style: TextStyle(
                                    color: Color(0xFF969692), fontSize: 10)),
                            Text(_ocrEnabled ? '退出拍摄后识别' : 'OCR已关闭',
                                style: const TextStyle(
                                    color: Color(0xFF969692), fontSize: 10)),
                          ]),
                    ),
                    Expanded(
                      child: _recent.isEmpty
                          ? const Center(
                              child: Text('暂无入库记录',
                                  style: TextStyle(
                                      color: Color(0xFFB1B1AD), fontSize: 11)))
                          : ListView.builder(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              scrollDirection: Axis.horizontal,
                              itemCount: _recent.length,
                              itemBuilder: (context, index) {
                                final receipt = _recent[index];
                                final failed =
                                    receipt.ocrStatus == OcrStatus.failed;
                                final status = failed
                                    ? '识别失败'
                                    : receipt.ocrStatus == OcrStatus.confirmed
                                        ? '已识别'
                                        : receipt.ocrStatus ==
                                                OcrStatus.needsReview
                                            ? '待补录'
                                            : !_ocrEnabled
                                                ? '识别已暂停'
                                                : '待识别';
                                return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        style: TextButton.styleFrom(
                                          foregroundColor:
                                              const Color(0xFF555551),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 9),
                                          shape: const RoundedRectangleBorder(),
                                        ),
                                        onPressed:
                                            locked || receipt.imagePath == null
                                                ? null
                                                : () => _showPhoto(receipt),
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(receipt.trackingNumber,
                                                  style: const TextStyle(
                                                      fontSize: 11)),
                                              const SizedBox(height: 2),
                                              Text(status,
                                                  style: const TextStyle(
                                                      fontSize: 10,
                                                      color:
                                                          Color(0xFF969692))),
                                            ]),
                                      ),
                                      if (failed)
                                        IconButton(
                                          tooltip: '重试识别',
                                          visualDensity: VisualDensity.compact,
                                          color: const Color(0xFF777773),
                                          iconSize: 18,
                                          icon: const Icon(Icons.refresh),
                                          onPressed: locked
                                              ? null
                                              : () async {
                                                  try {
                                                    await _queue
                                                        .retry(receipt.id);
                                                    await _refreshRecent();
                                                  } on OcrCancelled catch (error) {
                                                    if (mounted) {
                                                      setState(() => _message =
                                                          error.toString());
                                                    }
                                                  }
                                                },
                                        ),
                                    ]);
                              },
                            ),
                    ),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _cameraControl(
          {required IconData icon,
          required String label,
          required VoidCallback? onPressed}) =>
      SizedBox(
        width: 72,
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF555551),
            shape: const RoundedRectangleBorder(),
            padding: const EdgeInsets.symmetric(vertical: 8),
          ),
          onPressed: onPressed,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22),
            const SizedBox(height: 5),
            Text(label, style: const TextStyle(fontSize: 10)),
          ]),
        ),
      );
}
