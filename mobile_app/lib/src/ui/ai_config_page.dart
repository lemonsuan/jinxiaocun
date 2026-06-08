import 'package:flutter/material.dart';
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
  // Notion 极简配色
  static const Color _notionBg = Color(0xFFF7F7F5);
  static const Color _notionText = Color(0xFF37352F);
  static const Color _notionGreyText = Color(0xFF7C7B77);
  static const Color _notionBorder = Color(0xFFEDEDEB);

  bool _isLoading = true;
  bool _obscureApiKey = true;

  // 配置状态
  String _ocrMode = 'local';
  final TextEditingController _selfHostedOcrUrlController = TextEditingController();

  String _aiApiFormat = 'openai';
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _apiUrlController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _selfHostedOcrUrlController.dispose();
    _apiKeyController.dispose();
    _apiUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _isLoading = true);
    try {
      final ocrMode = await widget.database.loadOcrMode();
      final selfHostedOcrUrl = await widget.database.loadSelfHostedOcrUrl();
      final aiApiFormat = await widget.database.loadAiApiFormat();
      final apiKey = await widget.database.loadGeminiApiKey();
      final apiUrl = await widget.database.loadGeminiApiUrl();
      final model = await widget.database.loadGeminiModel();

      if (mounted) {
        setState(() {
          _ocrMode = ocrMode;
          _selfHostedOcrUrlController.text = selfHostedOcrUrl;
          _aiApiFormat = aiApiFormat;
          _apiKeyController.text = apiKey;
          _apiUrlController.text = apiUrl;
          _modelController.text = model;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('加载配置失败: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _isLoading = true);
    try {
      await widget.database.saveOcrMode(_ocrMode);
      await widget.database.saveSelfHostedOcrUrl(_selfHostedOcrUrlController.text.trim());
      await widget.database.saveAiApiFormat(_aiApiFormat);
      await widget.database.saveGeminiApiKey(_apiKeyController.text.trim());
      await widget.database.saveGeminiApiUrl(_apiUrlController.text.trim());
      await widget.database.saveGeminiModel(_modelController.text.trim());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('配置已保存'),
            duration: Duration(seconds: 1),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存配置失败: $e')),
        );
        setState(() => _isLoading = false);
      }
    }
  }

  InputDecoration _inputDecoration(String labelText, {Widget? suffixIcon}) {
    return InputDecoration(
      labelText: labelText,
      labelStyle: const TextStyle(color: _notionGreyText, fontFamily: 'monospace', fontSize: 13),
      filled: true,
      fillColor: Colors.white,
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: _notionBorder, width: 1.0),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: _notionBorder, width: 1.0),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: Colors.black, width: 1.2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _notionBg,
      appBar: AppBar(
        title: const Text(
          'OCR 与 AI 配置',
          style: TextStyle(
            color: _notionText,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        backgroundColor: _notionBg,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _notionText, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (!_isLoading)
            TextButton(
              onPressed: _saveSettings,
              child: const Text(
                '保存',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.black))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section 1: OCR 设置
                  _buildSectionTitle('OCR 识别源设置'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _notionBorder, width: 1.0),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '选择 OCR 识别模式：',
                          style: TextStyle(
                            fontSize: 12,
                            color: _notionGreyText,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: SegmentedButton<String>(
                            showSelectedIcon: false,
                            style: SegmentedButton.styleFrom(
                              selectedBackgroundColor: Colors.black,
                              selectedForegroundColor: Colors.white,
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                              side: const BorderSide(color: Colors.black, width: 0.8),
                              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                            ),
                            segments: const [
                              ButtonSegment<String>(
                                value: 'local',
                                label: Text('本机内置 OCR'),
                              ),
                              ButtonSegment<String>(
                                value: 'self_hosted',
                                label: Text('自建 OCR 服务'),
                              ),
                            ],
                            selected: {_ocrMode},
                            onSelectionChanged: (val) {
                              setState(() {
                                _ocrMode = val.first;
                              });
                            },
                          ),
                        ),
                        if (_ocrMode == 'self_hosted') ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: _selfHostedOcrUrlController,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                            decoration: _inputDecoration(
                              '自建 OCR 服务地址 (POST)',
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '同网段电脑运行 PaddleOCR-VL 服务接口，如：\nhttp://192.168.1.100:8000/layout-parsing',
                            style: TextStyle(
                              fontSize: 11,
                              color: _notionGreyText,
                              fontFamily: 'monospace',
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Section 2: 云端 AI 提取配置
                  _buildSectionTitle('云端 AI 结构化配置'),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _notionBorder, width: 1.0),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<String>(
                          value: _aiApiFormat,
                          style: const TextStyle(color: Colors.black, fontFamily: 'monospace', fontSize: 14),
                          dropdownColor: Colors.white,
                          decoration: _inputDecoration('AI API 格式'),
                          items: const [
                            DropdownMenuItem(value: 'openai', child: Text('OpenAI 兼容接口')),
                            DropdownMenuItem(value: 'gemini', child: Text('Google Gemini 格式')),
                            DropdownMenuItem(value: 'anthropic', child: Text('Anthropic Claude 格式')),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                _aiApiFormat = val;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _apiKeyController,
                          obscureText: _obscureApiKey,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                          decoration: _inputDecoration(
                            'API Key',
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureApiKey ? Icons.visibility_off : Icons.visibility,
                                color: _notionGreyText,
                                size: 20,
                              ),
                              onPressed: () {
                                setState(() {
                                  _obscureApiKey = !_obscureApiKey;
                                });
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _apiUrlController,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                          decoration: _inputDecoration('API 接口地址'),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _modelController,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                          decoration: _inputDecoration('大模型名称 (model)'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // 保存按钮 (底部主按钮)
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                      ),
                      onPressed: _saveSettings,
                      child: const Text(
                        '保存并应用配置',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.black,
        fontFamily: 'monospace',
        letterSpacing: 0.5,
      ),
    );
  }
}
