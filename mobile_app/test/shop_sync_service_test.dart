import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_mobile_app/src/application/shop_sync_service.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  final databases = <LocalInventoryDatabase>[];
  final services = <ShopSyncService>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync-service-');
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    await root.delete(recursive: true);
  });
  Future<LocalInventoryDatabase> open(String phone) async {
    final db = LocalInventoryDatabase(
        directory: Directory('${root.path}/$phone'),
        factory: databaseFactoryFfi);
    await db.open();
    databases.add(db);
    return db;
  }

  Future<LocalInventoryDatabase> online(String phone) async {
    final db = await open(phone);
    await db.saveAuthMode('online');
    await db.saveSyncServerUrl('https://sync.test');
    await db.saveAuthToken('token');
    await db.saveActiveShopId('shop-a');
    return open(phone);
  }

  ShopSyncService service(LocalInventoryDatabase db, MockClient client) {
    final sync = ShopSyncService(db,
        client: client,
        mediaDirectory: () async => Directory('${root.path}/media'));
    services.add(sync);
    return sync;
  }

  Future<InboundReceipt> inbound(LocalInventoryDatabase db, {String? photo}) =>
      db.confirmInbound(
          trackingNumber: 'SF123456',
          imagePath: photo,
          items: const [
            InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: 5)
          ]);
  http.Response json(Object data, [int status = 200]) =>
      http.Response(jsonEncode(data), status,
          headers: {'content-type': 'application/json'});
  http.Response emptyPull() => json(
      {'changes': [], 'cursor': 0, 'has_more': false, 'server_revision': 0});
  List<Map<String, dynamic>> ops(http.Request request) =>
      (jsonDecode(request.body)['operations'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
  http.Response ack(List<Map<String, dynamic>> operations,
          {String status = 'applied'}) =>
      json({
        'results': [
          for (var i = 0; i < operations.length; i++)
            {
              'operation_id': operations[i]['operation_id'],
              'status': status,
              'revision': i + 1
            }
        ],
        'server_revision': operations.length
      });
  List<Map<String, Object?>> remote(String digest) => [
        {
          'kind': 'product',
          'id': 'SKU',
          'revision': 1,
          'data': {'code': 'SKU', 'name': '商品'}
        },
        {
          'kind': 'inbound',
          'id': 'remote-in',
          'revision': 2,
          'data': {
            'tracking_number': 'SFREMOTE',
            'created_at': '2026-10-27T00:00:00Z',
            'ocr_status': 'confirmed',
            'is_settled': false,
            'image_sha256': digest,
            'items': [
              {
                'id': 'line',
                'product_code': 'SKU',
                'product_name': '商品',
                'quantity': 5
              }
            ]
          }
        },
        {
          'kind': 'stock',
          'id': 'SKU',
          'revision': 3,
          'data': {'product_code': 'SKU', 'product_name': '商品', 'quantity': 5}
        },
      ];
  test(
      'lost push response survives offline restart and replays identical operations',
      () async {
    final db = await online('a');
    await inbound(db);
    late List<Map<String, dynamic>> sent;
    final first = service(db, MockClient((request) async {
      sent = ops(request);
      throw const SocketException('response lost after commit');
    }));
    await first.sync();
    expect(first.lastSuccess, isNull);
    final frozen = await db.pendingSyncOperations();
    expect(frozen, hasLength(2));
    first.dispose();
    services.remove(first);
    await db.close();
    databases.remove(db);
    final restarted = await open('a');
    expect(await restarted.pendingSyncOperations(), frozen);
    var pushes = 0;
    final retry = service(restarted, MockClient((request) async {
      if (request.url.path.endsWith('/push')) {
        pushes++;
        expect(ops(request), sent);
        expect(request.headers['authorization'], 'Bearer token');
        expect(request.headers['x-active-shop-id'], 'shop-a');
        return ack(ops(request), status: 'duplicate');
      }
      return emptyPull();
    }));
    await retry.sync();
    expect(pushes, 1);
    expect(retry.lastSuccess, isNotNull);
    expect(await restarted.pendingSyncOperations(), isEmpty);
    expect(await restarted.pendingSyncRecords(), isEmpty);
    expect((await restarted.loadStockTotals()).single.quantity, 5);
    expect(await restarted.loadInboundHistory(), hasLength(1));
  });
  test('401 retains pending operations, credentials and local data', () async {
    final db = await online('a');
    await inbound(db);
    final sync =
        service(db, MockClient((_) async => json({'detail': 'expired'}, 401)));
    await sync.sync();
    expect(sync.lastSuccess, isNull);
    expect(sync.message, contains('登录已过期'));
    expect(await db.pendingSyncOperations(), hasLength(2));
    expect(await db.loadAuthToken(), 'token');
    expect(await db.loadInboundHistory(), hasLength(1));
    expect(await db.loadSyncCursor(), 0);
  });
  test('shop switch rejects late push response and preserves original outbox',
      () async {
    final db = await online('a');
    await inbound(db);
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    late List<Map<String, dynamic>> sent;
    final sync = service(db, MockClient((request) async {
      sent = ops(request);
      requested.complete();
      return response.future;
    }));
    final running = sync.sync();
    await requested.future;
    await db.saveActiveShopId('shop-b');
    final next = await open('a');
    response.complete(ack(sent));
    await running;
    expect(sync.lastSuccess, isNull);
    expect(sync.message, '同步已暂停');
    expect(await db.pendingSyncOperations(), hasLength(2));
    expect(await next.loadInboundHistory(), isEmpty);
    expect(await next.loadSyncCursor(), 0);
  });
  test('malformed pull rolls back preceding valid records and keeps cursor',
      () async {
    final db = await online('a');
    final sync = service(
        db,
        MockClient((_) async => json({
              'changes': [
                {
                  'kind': 'product',
                  'id': 'SKU',
                  'revision': 1,
                  'data': {'code': 'SKU', 'name': 'valid'}
                },
                {
                  'kind': 'stock',
                  'id': 'SKU',
                  'revision': 2,
                  'data': {
                    'product_code': 'SKU',
                    'product_name': 'invalid',
                    'quantity': -1
                  }
                },
              ],
              'cursor': 2,
              'has_more': false,
              'server_revision': 2
            })));
    await sync.sync();
    expect(sync.lastSuccess, isNull);
    expect(await db.loadSyncCursor(), 0);
    expect(await db.loadProductCatalog(), isEmpty);
    expect(await db.loadStockTotals(), isEmpty);
  });
  test(
      'uploads authenticated photo before metadata and replaces private path with hash',
      () async {
    final db = await online('a');
    final photo = File('${root.path}/photo.jpg');
    final bytes = utf8.encode('private evidence');
    await photo.writeAsBytes(bytes);
    final digest = sha256.convert(bytes).toString();
    await inbound(db, photo: photo.path);
    final calls = <String>[];
    final sync = service(db, MockClient((request) async {
      calls.add(request.url.path);
      expect(request.headers['authorization'], 'Bearer token');
      expect(request.headers['x-active-shop-id'], 'shop-a');
      if (request.url.path.endsWith('/exists')) {
        return json({'exists': false}, 404);
      }
      if (request.url.path.endsWith('/media')) {
        expect(
            request.headers['content-type'], startsWith('multipart/form-data'));
        expect(request.body, contains(digest));
        expect(request.body, contains('private evidence'));
        return json({
          'sha256': digest,
          'size': bytes.length,
          'content_type': 'image/jpeg'
        });
      }
      if (request.url.path.endsWith('/push')) {
        final operations = ops(request);
        final data = operations
            .firstWhere((op) => op['kind'] == 'inbound')['data'] as Map;
        expect(data['image_sha256'], digest);
        expect(data.containsKey('image_path'), false);
        return ack(operations);
      }
      return emptyPull();
    }));
    await sync.sync();
    expect(sync.lastSuccess, isNotNull);
    expect(calls.indexOf('/api/sync/v2/media'),
        lessThan(calls.indexOf('/api/sync/v2/push')));
    expect(await db.pendingSyncOperations(), isEmpty);
  });
  test(
      'wrong upload hash keeps receipt dirty without sending unverified metadata',
      () async {
    final db = await online('a');
    final photo = File('${root.path}/photo.jpg');
    await photo.writeAsString('evidence');
    await inbound(db, photo: photo.path);
    var pushedInbound = false;
    var pulled = false;
    final sync = service(db, MockClient((request) async {
      if (request.url.path.endsWith('/exists')) {
        return json({'exists': false}, 404);
      }
      if (request.url.path.endsWith('/media')) {
        return json({'sha256': '0' * 64});
      }
      if (request.url.path.endsWith('/push')) {
        final operations = ops(request);
        pushedInbound = operations.any((row) => row['kind'] == 'inbound');
        return ack(operations);
      }
      pulled = true;
      return emptyPull();
    }));
    await sync.sync();
    expect(sync.lastSuccess, isNull);
    expect(sync.message, contains('图片校验失败'));
    expect(pushedInbound, false);
    expect(pulled, true);
    expect(
        (await db.pendingSyncRecords()).any((row) => row['kind'] == 'inbound'),
        true);
    expect((await db.loadInboundHistory()).single.imagePath, isNotNull);
  });
  test(
      'download verifies SHA before attachment and removes corrupt temporary files',
      () async {
    final bytes = utf8.encode('remote evidence');
    final digest = sha256.convert(bytes).toString();
    for (final corrupt in [true, false]) {
      final db = await online(corrupt ? 'bad' : 'good');
      final sync = service(db, MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer token');
        expect(request.headers['x-active-shop-id'], 'shop-a');
        if (request.url.path.endsWith('/pull')) {
          return json({
            'changes': remote(digest),
            'cursor': 3,
            'has_more': false,
            'server_revision': 3
          });
        }
        expect(request.url.path, '/api/sync/v2/media/$digest');
        return http.Response.bytes(corrupt ? [1, 2, 3] : bytes, 200,
            headers: {'content-type': 'image/jpeg'});
      }));
      await sync.sync();
      final path = (await db.loadInboundHistory()).single.imagePath!;
      if (corrupt) {
        expect(sync.lastSuccess, isNull);
        expect(sync.message, contains('校验失败'));
        expect(path, 'sync://$digest');
        expect(await db.pendingSyncMediaDownloads(), hasLength(1));
        expect(await Directory('${root.path}/media').list().toList(), isEmpty);
      } else {
        expect(sync.lastSuccess, isNotNull);
        expect(await File(path).readAsBytes(), bytes);
        expect(await db.pendingSyncMediaDownloads(), isEmpty);
        expect(await db.pendingSyncRecords(), isEmpty);
      }
    }
  });
  test(
      'localChange drains HTTP, rejects its late pull, then syncs after action',
      () async {
    final db = await online('local-change');
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final events = <String>[];
    var requests = 0;
    var actionRan = false;
    final sync = service(db, MockClient((request) async {
      expect(request.url.path, '/api/sync/v2/pull');
      requests++;
      if (requests == 1) {
        events.add('request-started');
        requested.complete();
        final result = await response.future;
        events.add('request-ended');
        return result;
      }
      expect(actionRan, true);
      events.add('resumed-request');
      return json({
        'changes': [
          {
            'kind': 'product',
            'id': 'FRESH',
            'revision': 2,
            'data': {'code': 'FRESH', 'name': 'Fresh after local action'}
          }
        ],
        'cursor': 2,
        'has_more': false,
        'server_revision': 2,
      });
    }));
    final running = sync.sync();
    await requested.future;
    final change = sync.localChange(() async {
      events.add('action');
      // The completed HTTP response must not have mutated SQLite before action.
      expect(await db.loadSyncCursor(), 0);
      expect(await db.loadProductCatalog(), isEmpty);
      await db.restoreLocallyHiddenRecords();
      actionRan = true;
    });
    expect(actionRan, false);
    expect(events, ['request-started']);
    response.complete(json({
      'changes': [
        {
          'kind': 'product',
          'id': 'STALE',
          'revision': 1,
          'data': {'code': 'STALE', 'name': 'Rejected delayed response'}
        }
      ],
      'cursor': 1,
      'has_more': false,
      'server_revision': 1,
    }));
    await running;
    await change;
    expect(events,
        ['request-started', 'request-ended', 'action', 'resumed-request']);
    expect(requests, 2);
    expect(await db.loadSyncCursor(), 2);
    expect((await db.loadProductCatalog()).map((item) => item.productCode),
        ['FRESH']);
    expect(sync.lastSuccess, isNotNull);
    expect(sync.message, contains('本轮增量已处理'));
    expect(sync.dataVersion, 2); // One local action and one applied fresh pull.
  });

  test('localChange failure releases pause and later sync can complete',
      () async {
    final db = await online('failed-local-change');
    var requests = 0;
    final sync = service(db, MockClient((_) async {
      requests++;
      return emptyPull();
    }));
    await expectLater(
      sync.localChange(() async => throw StateError('user action failed')),
      throwsStateError,
    );
    expect(requests, 0);
    expect(sync.dataVersion, 0);
    await sync.sync();
    expect(requests, 1);
    expect(sync.lastSuccess, isNotNull);
    expect(sync.syncing, false);
    expect(sync.message, contains('本轮增量已处理'));
  });
  for (final failure in ['missing-photo', 'invalid-upload-400']) {
    test(
        '$failure retains bad document while later healthy document pushes and pulls',
        () async {
      final db = await online(failure);
      final photo = File('${root.path}/$failure.jpg');
      await photo.writeAsString('invalid or subsequently missing evidence');
      final bad = await inbound(db, photo: photo.path);
      if (failure == 'missing-photo') await photo.delete();
      final good =
          await db.confirmInbound(trackingNumber: 'SF-GOOD', items: const [
        InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: 5),
      ]);
      final sent = <Map<String, dynamic>>[];
      var pulled = false;
      var uploadAttempts = 0;
      final sync = service(db, MockClient((request) async {
        if (request.url.path.endsWith('/exists')) {
          return json({'exists': false}, 404);
        }
        if (request.url.path.endsWith('/media')) {
          uploadAttempts++;
          return json({'detail': 'Invalid image'}, 400);
        }
        if (request.url.path.endsWith('/push')) {
          final operations = ops(request);
          sent.addAll(operations);
          return ack(operations);
        }
        expect(request.url.path, '/api/sync/v2/pull');
        pulled = true;
        return json({
          'changes': [
            {
              'kind': 'product',
              'id': 'REMOTE',
              'revision': 10,
              'data': {
                'code': 'REMOTE',
                'name': 'Pulled despite bad local media'
              }
            },
          ],
          'cursor': 10,
          'has_more': false,
          'server_revision': 10
        });
      }));
      await sync.sync();
      expect(
          sent.where((row) => row['kind'] == 'inbound').map((row) => row['id']),
          [good.id]);
      expect(sent.any((row) => row['id'] == bad.id), false);
      expect(uploadAttempts, failure == 'missing-photo' ? 0 : 1);
      expect(pulled, true);
      expect(await db.loadSyncCursor(), 10);
      expect(
          (await db.loadProductCatalog())
              .any((row) => row.productCode == 'REMOTE'),
          true);
      expect(await db.pendingSyncOperations(), isEmpty);
      final pending = await db.pendingSyncRecords();
      expect(pending.map((row) => row['id']), [bad.id]);
      expect((pending.single['data'] as Map)['image_path'], photo.path);
      expect(await db.loadInboundHistory(), hasLength(2));
      expect(sync.lastSuccess, isNull);
      expect(sync.message, contains('1 笔图片待处理'));
      expect(sync.message, contains('其他正常记录已同步'));
    });
  }

  for (final failure in ['offline', '401']) {
    test(
        'media $failure stops the cycle instead of skipping to later documents',
        () async {
      final db = await online('media-$failure');
      final photo = File('${root.path}/media-$failure.jpg');
      await photo.writeAsString('evidence');
      await inbound(db, photo: photo.path);
      await db.confirmInbound(trackingNumber: 'SF-LATER', items: const [
        InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: 5),
      ]);
      var pushed = false;
      var pulled = false;
      final sync = service(db, MockClient((request) async {
        if (request.url.path.endsWith('/exists')) {
          if (failure == 'offline') throw const SocketException('offline');
          return json({'detail': 'expired'}, 401);
        }
        pushed = request.url.path.endsWith('/push');
        pulled = request.url.path.endsWith('/pull');
        return emptyPull();
      }));
      await sync.sync();
      expect(pushed, false);
      expect(pulled, false);
      expect(sync.lastSuccess, isNull);
      expect(sync.message, contains(failure == '401' ? '登录已过期' : 'offline'));
      expect(
          (await db.pendingSyncRecords())
              .where((row) => row['kind'] == 'inbound'),
          hasLength(2));
      expect(await db.loadSyncCursor(), 0);
    });
  }
}
