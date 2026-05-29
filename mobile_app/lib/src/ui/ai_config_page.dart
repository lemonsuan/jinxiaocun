import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../data/local_inventory_database.dart';

class AiConfigPage extends StatefulWidget {
  final LocalInventoryDatabase database;

  const AiConfigPage({
    super.key,
    required this.database,
  });

  @override
  State<AiConfigPage> createState() => _AiConfigPageState();
}

class _AiConfigPageState extends State<AiConfigPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();

  String _selectedFormat = 'openai'; // 'openai' 或 'gemini'
  List<String> _models = [];
  bool _isLoadingModels = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final format = await widget.database.loadAiApiFormat();
    final url = await widget.database.loadGeminiApiUrl();
    final key = await widget.database.loadGeminiApiKey();
    final model = await widget.database.loadGeminiModel();

    setState(() {
      _selectedFormat = format == 'gemini' ? 'anthropic' : format;
      _urlController.text = url;
      _keyController.text = key;
      if (model.isNotEmpty) {
        _modelController.text = model;
      } else {
        _modelController.text = _selectedFormat == 'anthropic'
            ? 'claude-3-5-sonnet-20241022'
            : 'deepseek-v4-flash';
      }
    });
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
        var requestUrl = url;
        if (requestUrl.endsWith('/')) {
          requestUrl = requestUrl.substring(0, requestUrl.length - 1);
        }
        final response = await http.get(
          Uri.parse('$requestUrl/v1/models'),
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
              if (models.isNotEmpty && !models.contains(_modelController.text)) {
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
        // anthropic 格式
        if (url.isEmpty) {
          throw Exception('请输入接口地址 (API URL)');
        }
        var requestUrl = url;
        if (requestUrl.endsWith('/')) {
          requestUrl = requestUrl.substring(0, requestUrl.length - 1);
        }
        final response = await http.get(
          Uri.parse('$requestUrl/v1/models'),
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
              if (models.isNotEmpty && !models.contains(_modelController.text)) {
                _modelController.text = models.first;
              }
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('成功加载了 ${models.length} 个 Anthropic 模型！')),
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

  Future<void> _saveConfig() async {
    setState(() => _isSaving = true);
    try {
      final url = _urlController.text.trim();
      final key = _keyController.text.trim();
      final model = _modelController.text.trim();

      await widget.database.saveAiApiFormat(_selectedFormat);
      await widget.database.saveGeminiApiUrl(url);
      await widget.database.saveGeminiApiKey(key);
      await widget.database.saveGeminiModel(model);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('AI 提取配置保存成功！')),
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
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 提取配置', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. AI 协议格式切换
                  const Text(
                    '大模型协议格式',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment<String>(
                          value: 'openai',
                          label: Text('OpenAI 兼容协议'),
                          icon: Icon(Icons.api_outlined),
                        ),
                        ButtonSegment<String>(
                          value: 'anthropic',
                          label: Text('Anthropic 原生协议'),
                          icon: Icon(Icons.auto_awesome_outlined),
                        ),
                      ],
                      selected: {_selectedFormat},
                      onSelectionChanged: (val) {
                        setState(() {
                          _selectedFormat = val.first;
                          _models.clear(); // 清空旧模型列表
                          if (_selectedFormat == 'anthropic') {
                            _urlController.text =
                                'https://api.anthropic.com';
                            _modelController.text = 'claude-3-5-sonnet-20241022';
                          } else {
                            _urlController.text = 'https://api.deepseek.com';
                            _modelController.text = 'deepseek-v4-flash';
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 2. 参数设置卡片
                  Card(
                    elevation: 0,
                    color: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_selectedFormat == 'openai' || _selectedFormat == 'anthropic') ...[
                            TextFormField(
                              controller: _urlController,
                              decoration: const InputDecoration(
                                labelText: '接口地址 (API URL)',
                                hintText: '请输入供货商的 API 基址',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              style: const TextStyle(fontSize: 14),
                            ),
                            const SizedBox(height: 16),
                          ],
                          TextFormField(
                            controller: _keyController,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'API Key',
                              hintText: '请输入供货商提供的 API 密钥',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            style: const TextStyle(fontSize: 14),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: _isLoadingModels
                                    ? const Center(
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(vertical: 8),
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Color(0xff2d6a4f),
                                          ),
                                        ),
                                      )
                                    : OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: const Color(0xff2d6a4f),
                                          side: const BorderSide(
                                              color: Color(0xff2d6a4f), width: 1.2),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          padding:
                                              const EdgeInsets.symmetric(vertical: 12),
                                        ),
                                        onPressed: _fetchModels,
                                        icon: const Icon(Icons.sync_outlined, size: 16),
                                        label: const Text(
                                          '加载供货商模型',
                                          style: TextStyle(fontWeight: FontWeight.bold),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (_models.isNotEmpty) ...[
                            DropdownButtonFormField<String>(
                              value: _models.contains(_modelController.text)
                                  ? _modelController.text
                                  : _models.first,
                              decoration: const InputDecoration(
                                labelText: '选择供货商提供的模型',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _models.map((m) {
                                return DropdownMenuItem<String>(
                                  value: m,
                                  child: Text(m, style: const TextStyle(fontSize: 13)),
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
                            const SizedBox(height: 16),
                          ],
                          TextFormField(
                            controller: _modelController,
                            decoration: const InputDecoration(
                              labelText: '当前识别模型名称',
                              hintText: '例如: deepseek-chat 或 gemini-1.5-flash',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 3. 底栏保存
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                )
              ],
            ),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xff2d6a4f),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isSaving ? null : _saveConfig,
                child: _isSaving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Text(
                        '保存 AI 接口配置',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
