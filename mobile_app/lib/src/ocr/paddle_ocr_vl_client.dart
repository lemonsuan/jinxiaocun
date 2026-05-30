import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class PaddleOcrVlClient {
  static const String _defaultToken = 'fc05ac31fc695bbaf708e5127f20a7d9b8ad01ac';
  static const String _layoutUrl = 'https://paddleocr.aistudio-app.com/layout-parsing';

  /// 主入口：调用 PaddleOCR-VL 版面解析 API 将本地图片识别为 Markdown 文本
  Future<String> recognizeImageToMarkdown(String localFilePath) async {
    final file = File(localFilePath);
    if (!file.existsSync()) {
      throw Exception('待识别的图片不存在: $localFilePath');
    }

    // 1. 读取并编码为 Base64
    final bytes = await file.readAsBytes();
    final base64Image = base64Encode(bytes);

    // 2. 构造请求 Payload
    final payload = {
      'file': base64Image,
      'fileType': 1, // 1 表示图像文件
      'useDocOrientationClassify': true, // 用户要求：开启图片方向自动矫正
      'useDocUnwarping': true, // 开启扭曲矫正
      'useLayoutDetection': true, // 开启版面区域分析检测
      'useChartRecognition': false, // 图表解析默认关闭
    };

    debugPrint('PaddleOCR-VL-1.6 版面解析任务提交中... (已开启自动方向与扭曲矫正)');

    final uri = Uri.parse(_layoutUrl);
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'bearer $_defaultToken',
      },
      body: jsonEncode(payload),
    ).timeout(const Duration(seconds: 45)); // 版面解析可能需要较长运算时间，超时设为 45 秒

    if (response.statusCode != 200) {
      throw Exception('版面解析请求失败 (HTTP ${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final result = data['result'];
    if (result == null) {
      throw Exception('版面解析接口返回错误或为空: ${response.body}');
    }

    final resultsList = result['layoutParsingResults'] as List<dynamic>?;
    if (resultsList == null || resultsList.isEmpty) {
      throw Exception('版面解析结果列表为空');
    }

    final buffer = StringBuffer();
    for (final page in resultsList) {
      final markdown = page['markdown'];
      if (markdown != null) {
        final text = markdown['text']?.toString();
        if (text != null && text.isNotEmpty) {
          buffer.writeln(text);
        }
      }
    }

    final markdownText = buffer.toString().trim();
    debugPrint('PaddleOCR-VL-1.6 版面解析完成，提取字符数: ${markdownText.length}');
    return markdownText;
  }
}
