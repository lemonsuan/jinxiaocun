import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ui/login_page.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw const SocketException('测试禁止访问真实服务器');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const server = 'https://numeric.example.test';
  const originalUuid = '754fe262-c1cb-4a6f-b42f-113999260041';
  late Directory directory;
  late LocalInventoryDatabase database;
  final opened = <LocalInventoryDatabase>[];
  HttpOverrides? previous;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('numeric-login-');
    database = LocalInventoryDatabase(
        directory: directory, factory: databaseFactoryFfi);
    await database.open();
    opened.add(database);
    await database.ensureDefaultWorkspace();
    previous = HttpOverrides.current;
    HttpOverrides.global = _NoNetwork();
  });
  tearDown(() async {
    HttpOverrides.global = previous;
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    await directory.delete(recursive: true);
  });

  http.Response json(Object value) => http.Response(jsonEncode(value), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
  Map<String, Object?> shop({String role = 'ADMIN', bool number = true}) => {
        'shop_id': originalUuid,
        'shop_name': '原来店铺',
        if (number) 'shop_number': '10000',
        'role': role,
        'status': 'APPROVED',
      };
  Future<void> until(WidgetTester tester, Finder finder) async {
    for (var index = 0; index < 100; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tester.pump(const Duration(milliseconds: 20));
      if (finder.evaluate().isNotEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('等待界面超时：$finder');
  }

  Future<void> showLogin(WidgetTester tester, MockClient client) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(client.close);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                            builder: (_) => LoginPage(
                                database: database,
                                client: client,
                                selectionOnly: true,
                                initialServerUrl: server))),
                    child: const Text('打开登录'))))));
    await tester.tap(find.text('打开登录'));
    await until(tester, find.text('登录云同步版'));
    await tester.enterText(find.byType(TextField).at(1), 'manager');
    await tester.enterText(find.byType(TextField).at(2), 'password');
    await tester.ensureVisible(find.text('登录云同步版'));
    await tester.tap(find.text('登录云同步版'));
    await until(tester, find.text('申请成为店铺管理员'));
  }

  Finder numberField() => find.byWidgetPredicate((widget) =>
      widget is TextField && widget.decoration?.hintText == '输入10000起数字店铺ID');

  testWidgets('店铺ID只显示数字，申请加入发送数字字符串且不改原默认', (tester) async {
    await tester.runAsync(() async {
      final original = await database.loadDefaultWorkspace();
      Map<String, dynamic>? submitted;
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          return json({
            'token': 'new-token',
            'username': 'manager',
            'user_id': 'manager-id'
          });
        }
        if (request.url.path == '/api/shops/join') {
          submitted = jsonDecode(request.body) as Map<String, dynamic>;
          return json({'message': '已申请'});
        }
        return json([shop()]);
      });
      await showLogin(tester, client);
      expect(find.text('店铺ID：10000\n角色：管理员'), findsOneWidget);
      expect(find.textContaining(originalUuid), findsNothing);
      await tester.enterText(numberField(), '10001');
      await tester.ensureVisible(find.text('提交管理员申请'));
      await tester.tap(find.text('提交管理员申请'));
      await until(tester, find.text('管理员申请已提交，请联系店铺创建人批准，然后刷新。'));
      expect(submitted, {'shop_number': '10001'});
      expect((await database.loadDefaultWorkspace()).id, original.id);
      expect(await database.loadAuthMode(), 'offline');
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('选择带数字ID的旧店仍用原UUID进入并保留库存和工作区', (tester) async {
    await tester.runAsync(() async {
      final original = await database.rememberAuthenticatedWorkspace(
          serverUrl: server,
          token: 'old-token',
          shopId: originalUuid,
          shopName: '原来店铺',
          accountId: 'manager-id',
          accountName: 'manager');
      final oldWorkspace = LocalInventoryDatabase(
          directory: directory, factory: databaseFactoryFfi);
      await oldWorkspace.open();
      opened.add(oldWorkspace);
      await oldWorkspace
          .confirmInbound(trackingNumber: 'OLD-001', items: const [
        InboundDraftItem(productCode: 'SKU', productName: '原商品', quantity: 7)
      ]);
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          return json({
            'token': 'renewed-token',
            'username': 'manager',
            'user_id': 'manager-id'
          });
        }
        return json([shop()]);
      });
      await showLogin(tester, client);
      await tester.ensureVisible(find.text('原来店铺'));
      await tester.tap(find.text('原来店铺'));
      await until(tester, find.text('打开登录'));
      final selected = await database.loadDefaultWorkspace();
      expect(selected.id, original.id);
      expect(selected.shopId, originalUuid);
      expect(await database.loadActiveShopId(), originalUuid);
      expect(await database.loadAuthToken(), 'renewed-token');
      expect((await database.loadSavedWorkspaces()).length, 2);
      final reopened = LocalInventoryDatabase(
          directory: directory, factory: databaseFactoryFfi);
      await reopened.open();
      opened.add(reopened);
      expect((await reopened.loadStockTotals()).single.quantity, 7);
      expect((await reopened.loadInboundHistory()).single.trackingNumber,
          'OLD-001');
    });
  });

  testWidgets('旧拍手角色没有库存入口且UUID输入不会发送加入请求', (tester) async {
    await tester.runAsync(() async {
      var joinRequests = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/api/auth/login') {
          return json({
            'token': 'old-global-token',
            'username': 'manager',
            'user_id': 'manager-id'
          });
        }
        if (request.url.path == '/api/shops/join') joinRequests++;
        return json([shop(role: 'WORKER')]);
      });
      await showLogin(tester, client);
      expect(find.text('原来店铺'), findsNothing);
      await tester.enterText(numberField(), originalUuid);
      await tester.ensureVisible(find.text('提交管理员申请'));
      await tester.tap(find.text('提交管理员申请'));
      await until(tester, find.text('请输入店铺创建人提供的10000起数字店铺ID'));
      expect(joinRequests, 0);
      expect(await database.loadAuthMode(), 'offline');
      expect(tester.takeException(), isNull);
    });
  });
}
