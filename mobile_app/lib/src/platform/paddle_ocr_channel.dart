import 'package:flutter/services.dart';

import '../domain/ocr_settings.dart';
import '../application/ocr_access_policy.dart';

/// 本地离线表格识别与文本提取的结构化结果。
///
/// 包含二维表格行列表 [rows] 和原始纯文本字符串 [rawText]。
class OcrTableResult {
  const OcrTableResult({
    required this.rows,
    required this.rawText,
  });

  /// 表格二维结构数据（外层为行，内层为单元格文本）。
  final List<List<String>> rows;

  /// OCR 引擎识别到的未经结构化拆分的原始全文文本。
  final String rawText;

  /// 提供给人机校验界面展示与编辑的纯文本形式。
  /// 若原始全文非空则返回原始全文，否则将各行单元格以制表符 \t 拼接返回。
  String get editableText {
    final text = rawText.trim();
    if (text.isNotEmpty) {
      return text;
    }
    return rows.map((row) => row.join('\t')).join('\n');
  }
}

/// PaddleOCR 原生平台通信通道。
///
/// 封装与 Android 原生 PaddleOCR / PP-Structure 推理引擎的 MethodChannel 交互，
/// 严格受 [OcrAccessPolicy] 开关许可约束：调用前获取许可并在调用返回后二次校验，
/// 确保当用户在后台识别期间关闭 OCR 开关时，识别结果被安全废弃，防止脏数据注入。
class PaddleOcrChannel {
  PaddleOcrChannel({required this.policy});

  /// 获取当前活跃的 OCR 访问控制策略。
  final OcrAccessPolicy Function() policy;

  /// 原生 MethodChannel 名称，与 Android 原生代码中的通道名一致。
  static const MethodChannel _channel =
      MethodChannel('inventory_app/paddle_ocr');

  /// 调用原生引擎对指定图片路径执行离线表格与单据识别。
  ///
  /// [imagePath] 待识别的本地图片绝对路径；
  /// [rowMergeTolerance] 表格行合并容差（数值越小越严格区分行高）；
  /// [permit] 可选预先获取的 OCR 执行许可证，若未传则现场申请；
  /// 返回解析后的二维表格结构与原始文本。
  Future<OcrTableResult> recognizeTable(
    String imagePath, {
    double rowMergeTolerance = OcrSettings.defaultRowMergeTolerance,
    OcrPermit? permit,
  }) async {
    final activePolicy = policy();
    final permission = permit ?? await activePolicy.permit();
    permission.validateFor(activePolicy);
    final result = await _channel.invokeMapMethod<String, Object?>(
      'recognizeTable',
      <String, Object?>{
        'imagePath': imagePath,
        'rowMergeTolerance': OcrSettings.normalizeRowMergeTolerance(
          rowMergeTolerance,
        ),
      },
    );
    permission.validateFor(activePolicy);
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
