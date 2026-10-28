import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../data/local_inventory_database.dart';
import '../domain/express_capture.dart';
import '../domain/models.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/paddle_ocr_channel.dart';
import 'capture_image_processor.dart';
import 'capture_work_coordinator.dart';
import 'ocr_access_policy.dart';

/// 单通道执行，待处理单据保留在SQLite中，不把整批图片放入内存。
class DurableSerialRunner<T> {
  DurableSerialRunner(
      {required this.next, required this.process, required this.onError});
  final Future<T?> Function() next;
  final Future<void> Function(T) process;
  final void Function(Object, StackTrace) onError;
  Future<void>? _running;
  bool _requested = false;
  Future<void> kick() {
    _requested = true;
    return _running ??= _drain().whenComplete(() {
      _running = null;
      if (_requested) unawaited(kick());
    });
  }

  Future<void> _drain() async {
    try {
      do {
        _requested = false;
        while (true) {
          final job = await next();
          if (job == null) break;
          await process(job);
        }
      } while (_requested);
    } catch (e, stack) {
      onError(e, stack);
    }
  }
}

class ExpressProcessingQueue {
  ExpressProcessingQueue._(this.database) {
    _ocr = PaddleOcrChannel(policy: () => database.ocrPolicy);
    _runner = DurableSerialRunner<ExpressImageJob>(
        next: _next,
        process: _process,
        onError: (e, _) => debugPrint('极速队列已暂停: ${e.runtimeType}'));
  }
  int _owners = 0;
  VoidCallback retain() {
    if (_owners++ == 0) {
      database.ocrPolicy.addListener(_changed);
      CaptureWorkCoordinator.instance.addListener(_changed);
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_owners == 0) {
        database.ocrPolicy.removeListener(_changed);
        CaptureWorkCoordinator.instance.removeListener(_changed);
      }
    };
  }

  void _changed() {
    if (_owners > 0) unawaited(kick());
  }

  Future<ExpressImageJob?> _next() async {
    if (_owners == 0 ||
        CaptureWorkCoordinator.instance.isActive ||
        !await database.loadOcrEnabled()) {
      return null;
    }
    if (_owners == 0 || CaptureWorkCoordinator.instance.isActive) return null;
    return database.nextExpressImageJob();
  }

  static final Expando<ExpressProcessingQueue> _instances = Expando();
  static ExpressProcessingQueue forDatabase(LocalInventoryDatabase database) =>
      _instances[database.processingScope] ??=
          ExpressProcessingQueue._(database);
  final LocalInventoryDatabase database;
  final _processor = CaptureImageProcessor();
  late final PaddleOcrChannel _ocr;
  final _post = PpStructurePostProcessor();
  late final DurableSerialRunner<ExpressImageJob> _runner;
  final Set<VoidCallback> listeners = {};
  Future<void> kick() => _runner.kick();
  Future<void> retry(String receiptId) async {
    await database.ocrPolicy.permit();
    if (await database.retryExpressImageJob(receiptId)) unawaited(kick());
  }

  Future<void> _process(ExpressImageJob job) async {
    String? processed;
    OcrPermit? permit;
    try {
      permit = await database.ocrPolicy.permit();
      if (_owners == 0 || CaptureWorkCoordinator.instance.isActive) return;
      if (!await database.isExpressImageJobCurrent(job)) return;
      permit.validate();
      processed = await _processor.process(job.imagePath, job.crop, job.token);
      if (!await database.isExpressImageJobCurrent(job)) return;
      permit.validate();
      if (_owners == 0 || CaptureWorkCoordinator.instance.isActive) return;
      final tolerance = await database.loadOcrRowMergeTolerance();
      final recognition = await _ocr.recognizeTable(processed,
          rowMergeTolerance: tolerance, permit: permit);
      var items = _post.processRows(recognition.rows);
      if (items.isEmpty && recognition.editableText.isNotEmpty) {
        items = _post.processPlainText(recognition.editableText);
      }
      if (items.isEmpty) throw const FormatException('未识别到商品，请查看原图后重试');
      await database.updateInboundOcrResult(
          receiptId: job.receiptId,
          items: items,
          ocrStatus: OcrStatus.confirmed,
          sellerOrderNumber:
              _post.extractSellerOrderNumber(recognition.editableText),
          expectedImagePath: job.imagePath,
          processedImagePath: processed,
          expectedExpressJobValue: job.encode(),
          validateOcrPermit: permit.validate);
      // 原始图片只有在新引用持久化后才可安全回收。
    } on OcrCancelled {
      // 关闭或代际变化只暂停旧任务，不标失败，也不清理原照片。
    } catch (_) {
      try {
        permit?.validate();
      } on OcrCancelled {
        return;
      }
      await database.updateInboundOcrResult(
          receiptId: job.receiptId,
          items: const [],
          ocrStatus: OcrStatus.failed,
          expectedImagePath: job.imagePath,
          expectedExpressJobValue: job.encode(),
          validateOcrPermit: permit?.validate);
    } finally {
      // 仅回收没有业务引用的派生图或已完成替换的原图。
      if (processed != null) {
        final referenced = await database.isImagePathReferenced(processed);
        final remove = referenced ? job.imagePath : processed;
        if (!await database.isImagePathReferenced(remove)) {
          final file = File(remove);
          if (await file.exists()) await file.delete();
        }
      }
      for (final listener in listeners.toList()) {
        listener();
      }
    }
  }
}
