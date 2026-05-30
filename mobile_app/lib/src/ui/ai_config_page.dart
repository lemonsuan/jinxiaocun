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
    return Scaffold(
      backgroundColor: const Color(0xFFFCFCFC), // 极简纯净微偏灰色背景
      appBar: AppBar(
        title: const Text(
          'AI 提取配置',
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
                  // 1. AI 协议格式切换
                  const Text(
                    '大模型协议格式',
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
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                        side: const BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                      ),
                      segments: const [
                        ButtonSegment<String>(
                          value: 'openai',
                          label: Text(
                            'OpenAI 兼容协议',
                            style: TextStyle(fontSize: 12, letterSpacing: 0.5),
                          ),
                          icon: Icon(Icons.api_outlined, size: 14),
                        ),
                        ButtonSegment<String>(
                          value: 'anthropic',
                          label: Text(
                            'Anthropic 原生协议',
                            style: TextStyle(fontSize: 12, letterSpacing: 0.5),
                          ),
                          icon: Icon(Icons.auto_awesome_outlined, size: 14),
                        ),
                      ],
                      selected: {_selectedFormat},
                      onSelectionChanged: (val) {
                        setState(() {
                          _selectedFormat = val.first;
                          _models.clear(); // 清空旧模型列表
                          if (_selectedFormat == 'anthropic') {
                            _urlController.text = 'https://api.anthropic.com';
                            _modelController.text = 'claude-3-5-sonnet-20241022';
                          } else {
                            _urlController.text = 'https://api.deepseek.com';
                            _modelController.text = 'deepseek-v4-flash';
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 32),

                  // 2. 参数设置区域
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
                        if (_selectedFormat == 'openai' || _selectedFormat == 'anthropic') ...[
                          TextFormField(
                            controller: _urlController,
                            decoration: const InputDecoration(
                              labelText: '接口地址 (API URL)',
                              labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              hintText: '请输入 API 接口地址',
                              hintStyle: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                              border: UnderlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              focusedBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                              ),
                              isDense: true,
                            ),
                            style: const TextStyle(fontSize: 14, color: Color(0xFF1E293B)),
                          ),
                          const SizedBox(height: 24),
                        ],
                        TextFormField(
                          controller: _keyController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'API Key',
                            labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            hintText: '请输入您的 API Key',
                            hintStyle: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                            border: UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            enabledBorder: UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            focusedBorder: UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                            ),
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 14, color: Color(0xFF1E293B)),
                        ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: _isLoadingModels
                                  ? const Center(
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(vertical: 8),
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFF1E293B),
                                        ),
                                      ),
                                    )
                                  : OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF1E293B),
                                        side: const BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        textStyle: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                          fontSize: 12,
                                          letterSpacing: 1.0,
                                        ),
                                      ),
                                      onPressed: _fetchModels,
                                      icon: const Icon(Icons.sync_outlined, size: 14),
                                      label: const Text('加载云端模型'),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (_models.isNotEmpty) ...[
                          DropdownButtonFormField<String>(
                            value: _models.contains(_modelController.text)
                                ? _modelController.text
                                : _models.first,
                            decoration: const InputDecoration(
                              labelText: '选择云端模型',
                              labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                              border: UnderlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              enabledBorder: UnderlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                              ),
                              isDense: true,
                            ),
                            items: _models.map((m) {
                              return DropdownMenuItem<String>(
                                value: m,
                                child: Text(
                                  m,
                                  style: const TextStyle(fontSize: 13, color: Color(0xFF1E293B)),
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
                          const SizedBox(height: 24),
                        ],
                        TextFormField(
                          controller: _modelController,
                          decoration: const InputDecoration(
                            labelText: '当前识别模型名称',
                            labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            hintText: '例如: deepseek-chat 或 gemini-1.5-flash',
                            hintStyle: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                            border: UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            enabledBorder: UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                            ),
                            focusedBorder: UnderlineInputBorder(
                              borderSide: BorderSide(color: Color(0xFF1E293B), width: 1.2),
                            ),
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 14, color: Color(0xFF1E293B)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 3. 底栏保存
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
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
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
                          '保存配置',
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
