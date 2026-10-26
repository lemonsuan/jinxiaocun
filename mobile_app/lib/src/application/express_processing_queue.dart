import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../data/local_inventory_database.dart';
import '../domain/express_capture.dart';
import '../domain/models.dart';
import '../ocr/pp_structure_post_processor.dart';
import '../platform/paddle_ocr_channel.dart';
import 'capture_image_processor.dart';

/// Serial runner: only one job is resident; pending receipts are the durable queue.
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
    _runner = DurableSerialRunner<ExpressImageJob>(
        next: database.nextExpressImageJob,
        process: _process,
        onError: (e, _) =>
            debugPrint('Express queue paused: ${e.runtimeType}'));
  }
  static ExpressProcessingQueue? _instance;
  static ExpressProcessingQueue forDatabase(LocalInventoryDatabase database) =>
      _instance ??= ExpressProcessingQueue._(database);
  final LocalInventoryDatabase database;
  final _processor = CaptureImageProcessor();
  final _ocr = PaddleOcrChannel();
  final _post = PpStructurePostProcessor();
  late final DurableSerialRunner<ExpressImageJob> _runner;
  final Set<VoidCallback> listeners = {};
  Future<void> kick() => _runner.kick();
  Future<void> retry(String receiptId) async {
    if (await database.retryExpressImageJob(receiptId)) unawaited(kick());
  }

  Future<void> _process(ExpressImageJob job) async {
    String? processed;
    try {
      if (!await database.isExpressImageJobCurrent(job)) return;
      processed = await _processor.process(job.imagePath, job.crop, job.token);
      if (!await database.isExpressImageJobCurrent(job)) return;
      final tolerance = await database.loadOcrRowMergeTolerance();
      final recognition =
          await _ocr.recognizeTable(processed, rowMergeTolerance: tolerance);
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
          expectedExpressJobValue: job.encode());
      // Keep the original as a recovery source; never delete evidence on a stale result.
    } catch (_) {
      await database.updateInboundOcrResult(
          receiptId: job.receiptId,
          items: const [],
          ocrStatus: OcrStatus.failed,
          expectedImagePath: job.imagePath,
          expectedExpressJobValue: job.encode());
    } finally {
      // Delete only unreferenced outputs. Successful replacement also releases its raw source.
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
