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
  final TextEditingController _confirmPasswordController = TextEditingController();
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
    final baseUrl = _serverUrlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (baseUrl.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = '请填写完整的连接参数及账号密码';
      });
      return;
    }

    // 注册专属前端强校验
    if (_isSignUp) {
      final confirmPassword = _confirmPasswordController.text.trim();
      final phone = _phoneController.text.trim();

      if (confirmPassword.isEmpty) {
        setState(() {
          _errorMessage = '请再次输入密码以确认';
        });
        return;
      }
      if (password != confirmPassword) {
        setState(() {
          _errorMessage = '两次输入的密码不一致，请重新检查';
        });
        return;
      }
      if (phone.isEmpty) {
        setState(() {
          _errorMessage = '请输入您的手机号';
        });
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final endpoint = _isSignUp ? '/api/auth/register' : '/api/auth/login';

      final Map<String, dynamic> requestBody = {
        'username': username,
        'password': password,
      };
      if (_isSignUp) {
        requestBody['phone'] = _phoneController.text.trim();
      }

      final response = await http.post(
        Uri.parse('$baseUrl$endpoint'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      ).timeout(const Duration(seconds: 12));

      final body = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        final token = body['token'] as String;
        final resUsername = body['username'] as String;
        _tempToken = token;
        _tempUsername = resUsername;

        // 保存服务器基地址
        await _database.saveSyncServerUrl(baseUrl);

        // 鉴权成功后，立刻拉取该用户的店铺列表
        await _fetchShops(baseUrl, token);
      } else {
        setState(() {
          _errorMessage = body['message'] ?? '鉴权失败，请检查账号密码。';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '连接超时或服务器无法访问，请确保基地址配置正确。';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fetchShops(String baseUrl, String token) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/shops/my-shops'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> list = jsonDecode(utf8.decode(response.bodyBytes));
        final items = list.map((e) => _ShopItem.fromJson(e)).toList();

        setState(() {
          _shops = items;
          _showShopSelector = true; // 开启店铺选择视图
        });
      } else {
        setState(() {
          _errorMessage = '拉取关联店铺列表失败。';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '店铺数据通信失败，请检查网络。';
      });
    }
  }

  Future<void> _createAndEnterShop() async {
    final shopName = _newShopNameController.text.trim();
    if (shopName.isEmpty) return;

    setState(() {
      _isCreatingShop = true;
    });

    try {
      final baseUrl = _serverUrlController.text.trim();
      final token = _tempToken!;

      final response = await http.post(
        Uri.parse('$baseUrl/api/shops/create'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'name': shopName}),
      ).timeout(const Duration(seconds: 10));

      final body = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        final newShopId = body['id'] as String;
        // 创建店铺成功，自动激活并登入
        await _enterShop(newShopId, shopName);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(body['message'] ?? '创建店铺失败')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('网络连接异常，无法创建店铺')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCreatingShop = false;
        });
      }
    }
  }

  Future<void> _enterShop(String shopId, String shopName) async {
    // 写入本地数据库，代表在线同步版登录并选择店铺成功！
    await _database.saveAuthMode('online');
    await _database.saveSyncServerUrl(_serverUrlController.text.trim());
    await _database.saveAuthToken(_tempToken!);
    await _database.saveActiveShopId(shopId);
    await _database.saveActiveShopName(shopName);

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const AppHome()),
      );
    }
  }

  // 固定的本地默认店铺 ID 常量，用于合并离线版本与云端店铺的底层租户架构，消除双版本复杂性
  static const String _defaultLocalShopId = '00000000-0000-0000-0000-000000000000';

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
                child: _showShopSelector ? _buildShopSelectorView() : _buildAuthView(),
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
              style: const TextStyle(color: Colors.redAccent, fontSize: 12, height: 1.4),
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
              const Text('服务器 API 基地址',
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _notionGreyText)),
              const SizedBox(height: 4),
              TextField(
                controller: _serverUrlController,
                decoration: const InputDecoration(
                  hintText: 'http://10.0.2.2:8000',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),

              // 用户名
              const Text('用户名',
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _notionGreyText)),
              const SizedBox(height: 4),
              TextField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  hintText: '输入您的账号',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),

              // 密码
              const Text('密码',
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _notionGreyText)),
              const SizedBox(height: 4),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  hintText: '输入账户密码',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),

              if (_isSignUp) ...[
                // 确认密码
                const Text('确认密码',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _notionGreyText)),
                const SizedBox(height: 4),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    hintText: '再次输入密码以确认',
                    border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),

                // 手机号
                const Text('手机号',
                    style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: _notionGreyText)),
                const SizedBox(height: 4),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    hintText: '输入您的手机号',
                    border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    elevation: 0,
                  ),
                  onPressed: _isLoading ? null : _submitAuth,
                  child: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          _isSignUp ? '快速注册并登录' : '登录云同步版',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
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
              onPressed: () {
                setState(() {
                  _isSignUp = !_isSignUp;
                  _errorMessage = null;
                });
              },
              child: Text(
                _isSignUp ? '已有账号？立即登录' : '没有账号？立即注册',
                style: const TextStyle(color: _notionText, fontSize: 12, fontWeight: FontWeight.w600),
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
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
            ),
            onPressed: _enterOfflineMode,
            icon: const Icon(Icons.storefront_outlined, size: 16),
            label: const Text(
              '放弃登录，返回本地默认店铺',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, fontFamily: 'monospace'),
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
            Expanded(
              child: Text(
                'SELECT SHOP',
                style: const TextStyle(
                  fontSize: 24,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: _notionText,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _showShopSelector = false;
                  _tempToken = null;
                });
              },
              child: const Text('返回登录', style: TextStyle(color: _notionGreyText, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '欢迎回来，$_tempUsername。请选择进入的店铺多租户工作区：',
          style: const TextStyle(fontSize: 12, color: _notionGreyText),
        ),
        const SizedBox(height: 20),

        // 已经批准的店铺列表
        if (approvedShops.isNotEmpty) ...[
          const Text('可进入的店铺',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _notionGreyText)),
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
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                subtitle: Text('角色：${shop.role == "CREATOR" ? "创建者" : "店员"}',
                    style: const TextStyle(fontSize: 11, color: _notionGreyText)),
                trailing: const Icon(Icons.arrow_forward_ios, size: 12, color: _notionText),
                onTap: () => _enterShop(shop.shopId, shop.shopName),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],

        // 审批中的店铺列表
        if (pendingShops.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text('等待审核批准的店铺',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _notionGreyText)),
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
                subtitle: const Text('加入申请审核中...', style: TextStyle(fontSize: 11, color: Colors.amber)),
                trailing: const Icon(Icons.hourglass_empty, size: 14, color: Colors.amber),
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
                '您当前还没有绑定任何商铺\n请在下方输入商铺名以创建全新店铺工作区',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _notionGreyText, height: 1.5),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),

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
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _notionText)),
              const SizedBox(height: 8),
              TextField(
                controller: _newShopNameController,
                decoration: const InputDecoration(
                  hintText: '输入新商铺的名称',
                  border: OutlineInputBorder(borderRadius: BorderRadius.zero),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    elevation: 0,
                  ),
                  onPressed: _isCreatingShop ? null : _createAndEnterShop,
                  child: _isCreatingShop
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(color: _notionText, strokeWidth: 2),
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
