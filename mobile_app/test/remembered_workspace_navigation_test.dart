import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/workspace_profile.dart';
import 'package:inventory_mobile_app/src/ui/login_page.dart';
import 'package:inventory_mobile_app/src/ui/workspace_bootstrap_page.dart';
import 'package:inventory_mobile_app/src/ui/workspace_settings_page.dart';

class _NoNetwork extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw const SocketException('测试当前没有网络');
  }
}

/// 模拟已保存工作区的业务连接损坏，配置仍由原测试数据库保留。
class _FailingOpenDatabase extends LocalInventoryDatabase {
  @override
  Future<void> open() async => throw StateError('模拟业务库无法打开');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late LocalInventoryDatabase database;
  late _NoNetwork network;
  HttpOverrides? previousOverrides;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('workspace-navigation-');
    database = LocalInventoryDatabase(
        directory: directory, factory: databaseFactoryFfi);
    await database.open();
    await database.ensureDefaultWorkspace();
    network = _NoNetwork();
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = network;
  });

  tearDown(() async {
    HttpOverrides.global = previousOverrides;
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<SavedWorkspace> saveShop(String id) =>
      database.rememberAuthenticatedWorkspace(
          serverUrl: 'https://$id.example.test',
          token: 'expired-but-retained-token-$id',
          shopId: id,
          shopName: '店铺$id',
          accountId: 'account-$id',
          accountName: '用户$id');

  // 文件数据库在独立线程完成读写，等待可见结果而非假设固定一帧就已完成。
  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail(
        '等待界面结果超时：$finder ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join('|')}');
  }

  Widget host(WidgetBuilder target) => MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context)
                        .push<bool>(MaterialPageRoute(builder: target)),
                    child: const Text('打开设置')),
              )));

  testWidgets('本地默认和曾登录店铺启动均不等待网络或重复登录', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: WorkspaceBootstrapPage(
              database: database,
              homeBuilder: (_) => const Scaffold(body: Text('本地主页')))));
      await until(tester, find.text('本地主页'));
      expect((await database.loadDefaultWorkspace()).isLocal, isTrue);
      expect(network.attempts, 0);

      final shop = await saveShop('A');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(MaterialApp(
          home: WorkspaceBootstrapPage(
              database: database,
              homeBuilder: (_) => const Scaffold(body: Text('店铺缓存主页')))));
      await until(tester, find.text('店铺缓存主页'));
      expect((await database.loadDefaultWorkspace()).id, shop.id);
      expect(await database.loadAuthMode(), 'online');
      expect(await database.loadAuthToken(), 'expired-but-retained-token-A');
      expect(find.byType(LoginPage), findsNothing);
      expect(network.attempts, 0);
    });
  });

  testWidgets('取消设置不改变默认店铺或凭据，也不连接服务器', (tester) async {
    await tester.runAsync(() async {
      final shop = await saveShop('A');
      await tester
          .pumpWidget(host((_) => WorkspaceSettingsPage(database: database)));
      await tester.tap(find.text('打开设置'));
      await until(tester, find.text('店铺A'));
      expect(find.text('当前默认'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('打开设置'), findsOneWidget);
      expect((await database.loadDefaultWorkspace()).id, shop.id);
      expect(await database.loadAuthToken(), 'expired-but-retained-token-A');
      expect(network.attempts, 0);
    });
  });

  testWidgets('设置离线选历史店铺及本地后，默认入口持久化且没有请求', (tester) async {
    await tester.runAsync(() async {
      final a = await saveShop('A');
      final b = await saveShop('B');
      await database.activateSavedWorkspace(a.id);
      await tester
          .pumpWidget(host((_) => WorkspaceSettingsPage(database: database)));
      await tester.tap(find.text('打开设置'));
      await until(tester, find.text('店铺B'));
      await tester.tap(find.text('店铺B'));
      await until(tester, find.text('打开设置'));
      expect((await database.loadDefaultWorkspace()).id, b.id);
      expect(await database.loadAuthMode(), 'online');

      await tester.tap(find.text('打开设置'));
      await until(tester, find.text('完全本地 · 不连接服务器'));
      await tester.tap(find.text('完全本地 · 不连接服务器'));
      await until(tester, find.text('打开设置'));
      expect((await database.loadDefaultWorkspace()).isLocal, isTrue);
      expect(await database.loadAuthMode(), 'offline');
      expect(network.attempts, 0);
    });
  });

  testWidgets('在线认证后取消选店不改原服务器、默认项或令牌', (tester) async {
    await tester.runAsync(() async {
      final original = await saveShop('A');
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (request.url.path == '/api/auth/login') {
          return http.Response(
              jsonEncode({
                'token': 'new-server-token',
                'username': 'new-user',
                'user_id': 'new-account',
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        expect(request.url.path, '/api/shops/my-shops');
        return http.Response(
            jsonEncode([
              {
                'shop_id': 'B',
                'shop_name': '待选新店铺',
                'role': 'MEMBER',
                'status': 'APPROVED'
              }
            ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      addTearDown(client.close);
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host((_) => LoginPage(
            database: database,
            client: client,
            selectionOnly: true,
            initialServerUrl: 'https://B.example.test',
          )));
      await tester.tap(find.text('打开设置'));
      await until(tester, find.text('在线登录或添加店铺'));
      await tester.enterText(find.byType(TextField).at(1), 'new-user');
      await tester.enterText(find.byType(TextField).at(2), 'password');
      await tester.ensureVisible(find.text('登录云同步版'));
      await tester.tap(find.text('登录云同步版'));
      await tester.pumpAndSettle();
      expect(requests, 2,
          reason: find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .join('|'));
      await until(tester, find.text('待选新店铺'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect((await database.loadDefaultWorkspace()).id, original.id);
      expect(await database.loadSyncServerUrl(), 'https://A.example.test');
      expect(await database.loadAuthToken(), 'expired-but-retained-token-A');
      expect(network.attempts, 0);
    });
  });
  testWidgets('默认资料损坏时保留原店铺并可从设置显式恢复', (tester) async {
    await tester.runAsync(() async {
      final original = await saveShop('A');
      final config = await databaseFactoryFfi
          .openDatabase('${directory.path}/inventory_config.db');
      await config.update('workspace_profiles', {'token': ''},
          where: 'id=?', whereArgs: [original.id]);
      await tester.pumpWidget(MaterialApp(
          home: WorkspaceBootstrapPage(
        database: database,
        homeBuilder: (_) => const Scaffold(body: Text('恢复后的主页')),
      )));
      await until(tester, find.text('从设置恢复工作区'));
      expect(find.text('恢复后的主页'), findsNothing);
      expect(await database.loadActiveShopId(), 'A');
      await tester.tap(find.text('从设置恢复工作区'));
      await until(tester, find.text('完全本地 · 不连接服务器'));
      await tester.tap(find.text('完全本地 · 不连接服务器'));
      await until(tester, find.text('恢复后的主页'));
      expect((await database.loadDefaultWorkspace()).isLocal, isTrue);
      expect(network.attempts, 0);
    });
  });

  testWidgets('窄屏的长店名、账号和服务器地址不会溢出布局', (tester) async {
    await tester.runAsync(() async {
      await database.rememberAuthenticatedWorkspace(
        serverUrl:
            'https://long.example.test/${List.filled(80, 'path').join('/')}',
        token: 'cached-token',
        shopId: 'long-shop',
        shopName: List.filled(30, '超长店铺名称').join(),
        accountId: 'long-user',
        accountName: List.filled(30, '账号').join(),
      );
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
          MaterialApp(home: WorkspaceSettingsPage(database: database)));
      await until(tester, find.text('当前默认'));
      expect(tester.takeException(), isNull);
      expect(network.attempts, 0);
    });
  });
  for (final approvedAtEntry in [true, false]) {
    testWidgets(
        approvedAtEntry ? '批准选店成功后原子记住默认入口并返回上一层' : '选店前审批撤销不会建立离线入口或改变默认项',
        (tester) async {
      await tester.runAsync(() async {
        final original = await saveShop('A');
        var shopFetches = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/api/auth/login') {
            return http.Response(
                jsonEncode({
                  'token': 'token-B',
                  'username': '用户B',
                  'user_id': 'user-B'
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          shopFetches++;
          return http.Response(
              jsonEncode([
                {
                  'shop_id': 'B',
                  'shop_name': '新的店铺B',
                  'role': 'MEMBER',
                  'status': shopFetches == 1 || approvedAtEntry
                      ? 'APPROVED'
                      : 'PENDING'
                }
              ]),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        });
        addTearDown(client.close);
        tester.view.physicalSize = const Size(1200, 1800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(host((_) => LoginPage(
            database: database,
            client: client,
            selectionOnly: true,
            initialServerUrl: 'https://B.example.test')));
        await tester.tap(find.text('打开设置'));
        await until(tester, find.text('在线登录或添加店铺'));
        await tester.enterText(find.byType(TextField).at(1), '用户B');
        await tester.enterText(find.byType(TextField).at(2), 'password');
        await tester.ensureVisible(find.text('登录云同步版'));
        await tester.tap(find.text('登录云同步版'));
        await until(tester, find.text('新的店铺B'));
        await tester.tap(find.text('新的店铺B'));
        if (approvedAtEntry) {
          await until(tester, find.text('打开设置'));
          final active = await database.loadDefaultWorkspace();
          expect(active.shopId, 'B');
          expect(active.accountId, 'user-B');
          expect(await database.loadAuthToken(), 'token-B');
          expect((await database.loadSavedWorkspaces()).length, 3);
        } else {
          await until(tester, find.text('此店铺尚未审批通过或权限已变更，请联系管理员。'));
          expect((await database.loadDefaultWorkspace()).id, original.id);
          expect(
              await database.loadAuthToken(), 'expired-but-retained-token-A');
          expect((await database.loadSavedWorkspaces()).length, 2);
        }
        expect(shopFetches, 2);
        expect(network.attempts, 0);
      });
    });
  }
  testWidgets('只打开在线登录再取消不初始化网络客户端或改变默认项', (tester) async {
    await tester.runAsync(() async {
      final original = await saveShop('A');
      await tester
          .pumpWidget(host((_) => WorkspaceSettingsPage(database: database)));
      await tester.tap(find.text('打开设置'));
      await until(tester, find.text('在线登录或添加店铺'));
      await tester.ensureVisible(find.text('在线登录或添加店铺'));
      await tester.tap(find.text('在线登录或添加店铺'));
      await until(tester, find.text('登录云同步版'));
      await tester.pageBack();
      await until(tester, find.text('当前默认'));
      expect((await database.loadDefaultWorkspace()).id, original.id);
      expect(await database.loadAuthToken(), 'expired-but-retained-token-A');
      expect(network.attempts, 0);
      expect(tester.takeException(), isNull);
    });
  });
  testWidgets('恢复登录预载失败时显示提示且无未处理异常，原默认和凭据保留', (tester) async {
    await tester.runAsync(() async {
      final original = await saveShop('A');
      await tester.pumpWidget(MaterialApp(
          home: LoginPage(
              database: _FailingOpenDatabase(), selectionOnly: true)));
      await until(tester, find.text('无法读取原工作区配置，可返回设置选择其他已保存工作区，或继续在线登录。'));
      expect(find.text('登录云同步版'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect((await database.loadDefaultWorkspace()).id, original.id);
      expect(await database.loadAuthToken(), 'expired-but-retained-token-A');
      expect(network.attempts, 0);
    });
  });
}
