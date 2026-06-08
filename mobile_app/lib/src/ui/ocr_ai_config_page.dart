import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../data/local_inventory_database.dart';
import '../domain/ocr_settings.dart';

class ApiPreset {
  final String name;
  final String url;
  final String defaultModel;

  const ApiPreset({
    required this.name,
    required this.url,
    required this.defaultModel,
  });
}

const List<ApiPreset> _openaiPresets = [
  ApiPreset(name: 'DeepSeek', url: 'https://api.deepseek.com', defaultModel: 'deepseek-chat'),
  ApiPreset(name: 'OpenAI 官方', url: 'https://api.openai.com', defaultModel: 'gpt-4o-mini'),
  ApiPreset(name: 'Gemini (兼容)', url: 'https://generativelanguage.googleapis.com/v1beta', defaultModel: 'gemini-1.5-flash'),
  ApiPreset(name: 'Kimi', url: 'https://api.moonshot.cn', defaultModel: 'moonshot-v1-8k'),
  ApiPreset(name: '通义千问', url: 'https://dashscope.aliyuncs.com/compatible-mode', defaultModel: 'qwen-turbo'),
  ApiPreset(name: 'MiniMax', url: 'https://api.minimax.io/v1', defaultModel: 'abab6.5s-chat'),
  ApiPreset(name: '小米 MiMo', url: 'https://api.xiaomimimo.com/v1', defaultModel: 'mimo-v2.5'),
];

const List<ApiPreset> _anthropicPresets = [
  ApiPreset(name: 'Anthropic 官方', url: 'https://api.anthropic.com', defaultModel: 'claude-3-5-sonnet-20241022'),
];

class OcrAiConfigPage extends StatefulWidget {
  final LocalInventoryDatabase database;

  const OcrAiConfigPage({
    super.key,
    required this.database,
  });

  @override
  State<OcrAiConfigPage> createState() => _OcrAiConfigPageState();
}

class _OcrAiConfigPageState extends State<OcrAiConfigPage> {
  // 1. 活跃引擎
  String _activeEngine = 'local_ocr'; // 'local_ocr', 'self_hosted_ocr', 'cloud_ai_ocr'

  // 2. 本机 OCR 行距
  double _ocrRowMergeTolerance = OcrSettings.defaultRowMergeTolerance;

  // 3. 自建 OCR
  final TextEditingController _selfHostedUrlController = TextEditingController();
  bool _isTestingSelfHosted = false;

  // 4. 云端 AI
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  String _selectedFormat = 'openai'; // 'openai' 或 'gemini' (anthropic)
  List<String> _models = [];
  bool _isLoadingModels = false;
  bool _isTestingConnection = false;
  bool _obscureApiKey = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _selfHostedUrlController.dispose();
    _urlController.dispose();
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final engine = await widget.database.loadActiveOcrEngine();
    final tolerance = await widget.database.loadOcrRowMergeTolerance();
    final selfHostedUrl = await widget.database.loadSelfHostedOcrUrl();

    final format = await widget.database.loadAiApiFormat();
    final url = await widget.database.loadGeminiApiUrl();
    final key = await widget.database.loadGeminiApiKey();
    final model = await widget.database.loadGeminiModel();

