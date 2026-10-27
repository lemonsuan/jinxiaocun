import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/application/inventory_service.dart';
import 'package:inventory_mobile_app/src/domain/workspace_profile.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  final opened = <LocalInventoryDatabase>[];
  setUp(() async =>
      root = await Directory.systemTemp.createTemp('remembered-workspace-'));
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    await root.delete(recursive: true);
  });
  Future<LocalInventoryDatabase> open() async {
    final db =
        LocalInventoryDatabase(directory: root, factory: databaseFactoryFfi);
    await db.open();
    opened.add(db);
    return db;
  }

  Future<SavedWorkspace> shared(LocalInventoryDatabase db, String shop,
          {String account = 'user1',
          String token = 'token1',
          String server = 'https://example.test'}) =>
      db.rememberAuthenticatedWorkspace(
          serverUrl: server,
          token: token,
          shopId: shop,
          shopName: '店铺$shop',
          accountId: account,
          accountName: '账户$account');
  Future<void> inbound(LocalInventoryDatabase db, String tracking) async =>
      db.confirmInbound(trackingNumber: tracking, items: [
        const InboundDraftItem(
            productCode: 'SKU', productName: '商品', quantity: 2)
      ]);

  test('首次无网络保存本地默认，重新打开仍为本地且无同步上下文', () async {
    final a = await open();
    expect((await a.ensureDefaultWorkspace()).isLocal, isTrue);
    expect(await a.loadAuthMode(), 'offline');
    expect(await a.loadAuthToken(), isEmpty);
    await inbound(a, 'LOCAL');
    final restarted = await open();
    expect((await restarted.loadDefaultWorkspace()).id, SavedWorkspace.localId);
    expect(
        (await restarted.loadInboundHistory()).single.trackingNumber, 'LOCAL');
    expect(await restarted.loadSyncContext(), isNull);
  });

  test('旧在线选择迁移保留库路径数据和过期令牌，且只登记当前店铺', () async {
    final setup = await open();
    await setup.saveAuthMode('online');
    await setup.saveSyncServerUrl(' https://example.test/// ');
    await setup.saveAuthToken('expired-token');
    await setup.saveActiveShopId('A');
    await setup.saveActiveShopName('以前的店');
    final old = await open();
    await inbound(old, 'OLD-A');
    final profile = await old.ensureDefaultWorkspace();
    expect(profile.isLocal, isFalse);
    expect(profile.serverUrl, 'https://example.test');
    expect(profile.shopName, '以前的店');
    expect(await old.loadAuthToken(), 'expired-token');
    expect(await old.loadSavedWorkspaces(), hasLength(2));
    final restarted = await open();
    expect((await restarted.loadDefaultWorkspace()).id, profile.id);
    expect(
        (await restarted.loadInboundHistory()).single.trackingNumber, 'OLD-A');
  });

  test('历史A B 本地可离线切换并记住默认，业务和队列互不混用', () async {
    final config = await open();
    await config.ensureDefaultWorkspace();
    final a = await shared(config, 'A');
    final dbA = await open();
    await inbound(dbA, 'A-IN');
    final countA = await dbA.pendingSyncCount();
    final b = await shared(config, 'B');
    expect(await dbA.loadSyncContext(), isNull);
    final dbB = await open();
    await inbound(dbB, 'B-IN');
    await config.activateSavedWorkspace(SavedWorkspace.localId);
    final local = await open();
    expect(await local.loadInboundHistory(), isEmpty);
    await inbound(local, 'LOCAL-IN');
    await config.activateSavedWorkspace(a.id);
    final restartedA = await open();
    expect((await restartedA.loadDefaultWorkspace()).id, a.id);
    expect(
        (await restartedA.loadInboundHistory()).single.trackingNumber, 'A-IN');
    expect(await restartedA.pendingSyncCount(), countA);
    final receipt = (await restartedA.loadInboundHistory()).single;
    await restartedA.deleteInboundReceipt(receipt.id);
    expect((await restartedA.loadStockTotals()).single.quantity, 2);
    await config.activateSavedWorkspace(b.id);
    final restartedB = await open();
    expect(
        (await restartedB.loadInboundHistory()).single.trackingNumber, 'B-IN');
    expect(await local.loadSyncContext(), isNull);
  });

  test('只读取设置或尝试未知入口均不改变默认及凭据', () async {
    final db = await open();
    await db.ensureDefaultWorkspace();
    final a = await shared(db, 'A');
    await db.loadSavedWorkspaces();
    await expectLater(db.activateSavedWorkspace('未登录的店铺'),
        throwsA(isA<InventoryException>()));
    expect((await db.loadDefaultWorkspace()).id, a.id);
    expect(await db.loadAuthToken(), 'token1');
    await expectLater(shared(db, 'B', server: 'bad-server'),
        throwsA(isA<InventoryException>()));
    expect((await db.loadDefaultWorkspace()).id, a.id);
    expect(await db.loadSavedWorkspaces(), hasLength(2));
  });

  test('目标库损坏时登记和选择失败均保留旧默认，不能留下新离线入口', () async {
    final db = await open();
    await db.ensureDefaultWorkspace();
    final a = await shared(db, 'A');
    const scope = 'https://example.test\nB';
    final file =
        File('${root.path}/inventory_${sha256.convert(utf8.encode(scope))}.db');
    await file.writeAsString('损坏的SQLite文件', flush: true);
    await expectLater(shared(db, 'B'), throwsA(anything));
    expect((await db.loadDefaultWorkspace()).id, a.id);
    expect(await db.loadSavedWorkspaces(), hasLength(2));
    await file.delete();
    final b = await shared(db, 'B');
    await db.activateSavedWorkspace(a.id);
    await file.writeAsString('再次损坏', flush: true);
    await expectLater(db.activateSavedWorkspace(b.id), throwsA(anything));
    expect((await db.loadDefaultWorkspace()).id, a.id);
    expect(await db.loadAuthToken(), 'token1');
  });

  test('配置提交中断时事务回滚整套选择和新历史资料', () async {
    final db = await open();
    await db.ensureDefaultWorkspace();
    final a = await shared(db, 'A');
    final config = await databaseFactoryFfi.openDatabase(
        '${root.path}/inventory_config.db',
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await config.execute(
          "CREATE TRIGGER fail_workspace BEFORE INSERT ON app_settings WHEN NEW.key='active_shop_id' AND NEW.value='B' BEGIN SELECT RAISE(ABORT,'模拟提交中断'); END");
      await expectLater(shared(db, 'B', token: 'tokenB'), throwsA(anything));
      expect((await db.loadDefaultWorkspace()).id, a.id);
      expect(await db.loadActiveShopId(), 'A');
      expect(await db.loadAuthToken(), 'token1');
      expect(await db.loadSavedWorkspaces(), hasLength(2));
    } finally {
      await config.close();
    }
  });

  test('认证历史和默认入口不进入业务备份，不同账户令牌各自保留', () async {
    final db = await open();
    await db.ensureDefaultWorkspace();
    final a = await shared(db, 'A');
    final other =
        await shared(db, 'A', account: 'other-user', token: 'private-secret');
    expect(other.id, isNot(a.id));
    await db.activateSavedWorkspace(a.id);
    expect(await db.loadAuthToken(), 'token1');
    await db.activateSavedWorkspace(other.id);
    expect(await db.loadAuthToken(), 'private-secret');
    final selected = await open();
    await inbound(selected, 'SAVED');
    final backup =
        utf8.decode(await selected.exportBackupBytes(includeImages: false));
    expect(backup, isNot(contains('private-secret')));
    expect(backup, isNot(contains('workspace_profiles')));
    expect(backup, isNot(contains('default_workspace_id')));
    expect(backup, isNot(contains('workspace_registry_initialized')));
    final rows =
        ((jsonDecode(backup) as Map)['tables'] as Map)['app_settings'] as List;
    expect(rows, isEmpty);
  });

  test('并发切换时旧连接的同步上下文只可能为自身完整快照或空，不会拿到B凭据', () async {
    final config = await open();
    await config.ensureDefaultWorkspace();
    final a = await shared(config, 'A', token: 'tokenA');
    final dbA = await open();
    final b = await shared(config, 'B', token: 'tokenB');
    await config.activateSavedWorkspace(a.id);
    for (var i = 0; i < 12; i++) {
      final results = await Future.wait([
        dbA.loadSyncContext(),
        config.activateSavedWorkspace(i.isEven ? b.id : a.id),
        dbA.loadSyncContext(),
      ]);
      for (final result in [results[0], results[2]]) {
        if (result == null) continue;
        final context = result as Map;
        expect(context['shop_id'], 'A');
        expect(context['token'], 'tokenA');
        expect(context['server_url'], 'https://example.test');
      }
    }
  });

  test('旧共享库在全局切成本地后仍按共享删除语义保留单据和库存', () async {
    final config = await open();
    await config.ensureDefaultWorkspace();
    await shared(config, 'A');
    final oldShared = await open();
    await inbound(oldShared, 'A-KEEP');
    final receipt = (await oldShared.loadInboundHistory()).single;
    await config.activateSavedWorkspace(SavedWorkspace.localId);
    await oldShared.deleteInboundReceipt(receipt.id);
    expect(await oldShared.loadInboundHistory(), isEmpty);
    expect((await oldShared.loadStockTotals()).single.quantity, 2);
    expect(await oldShared.pendingSyncRecords(), isNotEmpty);
    expect(await oldShared.loadSyncContext(), isNull);
  });

  test('默认配置损坏不自动换店，历史列表仍可显式恢复', () async {
    final db = await open();
    await db.ensureDefaultWorkspace();
    final a = await shared(db, 'A');
    await db.saveActiveShopId('错误的店');
    await expectLater(
        db.loadDefaultWorkspace(), throwsA(isA<InventoryException>()));
    expect(await db.loadSavedWorkspaces(), hasLength(2));
    await db.activateSavedWorkspace(a.id);
    expect((await db.loadDefaultWorkspace()).id, a.id);
  });
}
