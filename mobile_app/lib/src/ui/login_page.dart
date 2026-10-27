import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../data/local_inventory_database.dart';
import 'app_home.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const Color _notionBg = Color(0xFFF7F7F5);
  static const Color _notionText = Color(0xFF37352F);
  static const Color _notionGreyText = Color(0xFF7C7B77);
  static const Color _notionBorder = Color(0xFFEDEDEB);

  final LocalInventoryDatabase _database = LocalInventoryDatabase();

  final TextEditingController _serverUrlController =
      TextEditingController(text: 'http://10.0.2.2:8000');
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _newShopNameController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  bool _isSignUp = false; // 是否为注册模式
  bool _isLoading = false;
  String? _errorMessage;

  // 鉴权成功后暂存的数据，用于店铺选择界面
  String? _tempToken;
  String? _tempUsername;
  List<_ShopItem> _shops = [];
  bool _showShopSelector = false; // 是否正处于店铺选择子界面
  bool _isCreatingShop = false;
  bool _isRefreshingShops = false;
  bool _isJoiningShop = false;
  bool _isEnteringShop = false;
  String? _authenticatedServer;
  int _requestEpoch = 0;
  final _joinShopIdController = TextEditingController();
  bool get _shopBusy =>
      _isCreatingShop ||
      _isRefreshingShops ||
      _isJoiningShop ||
      _isEnteringShop;

  String _normalizedServer() =>
      _serverUrlController.text.trim().replaceFirst(RegExp(r'/+$'), '');

  bool _validServer(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        !uri.path.split('/').contains('api');
  }

  String _responseMessage(dynamic body, String fallback) {
    if (body is Map) {
      final message = body['detail'] ?? body['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return fallback;
  }

  void _showError(String message) {
    if (mounted) setState(() => _errorMessage = message);
  }

  @override
  void initState() {
    super.initState();
    _database.open().then((_) {
      // 预载本地已存的服务器地址以方便用户
      _database.loadSyncServerUrl().then((savedUrl) {
        if (savedUrl.isNotEmpty && mounted) {
          _serverUrlController.text = savedUrl;
        }
      });
    });
  }

  @override
  void dispose() {
    _requestEpoch++;
    _joinShopIdController.dispose();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _newShopNameController.dispose();
    _confirmPasswordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  // ─── HTTP 业务请求方法 ──────────────────────────────────────────

  Future<void> _submitAuth() async {
    if (_isLoading) return;
    final baseUrl = _normalizedServer();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (!_validServer(baseUrl)) {
      _showError(
          '请输入有效的 http:// 或 https:// 服务器地址，不含 /api、查询参数或账号信息。真机请填写服务器局域网 IP。');
      return;
    }
    if (username.isEmpty || password.isEmpty) {
      _showError('请填写账号和密码');
      return;
    }
    if (_isSignUp) {
      if (password != _confirmPasswordController.text) {
        _showError('两次输入的密码不一致，请重新检查');
        return;
      }
      if (_phoneController.text.trim().isEmpty) {
        _showError('请输入您的手机号');
        return;
      }
    }
    final epoch = ++_requestEpoch;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final endpoint = _isSignUp ? '/api/auth/register' : '/api/auth/login';
      final response = await http
          .post(
            Uri.parse('$baseUrl$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'username': username,
              'password': password,
              if (_isSignUp) 'phone': _phoneController.text.trim(),
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted || epoch != _requestEpoch) return;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode == 200 || response.statusCode == 201) {
        _tempToken = body['token'] as String;
        _tempUsername = body['username'] as String;
        _authenticatedServer = baseUrl;
        await _database.saveSyncServerUrl(baseUrl);
        if (!mounted || epoch != _requestEpoch) return;
        setState(() {
          _shops = [];
          _showShopSelector = true;
        });
        await _fetchShops();
      } else {
        _showError(_responseMessage(body, '鉴权失败，请检查账号密码。'));
      }
    } catch (_) {
      if (epoch == _requestEpoch) {
        _showError('连接超时或服务器无法访问。真机请使用服务器局域网 IP，并确认手机与服务器网络互通。');
      }
    } finally {
      if (mounted && epoch == _requestEpoch) setState(() => _isLoading = false);
    }
  }

  Future<bool> _fetchShops() async {
    final token = _tempToken;
    final baseUrl = _authenticatedServer;
    final epoch = _requestEpoch;
    if (token == null || baseUrl == null) return false;
    setState(() {
      _isRefreshingShops = true;
      _errorMessage = null;
    });
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/shops/my-shops'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (!mounted || epoch != _requestEpoch) return false;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode == 200 && body is List) {
        final items = body
            .map((item) =>
                _ShopItem.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList();
        setState(() => _shops = items);
        return true;
      }
      _showError(_responseMessage(body, '获取店铺失败，请刷新重试或重新登录。'));
    } catch (_) {
      if (epoch == _requestEpoch) _showError('店铺数据通信失败，请检查网络后刷新。');
    } finally {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _isRefreshingShops = false);
      }
    }
    return false;
  }

  Future<void> _joinShop() async {
    if (_shopBusy) return;
    final id = _joinShopIdController.text.trim();
    if (!RegExp(
            r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(id)) {
      _showError('请输入管理员提供的完整店铺 ID（UUID）');
      return;
    }
    final epoch = _requestEpoch;
    setState(() {
      _isJoiningShop = true;
      _errorMessage = null;
    });
    try {
      final response = await http
          .post(
            Uri.parse('$_authenticatedServer/api/shops/join'),
            headers: {
              'Authorization': 'Bearer $_tempToken',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({'shop_id': id}),
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted || epoch != _requestEpoch) return;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode == 200 || response.statusCode == 201) {
        _joinShopIdController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('申请已提交，请联系店铺管理员审批，然后刷新审批状态。')));
        await _fetchShops();
      } else {
        _showError(_responseMessage(body, '申请加入失败，请检查店铺 ID。'));
      }
    } catch (_) {
      if (epoch == _requestEpoch) _showError('网络异常，申请可能已提交，请刷新店铺列表确认。');
    } finally {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _isJoiningShop = false);
      }
    }
  }

  Future<void> _createAndEnterShop() async {
    if (_shopBusy) return;
    final shopName = _newShopNameController.text.trim();
    if (shopName.isEmpty) {
      _showError('请输入店铺名称');
      return;
    }
    final epoch = _requestEpoch;
    setState(() {
      _isCreatingShop = true;
      _errorMessage = null;
    });
    try {
      final response = await http
          .post(
            Uri.parse('$_authenticatedServer/api/shops/create'),
            headers: {
              'Authorization': 'Bearer $_tempToken',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({'name': shopName}),
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted || epoch != _requestEpoch) return;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode == 200 || response.statusCode == 201) {
        await _enterShop(body['id'] as String, shopName);
      } else {
        _showError(_responseMessage(body, '创建店铺失败'));
      }
    } catch (_) {
      if (epoch == _requestEpoch) _showError('网络异常，请刷新店铺列表确认是否已创建。');
    } finally {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _isCreatingShop = false);
      }
    }
  }

  Future<void> _enterShop(String shopId, String shopName) async {
    if (_isEnteringShop) return;
    setState(() => _isEnteringShop = true);
    try {
      // Recheck approval immediately before activating the persistent workspace.
      if (!await _fetchShops() || !mounted) return;
      if (!_shops
          .any((shop) => shop.shopId == shopId && shop.status == 'APPROVED')) {
        _showError('此店铺尚未审批通过或权限已变更，请联系管理员。');
        return;
      }
      await _database.saveAuthMode('online');
      await _database.saveSyncServerUrl(_authenticatedServer!);
      await _database.saveAuthToken(_tempToken!);
      await _database.saveActiveShopId(shopId);
      await _database.saveActiveShopName(shopName);
      if (mounted) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const AppHome()));
      }
    } catch (_) {
      _showError('无法打开店铺，请重试。已有本机数据已保留。');
    } finally {
      if (mounted) setState(() => _isEnteringShop = false);
    }
  }

  // 固定的本地默认店铺 ID 常量，用于合并离线版本与云端店铺的底层租户架构，消除双版本复杂性
  static const String _defaultLocalShopId =
      '00000000-0000-0000-0000-000000000000';

  Future<void> _enterOfflineMode() async {
    // 免密进入离线模式：自动激活“默认本地店铺 ID”，实现全数据流统一归档
    await _database.saveAuthMode('offline');
    await _database.saveActiveShopId(_defaultLocalShopId);
    await _database.saveActiveShopName('本地默认店铺');
    await _database.saveAuthToken('');
    await _database.saveSyncServerUrl('');

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const AppHome()),
      );
    }
  }

  // ─── 页面 Widget 组装 ──────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _notionBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _showShopSelector
                    ? _buildShopSelectorView()
                    : _buildAuthView(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // 1. 登录/注册主视图
  Widget _buildAuthView() {
    return Column(
      key: const ValueKey('auth_view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部极简文本
        Text(
          _isSignUp ? 'REGISTER' : 'SIGN IN',
          style: const TextStyle(
            fontSize: 28,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            letterSpacing: 2.0,
            color: _notionText,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _isSignUp ? '创建云端账户以同步多端库存数据' : '登录您的云端账户以同步多端店铺数据',
          style: const TextStyle(fontSize: 12, color: _notionGreyText),
        ),
        const SizedBox(height: 24),

        // 报错信息高亮
        if (_errorMessage != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEBEE),
              border: Border.all(color: Colors.redAccent, width: 0.8),
            ),
            child: Text(
              _errorMessage!,
              style: const TextStyle(
                  color: Colors.redAccent, fontSize: 12, height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // 表单卡片容器 (直角 Notion 风)
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _notionBorder, width: 1.0),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 服务器地址
              const Text('服务器地址（不含 /api）',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _notionGreyText)),
              const SizedBox(height: 4),
              TextField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  hintText: 'http://10.0.2.2:8000',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 6),
              const Text(
                  '真机请填写服务器局域网 IP（如 http://192.168.1.10:8000）；10.0.2.2 仅适用于 Android 模拟器。',
                  style: TextStyle(fontSize: 11, color: _notionGreyText)),
              const SizedBox(height: 16),

              // 用户名
              const Text('用户名',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _notionGreyText)),
              const SizedBox(height: 4),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  hintText: '输入您的账号',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),

              // 密码
              const Text('密码',
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: _notionGreyText)),
              const SizedBox(height: 4),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: '输入账户密码',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),

              if (_isSignUp) ...[
                // 确认密码
                const Text('确认密码',
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: _notionGreyText)),
                const SizedBox(height: 4),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: '再次输入密码以确认',
                    border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),

                // 手机号
                const Text('手机号',
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: _notionGreyText)),
                const SizedBox(height: 4),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    hintText: '输入您的手机号',
                    border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
              ],
              const SizedBox(height: 4),

              // 核心提交大按钮 (纯黑直角)
              SizedBox(
                width: double.infinity,
                height: 44,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _notionText,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero),
                    elevation: 0,
                  ),
                  onPressed: _isLoading ? null : _submitAuth,
                  child: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          _isSignUp ? '快速注册并登录' : '登录云同步版',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 切换登录/注册与直接进入离线版
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: _isLoading
                  ? null
                  : () {
                      setState(() {
                        _isSignUp = !_isSignUp;
                        _errorMessage = null;
                      });
                    },
              child: Text(
                _isSignUp ? '已有账号？立即登录' : '没有账号？立即注册',
                style: const TextStyle(
                    color: _notionText,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // 完全离线版入口 (高对比度尖锐虚线框或双边线)
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _notionText,
              backgroundColor: Colors.white,
              side: const BorderSide(color: _notionText, width: 1.0),
              shape:
                  const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            ),
            onPressed: _isLoading ? null : _enterOfflineMode,
            icon: const Icon(Icons.storefront_outlined, size: 16),
            label: const Text(
              '放弃登录，返回本地默认店铺',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  fontFamily: 'monospace'),
            ),
          ),
        ),
      ],
    );
  }

  // 2. 店铺列表与创建店铺子界面
  Widget _buildShopSelectorView() {
    final approvedShops = _shops.where((s) => s.status == 'APPROVED').toList();
    final pendingShops = _shops.where((s) => s.status == 'PENDING').toList();

    return Column(
      key: const ValueKey('shop_view'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题
        Row(
          children: [
            const Expanded(
              child: Text(
                'SELECT SHOP',
                style: TextStyle(
                  fontSize: 24,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: _notionText,
                ),
              ),
            ),
            TextButton(
              onPressed: _shopBusy
                  ? null
                  : () {
                      setState(() {
                        _requestEpoch++;
                        _showShopSelector = false;
                        _tempToken = null;
                        _authenticatedServer = null;
                        _shops = [];
                        _errorMessage = null;
                      });
                    },
              child: const Text('返回登录',
                  style: TextStyle(color: _notionGreyText, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '欢迎回来，$_tempUsername。请选择进入的店铺多租户工作区：',
          style: const TextStyle(fontSize: 12, color: _notionGreyText),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _shopBusy ? null : _fetchShops,
          icon: const Icon(Icons.refresh, size: 16),
          label: Text(_isRefreshingShops ? '正在刷新…' : '刷新店铺与审批状态'),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
        const SizedBox(height: 20),

        // 已经批准的店铺列表
        if (approvedShops.isNotEmpty) ...[
          const Text('可进入的店铺',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _notionGreyText)),
          const SizedBox(height: 6),
          for (final shop in approvedShops) ...[
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _notionBorder, width: 1.0),
              ),
              child: ListTile(
                title: Text(
                  shop.shopName,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                ),
                subtitle: Text('角色：${shop.role == "CREATOR" ? "创建者" : "店员"}',
                    style:
                        const TextStyle(fontSize: 11, color: _notionGreyText)),
                trailing: const Icon(Icons.arrow_forward_ios,
                    size: 12, color: _notionText),
                onTap: _shopBusy
                    ? null
                    : () => _enterShop(shop.shopId, shop.shopName),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],

        // 审批中的店铺列表
        if (pendingShops.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('等待审核批准的店铺',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _notionGreyText)),
          const SizedBox(height: 6),
          for (final shop in pendingShops) ...[
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _notionBorder, width: 1.0),
              ),
              child: ListTile(
                title: Text(
                  shop.shopName,
                  style: const TextStyle(fontSize: 14, color: _notionGreyText),
                ),
                subtitle: const Text('加入申请审核中...',
                    style: TextStyle(fontSize: 11, color: Colors.amber)),
                trailing: const Icon(Icons.hourglass_empty,
                    size: 14, color: Colors.amber),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],

        // 空状态说明
        if (approvedShops.isEmpty && pendingShops.isEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _notionBorder, width: 1.0),
            ),
            child: const Center(
              child: Text(
                '您当前还没有可进入的店铺\n可申请加入现有店铺，或创建全新店铺工作区',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: _notionGreyText, height: 1.5),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),

        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.white, border: Border.all(color: _notionBorder)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('加入已有店铺',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
                controller: _joinShopIdController,
                decoration: const InputDecoration(
                    hintText: '输入管理员提供的店铺 ID',
                    border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                    isDense: true),
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            const Text('审批通过后才能进入。待审批的店铺不会读取或上传本机数据。',
                style: TextStyle(fontSize: 11, color: _notionGreyText)),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: _shopBusy ? null : _joinShop,
                child: Text(_isJoiningShop ? '正在提交…' : '提交加入申请')),
          ]),
        ),
        const SizedBox(height: 16),
        // 创建全新店铺容器
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: _notionBorder, width: 1.0),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('创建全新商铺工作区',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _notionText)),
              const SizedBox(height: 8),
              TextField(
                controller: _newShopNameController,
                decoration: const InputDecoration(
                  hintText: '输入新商铺的名称',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 40,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: _notionText,
                    side: const BorderSide(color: _notionText, width: 0.8),
                    shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero),
                    elevation: 0,
                  ),
                  onPressed: _shopBusy ? null : _createAndEnterShop,
                  child: _isCreatingShop
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: _notionText, strokeWidth: 2),
                        )
                      : const Text('创建并直接登入'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── 店铺数据模型 ───────────────────────────────────────────────

class _ShopItem {
  _ShopItem({
    required this.shopId,
    required this.shopName,
    required this.role,
    required this.status,
  });

  final String shopId;
  final String shopName;
  final String role;
  final String status;

  factory _ShopItem.fromJson(Map<String, dynamic> json) {
    return _ShopItem(
      shopId: json['shop_id'] as String,
      shopName: json['shop_name'] as String,
      role: json['role'] as String,
      status: json['status'] as String,
    );
  }
}