    setState(() {
      _activeEngine = engine;
      _ocrRowMergeTolerance = OcrSettings.normalizeRowMergeTolerance(tolerance);
      _selfHostedUrlController.text = selfHostedUrl;

      _selectedFormat = format == 'gemini' ? 'anthropic' : format;
      _urlController.text = url;
      _keyController.text = key;
      if (model.isNotEmpty) {
        _modelController.text = model;
      } else {
        _modelController.text = _selectedFormat == 'anthropic'
            ? 'claude-3-5-sonnet-20241022'
            : 'deepseek-chat';
      }
    });
  }

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

  Future<void> _testSelfHostedOcr() async {
    final url = _selfHostedUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入自建 OCR 服务接口地址')),
      );
      return;
    }

    setState(() {
      _isTestingSelfHosted = true;
    });

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: jsonEncode({
          'image': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
        }),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200 || response.statusCode == 400) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
              title: const Text('连接测试成功', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              content: Text('自建 OCR 服务端口响应正常！(HTTP 状态码: ${response.statusCode})'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('确定', style: TextStyle(color: Color(0xFF1E293B))),
                ),
              ],
            ),
          );
        }
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            title: const Text('连接测试失败', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.red)),
            content: Text('无法连接至该自建 OCR 服务，请确认 IP 端口在同一个局域网下。\n报错详情: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('确定', style: TextStyle(color: Color(0xFF1E293B))),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTestingSelfHosted = false;
        });
      }
    }
  }

  Future<void> _fetchModels() async {
    final format = _selectedFormat;
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();

    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入 API Key')),
      );
      return;
    }

    setState(() {
      _isLoadingModels = true;
    });

    try {
      if (format == 'openai') {
        if (url.isEmpty) {
          throw Exception('请输入接口地址 (API URL)');
        }
        final requestUrl = _normalizeUrl(url, 'models');
        final response = await http.get(
          Uri.parse(requestUrl),
          headers: {
            'Authorization': 'Bearer $key',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(utf8.decode(response.bodyBytes));
          if (data is Map && data['data'] is List) {
            final list = data['data'] as List;
            final models = list
                .map((m) => m['id']?.toString() ?? '')
                .where((m) => m.isNotEmpty)
                .toList();
            setState(() {
              _models = models;
              if (models.isNotEmpty &&
                  !models.contains(_modelController.text)) {
                _modelController.text = models.first;
              }
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('成功加载了 ${models.length} 个模型！')),
              );
            }
          } else {
            throw Exception('返回数据格式不符合 OpenAI 规范');
          }
        } else {
          throw Exception('HTTP ${response.statusCode}: ${response.body}');
        }
      } else {
        if (url.isEmpty) {
          throw Exception('请输入接口地址 (API URL)');
        }
        final requestUrl = _normalizeUrl(url, 'models');
        final response = await http.get(
          Uri.parse(requestUrl),
          headers: {
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(utf8.decode(response.bodyBytes));
          if (data is Map && data['data'] is List) {
            final list = data['data'] as List;
            final models = list
                .map((m) => m['id']?.toString() ?? '')
                .where((m) => m.isNotEmpty)
                .toList();
            setState(() {
              _models = models;
              if (models.isNotEmpty &&
                  !models.contains(_modelController.text)) {
                _modelController.text = models.first;
              }
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('成功加载了 ${models.length} 个 Anthropic 模型！')),
              );
            }
          } else {
            throw Exception('返回数据格式不符合 Anthropic 规范');
          }
        } else {
          throw Exception('HTTP ${response.statusCode}: ${response.body}');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载模型失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingModels = false;
        });
      }
    }
  }

  Future<void> _testConnection() async {
    final format = _selectedFormat;
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    final model = _modelController.text.trim();

    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入 API Key')),
      );
      return;
    }
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入接口地址 (API URL)')),
      );
      return;
    }
    if (model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入或选择识别模型名称')),
      );
      return;
    }

    setState(() {
      _isTestingConnection = true;
    });

    try {
      if (format == 'openai') {
        final requestUrl = _normalizeUrl(url, 'chat/completions');
        final response = await http.post(
          Uri.parse(requestUrl),
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': 'Say hello in 3 words.'},
            ],
            'max_tokens': 10,
          }),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(utf8.decode(response.bodyBytes));
          final text = data['choices'][0]['message']['content'].toString().trim();
          if (mounted) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                title: const Text('测试连接成功', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                content: Text('模型响应: "$text"'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('好的', style: TextStyle(color: Color(0xFF1E293B))),
                  ),
                ],
              ),
            );
          }
        } else {
          throw Exception('HTTP ${response.statusCode}: ${response.body}');
        }
      } else {
        final requestUrl = _normalizeUrl(url, 'messages');
        final response = await http.post(
          Uri.parse(requestUrl),
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'x-api-key': key,
            'anthropic-version': '2023-06-01',
          },
          body: jsonEncode({
            'model': model,
            'max_tokens': 10,
            'messages': [
              {
                'role': 'user',
                'content': 'Say hello in 3 words.',
              }
            ],
          }),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(utf8.decode(response.bodyBytes));
          final text = data['content'][0]['text'].toString().trim();
          if (mounted) {
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                title: const Text('测试连接成功', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                content: Text('模型响应: "$text"'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('好的', style: TextStyle(color: Color(0xFF1E293B))),
                  ),
                ],
              ),
            );
          }
        } else {
          throw Exception('HTTP ${response.statusCode}: ${response.body}');
        }
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            title: const Text('测试连接失败', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.red)),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('确定', style: TextStyle(color: Color(0xFF1E293B))),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTestingConnection = false;
        });
      }
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    try {
      final selfHostedUrl = _selfHostedUrlController.text.trim();
      final url = _urlController.text.trim();
      final key = _keyController.text.trim();
      final model = _modelController.text.trim();

      // 1. 保存引擎和本机 OCR、自建 OCR 核心参数
      await widget.database.saveActiveOcrEngine(_activeEngine);
      await widget.database.saveOcrRowMergeTolerance(_ocrRowMergeTolerance);
      await widget.database.saveSelfHostedOcrUrl(selfHostedUrl);

      // 2. 保存云端大模型提取参数
      await widget.database.saveAiApiFormat(_selectedFormat);
      await widget.database.saveGeminiApiUrl(url);
      await widget.database.saveGeminiApiKey(key);
      await widget.database.saveGeminiModel(model);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('识别引擎配置保存成功！')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final valueText = _ocrRowMergeTolerance.toStringAsFixed(2);

    return Scaffold(
      backgroundColor: const Color(0xFFFCFCFC), // Notion 偏白灰底色
      appBar: AppBar(
        title: const Text(
          'OCR 与 AI 识别配置',
          style: TextStyle(
            fontWeight: FontWeight.w400,
            fontSize: 16,
            letterSpacing: 1.5,
            color: Color(0xFF1E293B),
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: const Color(0xFF1E293B),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. 识别引擎切换
                  const Text(
                    '当前默认识别引擎',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(
                        shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.zero),
                        side: const BorderSide(
                            color: Color(0xFFE2E8F0), width: 0.8),
                        selectedBackgroundColor: Colors.black,
                        selectedForegroundColor: Colors.white,
                      ),
                      segments: const [
                        ButtonSegment<String>(
                          value: 'local_ocr',
                          label: Text('本机 OCR', style: TextStyle(fontSize: 11)),
                          icon: Icon(Icons.phone_android_outlined, size: 14),
                        ),
                        ButtonSegment<String>(
                          value: 'self_hosted_ocr',
                          label: Text('自建 OCR', style: TextStyle(fontSize: 11)),
                          icon: Icon(Icons.lan_outlined, size: 14),
                        ),
                        ButtonSegment<String>(
                          value: 'cloud_ai_ocr',
                          label: Text('云端 AI OCR', style: TextStyle(fontSize: 11)),
                          icon: Icon(Icons.cloud_outlined, size: 14),
                        ),
                      ],
                      selected: {_activeEngine},
                      onSelectionChanged: (val) {
                        setState(() {
                          _activeEngine = val.first;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 2. 根据选定的识别引擎显示专有卡片
                  if (_activeEngine == 'local_ocr') ...[
                    const Text(
                      '本机 OCR 配置',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: const Color(0xFFE2E8F0), width: 0.8),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '当前模式: 本地离线表格识别后，发送给云端大模型进行信息规范化提取。',
                            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'OCR 识别行距容差: $valueText',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF1E293B)),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text('控制行行归纳合并的阈值，值越小行越紧凑。',
                                        style: TextStyle(
                                            fontSize: 11, color: Colors.grey)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 120,
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6),
                                    overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 10),
                                  ),
                                  child: Slider(
                                    min: OcrSettings.minRowMergeTolerance,
                                    max: OcrSettings.maxRowMergeTolerance,
                                    divisions: 8,
                                    activeColor: Colors.black,
                                    inactiveColor: Colors.grey.shade300,
                                    value: _ocrRowMergeTolerance,
                                    onChanged: (value) {
                                      setState(() {
                                        _ocrRowMergeTolerance =
                                            OcrSettings.normalizeRowMergeTolerance(
                                                value);
                                      });
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ] else if (_activeEngine == 'self_hosted_ocr') ...[
                    const Text(
                      '自建 OCR 配置 (PaddleOCR-VL-1.6)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: const Color(0xFFE2E8F0), width: 0.8),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '当前模式: 将图片发送至局域网部署的 PaddleOCR-VL-1.6 大模型服务获取排版文本，再送入云端大模型提取。',
                            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _selfHostedUrlController,
                            decoration: const InputDecoration(
                              labelText: '自建 OCR 接口 URL 地址',
                              labelStyle: TextStyle(
                                  color: Color(0xFF94A3B8), fontSize: 13),
                              hintText: 'http://<WiFi下的电脑IP>:8080/layout-parsing',
                              hintStyle: TextStyle(
                                  color: Color(0xFFCBD5E1), fontSize: 13),
                              border: UnderlineInputBorder(
                                borderSide: BorderSide(
                                    color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(
                                    color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              focusedBorder: UnderlineInputBorder(
                                borderSide: BorderSide(
                                    color: Color(0xFF1E293B), width: 1.2),
                              ),
                              isDense: true,
                            ),
                            style: const TextStyle(
                                fontSize: 13, color: Color(0xFF1E293B)),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            child: _isTestingSelfHosted
                                ? const Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.black,
                                      ),
                                    ),
                                  )
                                : OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.black,
                                      side: const BorderSide(
                                          color: Color(0xFFE2E8F0), width: 0.8),
                                      shape: const RoundedRectangleBorder(
                                          borderRadius: BorderRadius.zero),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                    ),
                                    onPressed: _testSelfHostedOcr,
                                    icon: const Icon(Icons.bolt_outlined, size: 14),
                                    label: const Text('测试自建 OCR 服务连接 (WiFi 下)',
                                        style: TextStyle(fontSize: 12)),
                                  ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ] else if (_activeEngine == 'cloud_ai_ocr') ...[
                    const Text(
                      '云端 AI OCR 说明',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: const Color(0xFFE2E8F0), width: 0.8),
                      ),
                      padding: const EdgeInsets.all(20),
                      child: const Text(
                        '当前模式: 依靠多模态大模型的视觉理解能力，直接读取图片内容提取商品清单 JSON（大模型需支持图片多模态输入，如 gpt-4o 或 gemini-1.5-flash）。',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B), height: 1.5),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // 3. 通用底层云端 AI 配置
                  const Text(
                    '底层云端 AI 提取配置 (所有引擎均需要大模型支持)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(
                        color: const Color(0xFFE2E8F0),
                        width: 0.8,
                      ),
                    ),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '协议格式',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B)),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            style: SegmentedButton.styleFrom(
                              shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.zero),
                              side: const BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            segments: const [
                              ButtonSegment<String>(
                                value: 'openai',
                                label: Text(
                                  'OpenAI 兼容协议',
                                  style: TextStyle(fontSize: 11),
                                ),
                                icon: Icon(Icons.api_outlined, size: 14),
                              ),
                              ButtonSegment<String>(
                                value: 'anthropic',
                                label: Text(
                                  'Anthropic 协议',
                                  style: TextStyle(fontSize: 11),
                                ),
                                icon: Icon(Icons.auto_awesome_outlined, size: 14),
                              ),
                            ],
                            selected: {_selectedFormat},
                            onSelectionChanged: (val) {
                              setState(() {
                                _selectedFormat = val.first;
                                _models.clear();
                                if (_selectedFormat == 'anthropic') {
                                  _urlController.text = 'https://api.anthropic.com';
                                  _modelController.text =
                                      'claude-3-5-sonnet-20241022';
                                } else {
                                  _urlController.text = 'https://api.deepseek.com';
                                  _modelController.text = 'deepseek-chat';
                                }
                              });
                            },
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _urlController,
                          decoration: const InputDecoration(
                            labelText: '接口地址 (API URL)',
                            labelStyle: TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 13),
                            hintText: '请输入 API 接口地址',
                            border: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            enabledBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            focusedBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFF1E293B), width: 1.2),
                            ),
                            isDense: true,
                          ),
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF1E293B)),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: (_selectedFormat == 'anthropic'
                                  ? _anthropicPresets
                                  : _openaiPresets)
                              .map((preset) {
                            final isSelected =
                                _urlController.text.trim() == preset.url;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _urlController.text = preset.url;
                                  _modelController.text = preset.defaultModel;
                                  _models.clear();
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF1E293B)
                                      : const Color(0xFFF1F5F9),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF1E293B)
                                        : const Color(0xFFE2E8F0),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  preset.name,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isSelected
                                        ? Colors.white
                                        : const Color(0xFF475569),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _keyController,
                          obscureText: _obscureApiKey,
                          decoration: InputDecoration(
                            labelText: 'API Key',
                            labelStyle: const TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 13),
                            hintText: '请输入您的 API Key',
                            border: const UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            enabledBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            focusedBorder: const UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFF1E293B), width: 1.2),
                            ),
                            isDense: true,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureApiKey
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 18,
                                color: const Color(0xFF94A3B8),
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscureApiKey = !_obscureApiKey;
                                });
                              },
                            ),
                          ),
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF1E293B)),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: _isTestingConnection
                                  ? const Center(
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      ),
                                    )
                                  : OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.black,
                                        side: const BorderSide(
                                            color: Color(0xFFE2E8F0),
                                            width: 0.8),
                                        shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.zero),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10),
                                      ),
                                      onPressed: _testConnection,
                                      icon: const Icon(Icons.bolt_outlined, size: 14),
                                      label: const Text('测试 AI 连接',
                                          style: TextStyle(fontSize: 11)),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _isLoadingModels
                                  ? const Center(
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.black,
                                        ),
                                      ),
                                    )
                                  : OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.black,
                                        side: const BorderSide(
                                            color: Color(0xFFE2E8F0),
                                            width: 0.8),
                                        shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.zero),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10),
                                      ),
                                      onPressed: _fetchModels,
                                      icon: const Icon(Icons.sync_outlined, size: 14),
                                      label: const Text('加载云端模型',
                                          style: TextStyle(fontSize: 11)),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        if (_models.isNotEmpty) ...[
                          DropdownButtonFormField<String>(
                            initialValue:
                                _models.contains(_modelController.text)
                                    ? _modelController.text
                                    : _models.first,
                            decoration: const InputDecoration(
                              labelText: '选择云端模型',
                              labelStyle: TextStyle(
                                  color: Color(0xFF94A3B8), fontSize: 13),
                              border: UnderlineInputBorder(
                                borderSide: BorderSide(
                                    color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(
                                    color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              isDense: true,
                            ),
                            items: _models.map((m) {
                              return DropdownMenuItem<String>(
                                value: m,
                                child: Text(
                                  m,
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF1E293B)),
                                ),
                              );
                            }).toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() {
                                  _modelController.text = val;
                                });
                              }
                            },
                          ),
                          const SizedBox(height: 20),
                        ],
                        TextFormField(
                          controller: _modelController,
                          decoration: const InputDecoration(
                            labelText: '当前识别模型名称',
                            labelStyle: TextStyle(
                                color: Color(0xFF94A3B8), fontSize: 13),
                            hintText: '例如: deepseek-chat 或 gemini-1.5-flash',
                            border: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            enabledBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            focusedBorder: UnderlineInputBorder(
                              borderSide: BorderSide(
                                  color: Color(0xFF1E293B), width: 1.2),
                            ),
                            isDense: true,
                          ),
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF1E293B)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 4. 底栏保存
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(
                  color: Color(0xFFF1F5F9),
                  width: 0.8,
                ),
              ),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero),
                    elevation: 0,
                  ),
                  onPressed: _isSaving ? null : _saveConfig,
                  child: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '保存引擎配置',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2.0,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
