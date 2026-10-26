import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../application/camera_preferences.dart';
import '../application/express_capture_state.dart';
import '../application/express_receipt_committer.dart';
import '../application/express_processing_queue.dart';
import '../data/local_inventory_database.dart';
import '../domain/express_capture.dart';
import '../domain/models.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/express_camera_channel.dart';
import '../platform/paddle_ocr_channel.dart';

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
  final _committer = ExpressReceiptCommitter();
  int _viewGeneration = 0;
  Stopwatch? _cycle;
  static const _crop = CaptureCrop(0.04, 0.12, 0.96, 0.88);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _queue = ExpressProcessingQueue.forDatabase(widget.database);
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
      if (!mounted) return;
      setState(() {
        _directory = directory.path;
        _torch = torch;
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
      // onCaptured is sent only after native JPEG save completion, never on shutter press.
      HapticFeedback.heavyImpact();
      if (mounted) {
        setState(() {
          _showSaved = true;
          _message = '已拍下，可以移开 · 正在记录入库';
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
      await _committer.saveOnce(photo.captureId, () async {
        await widget.database.confirmInbound(
            trackingNumber: photo.trackingNumber,
            items: const [],
            imagePath: photo.imagePath,
            ocrStatus: OcrStatus.pending,
            expressCrop: photo.crop,
            expressToken: photo.captureId);
      });
      _capture.committed();
      debugPrint(
          'Express receipt_committed_ms=${_cycle?.elapsedMilliseconds ?? 0}');
      unawaited(_queue.kick());
      // Arm local state before native reset can deliver a new barcode.
      _capture.reset();
      if (mounted) setState(() => _message = '已录入，继续扫描下一单 · 清单正在后台识别');
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
        backgroundColor: Colors.black,
        appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('极速入库'),
            leading: IconButton(
                onPressed: _capture.busy ? null : _leave,
                icon: const Icon(Icons.arrow_back))),
        body: SafeArea(
            child: Column(children: [
          Container(
              height: 100,
              width: double.infinity,
              color: const Color(0xFF202020),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(locked ? '快递单号' : '请扫描快递条码',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
                    if (locked)
                      Text(_capture.trackingNumber!,
                          softWrap: true,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 21)),
                  ]))),
          Expanded(
              child: _directory == null
                  ? const Center(child: CircularProgressIndicator())
                  : !Platform.isAndroid
                      ? const Center(
                          child: Text('极速相机目前支持 Android，请使用普通入库',
                              style: TextStyle(color: Colors.white)))
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
                              child: Stack(fit: StackFit.expand, children: [
                                AndroidView(
                                    key: ValueKey(_viewGeneration),
                                    viewType: ExpressCameraChannel.viewType,
                                    creationParams: {
                                      'outputDirectory': _directory,
                                      'torchEnabled': _torch
                                    },
                                    creationParamsCodec:
                                        const StandardMessageCodec(),
                                    onPlatformViewCreated: _attach),
                                IgnorePointer(
                                    child: Align(
                                        alignment: Alignment.center,
                                        child: FractionallySizedBox(
                                            widthFactor: locked ? .92 : .9,
                                            heightFactor: locked ? .76 : .32,
                                            child: Container(
                                                decoration: BoxDecoration(
                                                    border: Border.all(
                                                        color: Colors.white,
                                                        width: 2)))))),
                                if (_showSaved)
                                  const IgnorePointer(
                                      child: Align(
                                          alignment: Alignment.topCenter,
                                          child: Padding(
                                              padding: EdgeInsets.all(12),
                                              child: Chip(
                                                  avatar: Icon(
                                                      Icons.check_circle,
                                                      color: Colors.green),
                                                  label: Text('已拍下，可以移开'))))),
                              ])))),
          SizedBox(
              height: 64,
              child: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13))))),
          SizedBox(
              height: 64,
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                        onPressed: _capture.busy ? null : _toggleTorch,
                        color: Colors.white,
                        icon: Icon(_torch ? Icons.flash_on : Icons.flash_off)),
                    if (locked)
                      FilledButton.icon(
                          onPressed: _capture.busy
                              ? null
                              : (_capture.phase == ExpressCapturePhase.error
                                  ? _retryCamera
                                  : _takePhoto),
                          icon: const Icon(Icons.camera_alt),
                          label: Text(
                              _capture.savedCapture != null ? '重试保存' : '拍照')),
                    if (locked)
                      TextButton(
                          onPressed: _capture.busy ? null : _reset,
                          child: const Text('取消本单')),
                    if (!locked && _capture.phase == ExpressCapturePhase.error)
                      TextButton(
                          onPressed: _retryCamera, child: const Text('重试相机')),
                  ])),
          SizedBox(
              height: 90,
              child: locked
                  ? const Center(
                      child: Text('轻触画面对焦 · 照片保存后再提示完成',
                          style:
                              TextStyle(color: Colors.white70, fontSize: 12)))
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _recent.length,
                      itemBuilder: (context, index) {
                        final receipt = _recent[index];
                        final failed = receipt.ocrStatus == OcrStatus.failed;
                        return Padding(
                            padding: const EdgeInsets.all(6),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              ActionChip(
                                  label: Text(
                                      '${receipt.trackingNumber}\n${failed ? '识别失败' : receipt.ocrStatus == OcrStatus.confirmed ? '已识别' : '后台识别中'}'),
                                  onPressed: receipt.imagePath == null
                                      ? null
                                      : () => _showPhoto(receipt)),
                              if (failed)
                                IconButton(
                                    tooltip: '重试识别',
                                    color: Colors.white,
                                    icon: const Icon(Icons.refresh),
                                    onPressed: () async {
                                      await _queue.retry(receipt.id);
                                      await _refreshRecent();
                                    }),
                            ]));
                      })),
        ])),
      ),
    );
  }
}
