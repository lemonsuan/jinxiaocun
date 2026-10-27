part of 'local_inventory_database.dart';

extension _InventoryScope on LocalInventoryDatabase {
  static String _server(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
  Future<void> _openScoped() async {
    final directory = _directory ?? await getApplicationDocumentsDirectory();
    await directory.create(recursive: true);
    final factory = _factory ?? databaseFactory;
    final configPath = path.join(directory.path, 'inventory_config.db');
    _configuration = await factory.openDatabase(configPath,
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) => db.execute(
                'CREATE TABLE app_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at TEXT NOT NULL)')));
    final legacyPath = path.join(directory.path, 'inventory_app.db');
    if (await _setting('scope_initialized') != '1' &&
        await factory.databaseExists(legacyPath)) {
      // Read via SQLite (including its journal), never move or mutate the original.
      final legacy = await factory.openDatabase(legacyPath,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
      try {
        final tables = await legacy.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='app_settings'");
        if (tables.isNotEmpty) {
          for (final row in await legacy.query('app_settings')) {
            if (!(row['key'] as String).startsWith('express_image_job:')) {
              await _settings.insert('app_settings', row,
                  conflictAlgorithm: ConflictAlgorithm.ignore);
            }
          }
        }
        final scope = await _selectedScope();
        await _settings.insert(
            'app_settings',
            {
              'key': 'legacy_scope',
              'value': scope,
              'updated_at': DateTime.now().toIso8601String()
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      } finally {
        await legacy.close();
      }
    }
    await _settings.insert(
        'app_settings',
        {
          'key': 'scope_initialized',
          'value': '1',
          'updated_at': DateTime.now().toIso8601String()
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    // 库文件与共享/本地语义取自同一份快照，切换时也不能混用两套选择。
    final selection = await _authSnapshot();
    _openedScope = _scopeFromSnapshot(selection);
    _openedOnline = selection[LocalInventoryDatabase._authModeKey] == 'online';
    final dbPath = path.join(directory.path,
        'inventory_${sha256.convert(utf8.encode(_openedScope!))}.db');
    final legacyScope = await _setting('legacy_scope');
    if (!await factory.databaseExists(dbPath) &&
        legacyScope == _openedScope &&
        await factory.databaseExists(legacyPath)) {
      // Copy business rows from a read snapshot into a new complete schema.
      // Atomic rename and a retained source also work on older Android SQLite
      // versions which do not support VACUUM INTO.
      final stagingPath = '$dbPath.migrating';
      if (await factory.databaseExists(stagingPath)) {
        await factory.deleteDatabase(stagingPath);
      }
      final legacy = await factory.openDatabase(legacyPath,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false));
      final staging = await factory.openDatabase(stagingPath,
          options: OpenDatabaseOptions(
              version: LocalDatabaseSchema.version,
              onCreate: (db, _) async {
                for (final sql in LocalDatabaseSchema.createStatements) {
                  await db.execute(sql);
                }
              }));
      try {
        await legacy.transaction((source) async {
          final tables = (await source.rawQuery(
                  "SELECT name FROM sqlite_master WHERE type='table'"))
              .map((r) => r['name'])
              .toSet();
          await staging.transaction((target) async {
            for (final table in LocalInventoryDatabase._backupTables) {
              if (!tables.contains(table)) continue;
              for (final row in await source.query(table)) {
                await target.insert(table, row);
              }
            }
          });
        });
      } finally {
        await legacy.close();
        await staging.close();
      }
      await File(stagingPath).rename(dbPath);
    }

    _database = await factory.openDatabase(dbPath, options: _businessOptions());
    await _ensureSync();
  }

  Future<String> _setting(String key) async {
    final rows = await _settings.query('app_settings',
        columns: ['value'], where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? '' : rows.first['value'] as String;
  }

  OpenDatabaseOptions _businessOptions({bool singleInstance = true}) =>
      OpenDatabaseOptions(
        version: LocalDatabaseSchema.version,
        singleInstance: singleInstance,
        onCreate: (db, _) async {
          for (final sql in LocalDatabaseSchema.createStatements) {
            await db.execute(sql);
          }
        },
        onUpgrade: (db, old, current) async {
          for (var version = old + 1; version <= current; version++) {
            for (final sql
                in LocalDatabaseSchema.migrationStatements[version] ??
                    <String>[]) {
              await db.execute(sql);
            }
          }
        },
      );

  Future<Map<String, String>> _authSnapshot() async => {
        for (final row in await _settings
            .query('app_settings', where: 'key IN (?,?,?,?,?,?)', whereArgs: [
          LocalInventoryDatabase._authModeKey,
          LocalInventoryDatabase._syncServerUrlKey,
          LocalInventoryDatabase._authTokenKey,
          LocalInventoryDatabase._activeShopIdKey,
          LocalInventoryDatabase._activeShopNameKey,
          'sync_device_id'
        ]))
          row['key'] as String: row['value'] as String,
      };

  String _scopeFromSnapshot(Map<String, String> config) {
    if (config[LocalInventoryDatabase._authModeKey] != 'online') {
      return 'offline';
    }
    return '${_server(config[LocalInventoryDatabase._syncServerUrlKey] ?? '')}\n${config[LocalInventoryDatabase._activeShopIdKey] ?? ''}';
  }

  Future<String> _selectedScope() async =>
      _scopeFromSnapshot(await _authSnapshot());

  Future<bool> _isOnlineWorkspace() async =>
      _openedScope == null ? await loadAuthMode() == 'online' : _openedOnline;
  Future<void> _guardBackupRestore() async {
    // Restoring over an active shared workspace could erase pending evidence or
    // silently overwrite accepted revisions. Restore into the independent workspace.
    await _ensureSync();
    if (await _isOnlineWorkspace()) {
      throw InventoryException('请切换到离线独立工作区后恢复备份，在线店铺数据和待同步记录会保留。');
    }
  }
}
