part of 'local_inventory_database.dart';

/// 默认工作区与历史入口属于本机配置，永远不随业务备份导出。
extension RememberedInventoryWorkspaces on LocalInventoryDatabase {
  static const _defaultWorkspaceKey = 'default_workspace_id';
  static const _workspaceInitializedKey = 'workspace_registry_initialized';

  Future<void> _workspaceSchema() async {
    await _settings.execute('''CREATE TABLE IF NOT EXISTS workspace_profiles(
      id TEXT PRIMARY KEY,mode TEXT NOT NULL,server_url TEXT NOT NULL,
      shop_id TEXT NOT NULL,shop_name TEXT NOT NULL,account_id TEXT NOT NULL,
      account_name TEXT NOT NULL,token TEXT NOT NULL,last_entered TEXT NOT NULL)''');
    await _settings.insert('workspace_profiles', _localWorkspaceRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Map<String, Object?> _localWorkspaceRow() => {
        'id': SavedWorkspace.localId,
        'mode': 'offline',
        'server_url': '',
        'shop_id': SavedWorkspace.localShopId,
        'shop_name': '本地默认店铺',
        'account_id': '',
        'account_name': '',
        'token': '',
        'last_entered': DateTime.now().toIso8601String(),
      };

  SavedWorkspace _publicWorkspace(Map row) => SavedWorkspace(
        id: row['id'] as String,
        isLocal: row['mode'] == 'offline',
        serverUrl: row['server_url'] as String,
        shopId: row['shop_id'] as String,
        shopName: row['shop_name'] as String,
        accountId: row['account_id'] as String,
        accountName: row['account_name'] as String,
      );

  void _validateWorkspace(Map row) {
    if (row['mode'] == 'offline' &&
        row['id'] == SavedWorkspace.localId &&
        row['shop_id'] == SavedWorkspace.localShopId &&
        row['server_url'] == '' &&
        row['token'] == '') {
      return;
    }
    final uri = Uri.tryParse('${row['server_url']}');
    if (row['mode'] != 'online' ||
        uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        '${row['shop_id']}'.trim().isEmpty ||
        '${row['token']}'.isEmpty) {
      throw InventoryException('已保存的店铺配置不完整，请在设置中重新登录或选择本地模式。');
    }
  }

  String _workspaceScope(Map row) => row['mode'] == 'offline'
      ? 'offline'
      : '${row['server_url']}\n${row['shop_id']}';

  Future<void> _preflightWorkspace(Map row) async {
    _validateWorkspace(row);
    // 注入内存连接的单元测试沿用该连接；真实工作区必须预检实际目标库。
    if (_configuration == null && _directory == null) return;
    final directory = _directory ?? await getApplicationDocumentsDirectory();
    await directory.create(recursive: true);
    final filename =
        'inventory_${sha256.convert(utf8.encode(_workspaceScope(row)))}.db';
    final target = await (_factory ?? databaseFactory).openDatabase(
        path.join(directory.path, filename),
        options: _businessOptions(singleInstance: false));
    try {
      final check = await target.rawQuery('PRAGMA quick_check(1)');
      if (check.isEmpty || check.single.values.single != 'ok') {
        throw InventoryException('目标店铺的本机数据库异常，原工作区已保留。');
      }
      final probe = LocalInventoryDatabase(database: target);
      await probe._ensureSync();
    } finally {
      await target.close();
    }
  }

  Future<void> _selectWorkspace(
      Transaction txn, Map<String, Object?> row) async {
    final now = DateTime.now().toIso8601String();
    for (final entry in {
      _defaultWorkspaceKey: row['id'] as String,
      _workspaceInitializedKey: '1',
      LocalInventoryDatabase._authModeKey: row['mode'] as String,
      LocalInventoryDatabase._syncServerUrlKey: row['server_url'] as String,
      LocalInventoryDatabase._authTokenKey: row['token'] as String,
      LocalInventoryDatabase._activeShopIdKey: row['shop_id'] as String,
      LocalInventoryDatabase._activeShopNameKey: row['shop_name'] as String,
    }.entries) {
      await txn.insert('app_settings',
          {'key': entry.key, 'value': entry.value, 'updated_at': now},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await txn.update('workspace_profiles', {'last_entered': now},
        where: 'id=?', whereArgs: [row['id']]);
  }

  /// 首次使用保留本地默认入口，旧安装则只迁移当前真实保存的店铺。
  Future<SavedWorkspace> ensureDefaultWorkspace() async {
    await _workspaceSchema();
    if (await _setting(_workspaceInitializedKey) != '1') {
      final config = await _authSnapshot();
      final mode = config[LocalInventoryDatabase._authModeKey] ?? '';
      Map<String, Object?> row;
      if (mode == 'offline' ||
          (mode.isEmpty &&
              (config[LocalInventoryDatabase._activeShopIdKey] ?? '')
                  .isEmpty)) {
        row = _localWorkspaceRow();
      } else if (mode == 'online') {
        row = _sharedWorkspaceRow(
          serverUrl: config[LocalInventoryDatabase._syncServerUrlKey] ?? '',
          token: config[LocalInventoryDatabase._authTokenKey] ?? '',
          shopId: config[LocalInventoryDatabase._activeShopIdKey] ?? '',
          shopName:
              config[LocalInventoryDatabase._activeShopNameKey] ?? '已保存店铺',
          accountId: '',
          accountName: '以前登录的账户',
        );
      } else {
        throw InventoryException('默认工作区配置异常，请在设置中重新选择，原数据已保留。');
      }
      await _preflightWorkspace(row);
      await _settings.transaction((txn) async {
        final marker = await txn.query('app_settings',
            where: 'key=?', whereArgs: [_workspaceInitializedKey]);
        if (marker.isNotEmpty && marker.single['value'] == '1') return;
        await txn.insert('workspace_profiles', row,
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await _selectWorkspace(txn, row);
      });
    }
    return _readDefaultWorkspace();
  }

  Future<SavedWorkspace> loadDefaultWorkspace() => ensureDefaultWorkspace();

  Future<SavedWorkspace> _readDefaultWorkspace() async {
    final id = await _setting(_defaultWorkspaceKey);
    final rows = await _settings
        .query('workspace_profiles', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) {
      throw InventoryException('找不到默认工作区，请在设置中重新选择，原数据已保留。');
    }
    _validateWorkspace(rows.single);
    final config = await _authSnapshot();
    final row = rows.single;
    if (config[LocalInventoryDatabase._authModeKey] != row['mode'] ||
        _InventoryScope._server(
                config[LocalInventoryDatabase._syncServerUrlKey] ?? '') !=
            row['server_url'] ||
        (config[LocalInventoryDatabase._authTokenKey] ?? '') != row['token'] ||
        (config[LocalInventoryDatabase._activeShopIdKey] ?? '') !=
            row['shop_id']) {
      throw InventoryException('默认工作区配置不一致，请在设置中重新选择，原数据已保留。');
    }
    return _publicWorkspace(row);
  }

  Future<List<SavedWorkspace>> loadSavedWorkspaces() async {
    await _workspaceSchema();
    // 默认配置损坏时仍可列出本地和历史入口，供设置页面显式恢复。
    return (await _settings.query('workspace_profiles',
            orderBy:
                "CASE mode WHEN 'offline' THEN 0 ELSE 1 END,last_entered DESC"))
        .map(_publicWorkspace)
        .toList(growable: false);
  }

  /// 只允许选择本机已经登记的入口，不接受手填店铺编号来创建离线授权。
  Future<SavedWorkspace> activateSavedWorkspace(String id) async {
    await _workspaceSchema();
    final rows = await _settings
        .query('workspace_profiles', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) throw InventoryException('此店铺尚未在本机成功登录，请先在线登录并进入。');
    await _preflightWorkspace(rows.single);
    return _settings.transaction((txn) async {
      final current =
          await txn.query('workspace_profiles', where: 'id=?', whereArgs: [id]);
      if (current.isEmpty) throw InventoryException('工作区资料已变化，请刷新后重试。');
      _validateWorkspace(current.single);
      await _selectWorkspace(txn, current.single);
      return _publicWorkspace(current.single);
    });
  }

  Map<String, Object?> _sharedWorkspaceRow({
    required String serverUrl,
    required String token,
    required String shopId,
    required String shopName,
    required String accountId,
    required String accountName,
  }) {
    final server = _InventoryScope._server(serverUrl);
    final identity = '$server\n$shopId\n$accountId';
    return {
      'id': 'shared-${sha256.convert(utf8.encode(identity))}',
      'mode': 'online',
      'server_url': server,
      'shop_id': shopId,
      'shop_name': shopName.isEmpty ? '已保存店铺' : shopName,
      'account_id': accountId,
      'account_name': accountName,
      'token': token,
      'last_entered': DateTime.now().toIso8601String(),
    };
  }

  /// 调用者必须已在线验证登录及审批；目标库可打开后才提交历史和默认项。
  Future<SavedWorkspace> rememberAuthenticatedWorkspace({
    required String serverUrl,
    required String token,
    required String shopId,
    required String shopName,
    String accountId = '',
    String accountName = '',
  }) async {
    await _workspaceSchema();
    final row = _sharedWorkspaceRow(
      serverUrl: serverUrl,
      token: token,
      shopId: shopId,
      shopName: shopName,
      accountId: accountId,
      accountName: accountName,
    );
    await _preflightWorkspace(row);
    return _settings.transaction((txn) async {
      await txn.insert('workspace_profiles', row,
          conflictAlgorithm: ConflictAlgorithm.replace);
      await _selectWorkspace(txn, row);
      return _publicWorkspace(row);
    });
  }
}
