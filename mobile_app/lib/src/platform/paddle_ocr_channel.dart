import 'package:flutter/services.dart';

import '../domain/ocr_settings.dart';

class OcrTableResult {
  const OcrTableResult({
    required this.rows,
    required this.rawText,
  });

  final List<List<String>> rows;
  final String rawText;

  String get editableText {
    final text = rawText.trim();
    if (text.isNotEmpty) {
      return text;
    }
    return rows.map((row) => row.join('\t')).join('\n');
  }
}

class PaddleOcrChannel {
  static const MethodChannel _channel =
      MethodChannel('inventory_app/paddle_ocr');

  Future<OcrTableResult> recognizeTable(
    String imagePath, {
    double rowMergeTolerance = OcrSettings.defaultRowMergeTolerance,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'recognizeTable',
      <String, Object?>{
        'imagePath': imagePath,
        'rowMergeTolerance': OcrSettings.normalizeRowMergeTolerance(
          rowMergeTolerance,
        ),
      },
    );
    return OcrTableResult(
      rows: _parseRows(result?['rows']),
      rawText: result?['rawText']?.toString() ?? '',
    );
  }

  List<List<String>> _parseRows(Object? rows) {
    if (rows is! List) {
      return const [];
    }
    return rows.map((row) {
      if (row is! List) {
        return const <String>[];
      }
      return row.map((cell) => cell?.toString() ?? '').toList();
    }).toList();
  }
}
