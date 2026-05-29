import 'dart:convert';
import 'package:http/http.dart' as http;
import '../data/local_inventory_database.dart';
import '../domain/models.dart';

class GemmaExtractionResult {
  GemmaExtractionResult({
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

class GemmaExtractor {
  GemmaExtractor(this._database);

  final LocalInventoryDatabase _database;

  Future<GemmaExtractionResult> extract(String ocrText) async {
    var apiKey = await _database.loadGeminiApiKey();
    if (apiKey.isEmpty) {
      apiKey = 'sk-7530d0e7a047446591a992ea3c13c9d2';
    }

    var apiUrl = await _database.loadGeminiApiUrl();
    if (apiUrl.isEmpty || apiUrl == 'https://generativelanguage.googleapis.com') {
      apiUrl = 'https://api.deepseek.com';
    }
    // 确保没有尾随斜杠
    if (apiUrl.endsWith('/')) {
      apiUrl = apiUrl.substring(0, apiUrl.length - 1);
    }

    var model = await _database.loadGeminiModel();
    if (model.isEmpty || model == 'gemini-1.5-flash' || model == 'built-in') {
      model = 'deepseek-v4-flash';
    }

    final systemPrompt = '你是一个极其严格的入库清单结构化数据提取助手。你必须且仅能输出纯粹的标准 JSON，严禁输出任何解释、文字说明、Markdown 首尾包裹标记（如 ```json）。为了极速生成，若某个属性在文本中未提及或为空，绝对不要输出其对应的键值对（Key-Value）。';
    final userPrompt = '请从下面的 OCR 文本中提取入库清单信息。规则如下：\n'
        '1. 识别“订单号/订单编号”并提取为 `seller_order_number`，“快递单号/运单号”提取为 `tracking_number`，“计划单/入库单”提取为 `scheme_number`。\n'
        '2. 商品明细保存为 `items` 列表。每个商品项：产品/商品编号提取为 `product_code`，产品/商品名称提取为 `product_name`，数量提取为整数 `quantity`（默认为 1），采购价提取为数字 `purchase_price`，销售价提取为数字 `sale_price`。\n'
        '3. 🚨【极速原则】如果某项信息未在文本中提及或无法确定，请直接在 JSON 中忽略该键（Key），绝对不要输出它！\n\n'
        '【待解析 OCR 文本如下】:\n$ocrText';

    final response = await http.post(
      Uri.parse('$apiUrl/v1/chat/completions'),
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
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('API请求失败 (HTTP ${response.statusCode}): ${utf8.decode(response.bodyBytes)}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final content = data['choices'][0]['message']['content'].toString().trim();

    // 清理可能的 markdown 包裹
    var jsonText = content;
    if (jsonText.startsWith('```')) {
      final match = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(jsonText);
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

    return GemmaExtractionResult(
      trackingNumber: parsed['tracking_number']?.toString(),
      sellerOrderNumber: parsed['seller_order_number']?.toString(),
      schemeNumber: parsed['scheme_number']?.toString(),
      items: items,
    );
  }
}