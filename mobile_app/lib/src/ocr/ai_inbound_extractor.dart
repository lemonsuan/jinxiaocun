import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../data/local_inventory_database.dart';
import '../domain/models.dart';
import '../platform/paddle_ocr_channel.dart';

class AiInboundExtractionResult {
  AiInboundExtractionResult({
    this.trackingNumber,
    this.sellerOrderNumber,
    this.schemeNumber,
    required this.items,
  });

  final String? trackingNumber;
  final String? sellerOrderNumber;
  final String? schemeNumber;
  final List<InboundDraftItem> items;
}

/// 通用 AI 提取服务类（先调用本地离线 OCR，再使用配置的云端大模型提取）
class AiInboundExtractor {
  AiInboundExtractor(this._database);

  final LocalInventoryDatabase _database;
  final PaddleOcrChannel _paddleOcr = PaddleOcrChannel();

  String _normalizeUrl(String baseUrl, String endpoint) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final hasVersion = RegExp(r'/v\d+(beta|alpha)?$').hasMatch(url) ||
        RegExp(r'/v\d+(beta|alpha)?/').hasMatch(url);
    if (hasVersion) {
      return '$url/$endpoint';
    } else {
      return '$url/v1/$endpoint';
    }
  }

  Future<Map<String, String>> _loadConfig() async {
    final aiFormat = await _database.loadAiApiFormat();
    final apiKey = await _database.loadGeminiApiKey();
    var apiUrl = await _database.loadGeminiApiUrl();
    final model = await _database.loadGeminiModel();

    if (apiKey.trim().isEmpty) {
      throw Exception('未检测到 AI API Key，请先在 [系统设置 -> AI 智能提取配置] 中配置。');
    }

    if (apiUrl.trim().isEmpty) {
      throw Exception('未检测到 AI API 接口地址，请先在 [系统设置 -> AI 智能提取配置] 中配置。');
    }

    // 确保没有尾随斜杠
    apiUrl = apiUrl.trim();
    if (apiUrl.endsWith('/')) {
      apiUrl = apiUrl.substring(0, apiUrl.length - 1);
    }

    if (model.trim().isEmpty) {
      throw Exception('未检测到 AI 模型名称，请先在 [系统设置 -> AI 智能提取配置] 中配置。');
    }

    return {
      'aiFormat': aiFormat,
      'apiKey': apiKey.trim(),
      'apiUrl': apiUrl,
      'model': model.trim(),
    };
  }

  Future<AiInboundExtractionResult> extract(String ocrText) async {
    final config = await _loadConfig();
    final aiFormat = config['aiFormat']!;
    final apiKey = config['apiKey']!;
    final apiUrl = config['apiUrl']!;
    final model = config['model']!;

    const systemPrompt =
        '你是一个极其严格的入库清单结构化数据提取助手。你必须且仅能输出纯粹的标准 JSON，严禁输出任何解释、文字说明、Markdown 首尾包裹标记（如 ```json）。为了极速生成，若某个属性在文本中未提及或为空，绝对不要输出其对应的键值对（Key-Value）。';
    final userPrompt = '请从下面的 OCR 文本中提取入库清单信息。规则如下：\n'
        '1. 识别“订单号/订单编号”并提取为 `seller_order_number`，“快递单号/运单号”提取为 `tracking_number`，“计划单/入库单”提取为 `scheme_number`。\n'
        '2. 商品明细保存为 `items` 列表。每个商品项：产品/商品编号提取为 `product_code`，产品/商品名称提取为 `product_name`，数量提取为整数 `quantity`（默认为 1），采购价提取为数字 `purchase_price`，销售价提取为数字 `sale_price`。\n'
        '3. 🚨【极速原则】如果某项信息未在文本中提及或无法确定，请直接在 JSON 中忽略该键（Key），绝对不要输出它！\n\n'
        '【待解析 OCR 文本如下】:\n$ocrText';

    String content = '';

    if (aiFormat == 'gemini' || aiFormat == 'anthropic') {
      final requestUrl = _normalizeUrl(apiUrl, 'messages');
      final response = await http
          .post(
            Uri.parse(requestUrl),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': 2048,
              'system': systemPrompt,
              'messages': [
                {
                  'role': 'user',
                  'content': userPrompt,
                }
              ],
              'temperature': 0.0,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception(
            'Anthropic API请求失败 (HTTP ${response.statusCode}): ${utf8.decode(response.bodyBytes)}');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      content = data['content'][0]['text'].toString().trim();
    } else {
      final requestUrl = _normalizeUrl(apiUrl, 'chat/completions');
      final response = await http
          .post(
            Uri.parse(requestUrl),
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                {'role': 'user', 'content': userPrompt},
              ],
              'temperature': 0.0,
              'response_format': {'type': 'json_object'},
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception(
            'API请求失败 (HTTP ${response.statusCode}): ${utf8.decode(response.bodyBytes)}');
      }

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      content = data['choices'][0]['message']['content'].toString().trim();
    }

    return _parseJsonToResult(content);
  }

  /// 先通过本地离线/自建 OCR 获取文本，再由配置的大模型进行结构化清洗提取
  Future<AiInboundExtractionResult> extractFromImage(String imagePath) async {
    final ocrMode = await _database.loadOcrMode();
    String ocrText = '';

    if (ocrMode == 'self_hosted') {
      final url = await _database.loadSelfHostedOcrUrl();
      if (url.trim().isEmpty) {
        throw Exception('自建 OCR 服务地址未配置，请先在[我的 -> OCR与AI配置]中配置。');
      }

      final file = File(imagePath);
      if (!await file.exists()) {
        throw Exception('待识别的图片文件不存在: $imagePath');
      }
      final bytes = await file.readAsBytes();
      final base64String = base64Encode(bytes);

      final uri = Uri.parse(url.trim());
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode({'image': base64String}),
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode != 200) {
        throw Exception('自建 OCR 服务请求失败 (HTTP ${response.statusCode}): ${utf8.decode(response.bodyBytes)}');
      }

      String? extractedText;
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map) {
          extractedText = decoded['markdown']?.toString() ??
                          decoded['text']?.toString() ??
                          decoded['result']?.toString() ??
                          decoded['data']?.toString();
        } else if (decoded is String) {
          extractedText = decoded;
        }
      } catch (_) {
        // 解析 JSON 失败，可能返回的直接是纯文本 Markdown，在下方 fallback 捕获
      }

      extractedText ??= utf8.decode(response.bodyBytes);
      ocrText = extractedText;
      if (ocrText.trim().isEmpty) {
        throw Exception('自建 OCR 服务未返回任何识别文本');
      }
    } else {
      final ocrResult = await _paddleOcr.recognizeTable(imagePath);
      ocrText = ocrResult.editableText;
      if (ocrText.trim().isEmpty) {
        throw Exception('本地 OCR 识别失败，未提取到任何文字');
      }
    }

    return extract(ocrText);
  }

  AiInboundExtractionResult _parseJsonToResult(String content) {
    // 清理可能的 markdown 包裹
    var jsonText = content;
    if (jsonText.startsWith('```')) {
      final match =
          RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(jsonText);
      if (match != null) {
        jsonText = match.group(1)!;
      }
    }

    final parsed = jsonDecode(jsonText.trim()) as Map<String, dynamic>;

    final itemsList = parsed['items'] as List<dynamic>? ?? const [];
    final items = <InboundDraftItem>[];
    for (final item in itemsList) {
      final map = item as Map<String, dynamic>;
      final productName = map['product_name']?.toString() ?? '';
      if (productName.isEmpty) continue;

      final qtyRaw = map['quantity'];
      var qty = 1;
      if (qtyRaw != null) {
        if (qtyRaw is num) {
          qty = qtyRaw.toInt();
        } else {
          qty = int.tryParse(qtyRaw.toString()) ?? 1;
        }
      }

      double? purchasePrice;
      final purchasePriceRaw = map['purchase_price'];
      if (purchasePriceRaw != null) {
        if (purchasePriceRaw is num) {
          purchasePrice = purchasePriceRaw.toDouble();
        } else {
          purchasePrice = double.tryParse(purchasePriceRaw.toString());
        }
      }

      double? salePrice;
      final salePriceRaw = map['sale_price'];
      if (salePriceRaw != null) {
        if (salePriceRaw is num) {
          salePrice = salePriceRaw.toDouble();
        } else {
          salePrice = double.tryParse(salePriceRaw.toString());
        }
      }

      items.add(
        InboundDraftItem(
          productCode: map['product_code']?.toString(),
          productName: productName,
          quantity: qty,
          purchasePrice: purchasePrice,
          salePrice: salePrice,
          sourceText: 'AI Extract',
        ),
      );
    }

    return AiInboundExtractionResult(
      trackingNumber: parsed['tracking_number']?.toString(),
      sellerOrderNumber: parsed['seller_order_number']?.toString(),
      schemeNumber: parsed['scheme_number']?.toString(),
      items: items,
    );
  }
}
