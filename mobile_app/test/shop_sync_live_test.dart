import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:inventory_mobile_app/src/application/shop_sync_service.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Run only against a disposable Django database/media directory:
/// flutter test --dart-define=SHOP_SYNC_TEST_URL=http://127.0.0.1:18000
///   test/shop_sync_live_test.dart
/// Each run creates independent accounts/shop and intentionally retains server
/// evidence, matching the application's retention contract.
void main() {
  const configuredUrl = String.fromEnvironment('SHOP_SYNC_TEST_URL');
  final base = configuredUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  sqfliteFfiInit();
  test(
      'live Django: approval, two phones, private evidence, local hide and stock',
      () async {
    final root = await Directory.systemTemp.createTemp('shop-sync-live-');
    final databases = <LocalInventoryDatabase>[];
    final services = <ShopSyncService>[];
    final client = http.Client();
    addTearDown(() async {
      for (final service in services) {
        service.dispose();
      }
      client.close();
      for (final database in databases) {
        await database.close();
      }
      await root.delete(recursive: true);
    });
    Future<http.Response> call(String path,
        {String? token, String? shop, Map<String, Object?>? body}) async {
      final headers = <String, String>{
        if (token != null) 'Authorization': 'Bearer $token',
        if (shop != null) 'X-Active-Shop-ID': shop,
        if (body != null) 'Content-Type': 'application/json',
      };
      return (body == null
              ? client.get(Uri.parse('$base$path'), headers: headers)
              : client.post(Uri.parse('$base$path'),
                  headers: headers, body: jsonEncode(body)))
          .timeout(const Duration(seconds: 15));
    }

    Object? decode(http.Response response) =>
        jsonDecode(utf8.decode(response.bodyBytes));
    Future<Map<String, dynamic>> successful(String path,
        {String? token, String? shop, Map<String, Object?>? body}) async {
      final response = await call(path, token: token, shop: shop, body: body);
      expect(response.statusCode, 200, reason: '$path: ${response.body}');
      return Map<String, dynamic>.from(decode(response) as Map);
    }

    Future<LocalInventoryDatabase> phone(
        String name, String token, String shop) async {
      Future<LocalInventoryDatabase> open() async {
        final db = LocalInventoryDatabase(
            directory: Directory('${root.path}/$name'),
            factory: databaseFactoryFfi);
        await db.open();
        databases.add(db);
        return db;
      }

      final setup = await open();
      await setup.saveAuthMode('online');
      await setup.saveSyncServerUrl(base);
      await setup.saveAuthToken(token);
      await setup.saveActiveShopId(shop);
      return open();
    }

    ShopSyncService syncFor(LocalInventoryDatabase db, String name) {
      final sync = ShopSyncService(db,
          mediaDirectory: () async => Directory('${root.path}/media-$name'));
      services.add(sync);
      return sync;
    }

    Future<void> sync(ShopSyncService service) async {
      await service.sync();
      expect(service.lastSuccess, isNotNull, reason: service.message);
      expect(service.pending, 0, reason: service.message);
      expect(service.conflicts, 0, reason: service.message);
    }

    final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final ownerName = 'live_owner_$suffix';
    final memberName = 'live_member_$suffix';
    final owner = await successful('/api/auth/register',
        body: {'username': ownerName, 'password': 'LiveSync!2026-password'});
    final member = await successful('/api/auth/register',
        body: {'username': memberName, 'password': 'LiveSync!2026-password'});
    final ownerToken = owner['token'] as String;
    final memberToken = member['token'] as String;
    final shop = (await successful('/api/shops/create',
        token: ownerToken,
        body: {'name': 'Live integration $suffix'}))['id'] as String;
    await successful('/api/shops/join',
        token: memberToken, body: {'shop_id': shop});
    final denied =
        await call('/api/view/inbound', token: memberToken, shop: shop);
    expect(denied.statusCode, 403,
        reason: 'Pending members must not read shop records');
    final membersResponse =
        await call('/api/shops/members', token: ownerToken, shop: shop);
    expect(membersResponse.statusCode, 200);
    final members = decode(membersResponse) as List;
    final membership = members
        .cast<Map>()
        .singleWhere((row) => (row['user'] as Map)['username'] == memberName);
    await successful('/api/shops/members/update',
        token: ownerToken,
        shop: shop,
        body: {'membership_id': membership['id'], 'status': 'APPROVED'});

    final a = await phone('a', ownerToken, shop);
    final b = await phone('b', memberToken, shop);
    final syncA = syncFor(a, 'a');
    final syncB = syncFor(b, 'b');
    final photo = await File('test/fixtures/ocr_v6/blank.png')
        .copy('${root.path}/evidence.png');
    final bytes = await photo.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final receipt = await a.confirmInbound(
        trackingNumber: 'SF$suffix',
        imagePath: photo.path,
        items: [
          const InboundDraftItem(
              productCode: 'LIVE-SKU', productName: '真实同步测试商品', quantity: 10)
        ]);
    await sync(syncA);
    await sync(syncB);
    final copied = (await b.loadInboundHistory()).single;
    expect(copied.id, receipt.id);
    expect(copied.trackingNumber, receipt.trackingNumber);
    expect((await b.loadStockTotals()).single.quantity, 10);
    expect(copied.imagePath, isNotNull);
    expect(copied.imagePath, isNot(startsWith('sync://')));
    expect(await File(copied.imagePath!).readAsBytes(), bytes);
    expect(
        sha256.convert(await File(copied.imagePath!).readAsBytes()).toString(),
        digest);
    final media = await call('/api/sync/v2/media/$digest',
        token: memberToken, shop: shop);
    expect(media.statusCode, 200);
    expect(media.bodyBytes, bytes);
    expect((await call('/api/sync/v2/media/$digest')).statusCode, 401);

    await a.deleteInboundReceipt(receipt.id);
    await sync(syncA);
    await sync(syncB);
    expect(await a.loadInboundHistory(), isEmpty);
    expect(await b.loadInboundHistory(), hasLength(1));
    expect((await a.loadStockTotals()).single.quantity, 10);
    final retained =
        await successful('/api/view/inbound', token: ownerToken, shop: shop);
    expect(retained['total'], 1);
    expect(((retained['items'] as List).single as Map)['id'], receipt.id);
    final detail = await successful(
        '/api/view/inbound/${Uri.encodeComponent(receipt.id)}',
        token: ownerToken,
        shop: shop);
    expect((detail['data'] as Map)['image_sha256'], digest);
    expect(
        (await call('/api/sync/v2/media/$digest',
                token: ownerToken, shop: shop))
            .bodyBytes,
        bytes);

    await b.confirmOutbound(items: [
      const OutboundItem(
          productCode: 'LIVE-SKU', productName: '真实同步测试商品', quantity: 3)
    ], logisticsNumber: 'OUT-$suffix');
    await sync(syncB);
    await sync(syncA);
    expect((await a.loadStockTotals()).single.quantity, 7);
    expect((await b.loadStockTotals()).single.quantity, 7);
    expect(await a.loadInboundHistory(), isEmpty);
    expect(await a.loadOutboundHistory(), hasLength(1));
    final stocks =
        await successful('/api/view/stocks', token: ownerToken, shop: shop);
    expect(((stocks['items'] as List).single as Map)['quantity'], 7);
    final readonly = await call('/api/inventory/products',
        token: ownerToken,
        shop: shop,
        body: {'code': 'MUST-NOT-CREATE', 'name': 'blocked'});
    expect(readonly.statusCode, 405, reason: readonly.body);
    final products =
        await successful('/api/view/products', token: ownerToken, shop: shop);
    expect(products['total'], 1);
  },
      skip: base.isEmpty
          ? 'Opt-in: provide SHOP_SYNC_TEST_URL for disposable Django server'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
