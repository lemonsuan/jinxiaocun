import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class PaddleOcrVlClient {
  static const String _defaultToken = 'fc05ac31fc695bbaf708e5127f20a7d9b8ad01ac';
  static const String _model = 'PaddleOCR-VL-1.6';
  static const String _jobUrl = 'https://paddleocr.aistudio-app.com/api/v2/ocr/jobs';

  /// 主入口：将本地图片路径识别为 Markdown 文本
  Future<String> recognizeImageToMarkdown(String localFilePath) async {
    final jobId = await _submitJob(localFilePath);
    debugPrint('PaddleOCR-VL-1.6 任务提交成功，任务ID: $jobId');
    
    final jsonlUrl = await _pollJobStatus(jobId);
    debugPrint('PaddleOCR-VL-1.6 任务分析完毕，结果地址: $jsonlUrl');

    final markdownText = await _fetchMarkdownResult(jsonlUrl);
    return markdownText;
  }

  /// 提交 OCR 任务
  Future<String> _submitJob(String localFilePath) async {
    final file = File(localFilePath);
    if (!file.existsSync()) {
      throw Exception('待识别的图片不存在: $localFilePath');
    }

    final uri = Uri.parse(_jobUrl);
    final request = http.MultipartRequest('POST', uri);
    
    // 设置 Authorization Header
    request.headers['Authorization'] = 'bearer $_defaultToken';

    // 构建 payload
    final optionalPayload = {
      'useDocOrientationClassify': false,
      'useDocUnwarping': false,
      'useChartRecognition': false,
    };

    request.fields['model'] = _model;
    request.fields['optionalPayload'] = jsonEncode(optionalPayload);

    // 添加本地图片文件
    final multipartFile = await http.MultipartFile.fromPath('file', localFilePath);
    request.files.add(multipartFile);

    final streamedResponse = await request.send().timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception('提交 OCR 任务失败 (HTTP ${response.statusCode}): ${response.body}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data['data'] == null || data['data']['jobId'] == null) {
      throw Exception('接口返回格式异常，未找到 jobId: ${response.body}');
    }

    return data['data']['jobId'].toString();
  }

  /// 异步轮询任务状态，直到 'done'
  Future<String> _pollJobStatus(String jobId) async {
    final url = Uri.parse('$_jobUrl/$jobId');
    final headers = {'Authorization': 'bearer $_defaultToken'};

    while (true) {
      final response = await http.get(url, headers: headers).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('轮询任务状态失败 (HTTP ${response.statusCode}): ${response.body}');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data['data'] == null) {
        throw Exception('轮询数据格式异常: ${response.body}');
      }

      final state = data['data']['state']?.toString().toLowerCase();
      if (state == 'pending') {
        debugPrint('PaddleOCR-VL-1.6 任务状态: pending (排队中)...');
      } else if (state == 'running') {
        try {
          final progress = data['data']['extractProgress'];
          final total = progress['totalPages'];
          final extracted = progress['extractedPages'];
          debugPrint('PaddleOCR-VL-1.6 任务状态: running (识别中), 总页数: $total, 已提取: $extracted');
        } catch (_) {
          debugPrint('PaddleOCR-VL-1.6 任务状态: running (识别中)...');
        }
      } else if (state == 'done') {
        final jsonUrl = data['data']['resultUrl']?['jsonUrl']?.toString();
        if (jsonUrl == null || jsonUrl.isEmpty) {
          throw Exception('任务完成但结果地址为空');
        }
        return jsonUrl;
      } else if (state == 'failed') {
        final errorMsg = data['data']['errorMsg']?.toString() ?? '未知错误';
        throw Exception('PaddleOCR-VL-1.6 任务执行失败: $errorMsg');
      }

      // 等待 5 秒
      await Future.delayed(const Duration(seconds: 5));
    }
  }

  /// 下载并解析 JSONL 格式的 Markdown 识别文本
  Future<String> _fetchMarkdownResult(String jsonlUrl) async {
    final response = await http.get(Uri.parse(jsonlUrl)).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('获取 JSONL 结果失败 (HTTP ${response.statusCode})');
    }

    // JSONL 每行是一个 JSON 串
    final lines = utf8.decode(response.bodyBytes).trim().split('\n');
    final buffer = StringBuffer();

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      try {
        final parsed = jsonDecode(trimmed);
        final results = parsed['result']?['layoutParsingResults'] as List<dynamic>?;
        if (results == null) continue;

        for (final res in results) {
          final text = res['markdown']?['text']?.toString();
          if (text != null && text.isNotEmpty) {
            buffer.writeln(text);
          }
        }
      } catch (e) {
        debugPrint('解析 JSONL 行数据出错: $e');
      }
    }

    return buffer.toString();
  }
}
