import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:inventory_mobile_app/src/data/local_database_schema.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/application/express_processing_queue.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  final opened = <LocalInventoryDatabase>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('shop-sync-');
  });
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    await root.delete(recursive: true);
  });
  Future<LocalInventoryDatabase> open(String phone) async {
    final db = LocalInventoryDatabase(
        directory: Directory('${root.path}/$phone'),
        factory: databaseFactoryFfi);
    await db.open();
    opened.add(db);
    return db;
  }

  Future<LocalInventoryDatabase> online(String phone,
      {String shop = 'shop1', String server = 'https://example.test'}) async {
    final setup = await open(phone);
    await setup.saveAuthMode('online');
    await setup.saveSyncServerUrl(server);
    await setup.saveAuthToken('token');
    await setup.saveActiveShopId(shop);
    return open(phone);
  }

  Future<InboundReceipt> inbound(LocalInventoryDatabase db, String number,
          {int qty = 10}) =>
      db.confirmInbound(trackingNumber: number, items: [
        InboundDraftItem(productCode: 'SKU', productName: '商品', quantity: qty)
      ]);
  Map<String, Object?> wire(Map candidate) {
    final data = Map<String, Object?>.from(candidate['data'] as Map);
    data.remove('image_path');
    data.remove('image_paths');
    return data;
  }

  Map<String, Object?> record(String kind, String id, int rev, Map data) =>
      {'kind': kind, 'id': id, 'revision': rev, 'data': data};
  Map<String, Object?> stock(int rev, int qty) => record('stock', 'SKU', rev,
      {'product_code': 'SKU', 'product_name': '商品', 'quantity': qty});
  Future<List<Map<String, Object?>>> publish(LocalInventoryDatabase db,
      {int start = 1}) async {
    final records = <Map<String, Object?>>[];
    for (final candidate in await db.pendingSyncRecords()) {
      final data = wire(candidate);
      final op = await db.freezeSyncOperation(candidate, data);
      records.add(record(
          candidate['kind'] as String, candidate['id'] as String, start, data));
      await db.applySyncPushResults([
        {
          'operation_id': op['operation_id'],
          'status': 'applied',
          'revision': start++
        }
      ]);
    }
    return records;
  }

  test(
      'two phones: local hide retains stock, server document and pending evidence; pull never resurrects',
      () async {
    final a = await online('a');
    final b = await online('b');
    final receipt = await inbound(a, 'SF123');
    final changes = await publish(a);
    await a.applySyncPull([stock(3, 10)], 3);
    await b.applySyncPull([...changes, stock(3, 10)], 3);
    expect((await b.loadInboundHistory()).single.trackingNumber, 'SF123');
    await a.deleteInboundReceipt(receipt.id);
    expect(await a.loadInboundHistory(), isEmpty);
    expect((await a.loadStockTotals()).single.quantity, 10);
    expect((await b.loadInboundHistory()).length, 1);
    expect(await a.pendingSyncRecords(), isEmpty);
    await a.applySyncPull([...changes, stock(3, 10)], 3);
    expect(await a.loadInboundHistory(), isEmpty);
    final restarted = await open('a');
    expect(await restarted.loadInboundHistory(), isEmpty);
    await restarted.restoreLocallyHiddenRecords();
    expect((await restarted.loadInboundHistory()).length, 1);
    final unuploaded = await inbound(a, 'SFUNUPLOADED', qty: 2);
    await a.deleteInboundReceipt(unuploaded.id);
    expect(
        (await a.pendingSyncRecords()).where((r) => r['id'] == unuploaded.id),
        hasLength(1));
  });

  test(
      'frozen outbox survives restart and old acknowledgement keeps later generation',
      () async {
    final a = await online('a');
    final receipt = await inbound(a, 'SF1');
    final candidate = (await a.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'inbound');
    final frozen = await a.freezeSyncOperation(candidate, wire(candidate));
    await a.setReceiptSettled(receipt.id, true);
    final restarted = await open('a');
    expect((await restarted.pendingSyncOperations()).single, frozen);
    await restarted.applySyncPushResults([
      {
        'operation_id': frozen['operation_id'],
        'status': 'applied',
        'revision': 4
      }
    ]);
    final changed = (await restarted.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'inbound');
    expect(changed['base_revision'], 4);
    expect((changed['data'] as Map)['is_settled'], true);
    expect(changed['generation'], greaterThan(candidate['generation'] as int));
    await restarted.applySyncPushResults([
      {
        'operation_id': frozen['operation_id'],
        'status': 'duplicate',
        'revision': 4
      }
    ]);
    expect(
        (await restarted.pendingSyncRecords())
            .any((r) => r['kind'] == 'inbound'),
        true);
  });

  test(
      'scope isolates server and shop, immutable old job queue and stale context',
      () async {
    final a = await online('a');
    await inbound(a, 'SF1');
    final context = await a.loadSyncContext();
    expect(context!['shop_id'], 'shop1');
    await a.saveActiveShopId('shop2');
    expect(await a.loadSyncContext(), isNull);
    final other = await open('a');
    expect(await other.loadInboundHistory(), isEmpty);
    expect(
        identical(ExpressProcessingQueue.forDatabase(a),
            ExpressProcessingQueue.forDatabase(other)),
        false);
    expect(
        identical(ExpressProcessingQueue.forDatabase(a),
            ExpressProcessingQueue.forDatabase(a)),
        true);
    await other.saveSyncServerUrl('https://different.test');
    final server = await open('a');
    expect(await server.loadInboundHistory(), isEmpty);
    await server.saveSyncServerUrl('https://example.test/');
    await server.saveActiveShopId('shop1');
    final original = await open('a');
    expect(await original.loadInboundHistory(), hasLength(1));
  });

  test(
      'stock projects pending deltas against server snapshots and ledger reconciles only once',
      () async {
    final a = await online('a');
    await a.applySyncPull([stock(1, 10)], 1);
    await a.confirmOutbound(items: [
      const OutboundItem(productCode: 'SKU', productName: '商品', quantity: 3)
    ]);
    await a.applySyncPull([stock(2, 8)], 2);
    expect((await a.loadStockTotals()).single.quantity, 5);
    await a.applySyncPull([stock(2, 8)], 2);
    expect((await a.loadStockTotals()).single.quantity, 5);
    await a.applySyncPull([stock(3, 1)], 3);
    expect((await a.loadStockTotals()).single.quantity, 0);
    expect(await a.syncConflictCount(), 1);
    await expectLater(
        a.confirmOutbound(items: [
          const OutboundItem(productCode: 'SKU', productName: '商品', quantity: 1)
        ]),
        throwsException);
  });

  test(
      'pull conflict preserves local values, blocks retries and explicit server choice archives evidence',
      () async {
    final a = await online('a');
    final receipt = await inbound(a, 'SF1');
    final initial = await publish(a);
    await a.applySyncPull([stock(3, 10)], 3);
    await a.setReceiptSettled(receipt.id, true);
    final remote = Map<String, Object?>.from(
        initial.firstWhere((r) => r['kind'] == 'inbound'));
    remote['revision'] = 4;
    await a.applySyncPull([remote], 4);
    expect((await a.loadInboundHistory()).single.isSettled, true);
    expect((await a.pendingSyncRecords()).where((r) => r['kind'] == 'inbound'),
        isEmpty);
    final conflict = (await a.loadSyncConflicts()).single;
    expect((conflict['local_data'] as Map)['is_settled'], true);
    await a.acceptServerSyncConflict(conflict['operation_id'] as String);
    expect((await a.loadInboundHistory()).single.isSettled, false);
    expect(await a.syncConflictCount(), 0);
    expect(await a.pendingSyncRecords(), isEmpty);
  });

  test('media hydration is guarded, does not dirty and skips hidden records',
      () async {
    final a = await online('a');
    final b = await online('b');
    await inbound(a, 'SF1');
    final changes = await publish(a);
    final remote = changes.firstWhere((r) => r['kind'] == 'inbound');
    final digest = List.filled(64, 'a').join();
    (remote['data'] as Map)['image_sha256'] = digest;
    await b.applySyncPull([...changes, stock(3, 10)], 3);
    final ref = (await b.pendingSyncMediaDownloads()).single;
    expect((await b.loadInboundHistory()).single.imagePath, 'sync://$digest');
    await b.attachSyncMedia(
        {...ref, 'sha256': List.filled(64, 'b').join()}, '/wrong.jpg');
    expect((await b.pendingSyncMediaDownloads()), hasLength(1));
    await b.attachSyncMedia(ref, '/private/photo.jpg');
    expect(
        (await b.loadInboundHistory()).single.imagePath, '/private/photo.jpg');
    expect(await b.pendingSyncRecords(), isEmpty);
    expect(await b.pendingSyncMediaDownloads(), isEmpty);
    await b.deleteInboundReceipt(remote['id'] as String);
    await b.applySyncPull(
        [record('inbound', remote['id'] as String, 4, remote['data'] as Map)],
        4);
    expect(await b.loadInboundHistory(), isEmpty);
    expect(await b.pendingSyncMediaDownloads(), isEmpty);
  });

  test(
      'legacy original retained, migrates only recorded scope; backup excludes credentials and state',
      () async {
    final dir = Directory('${root.path}/legacy');
    await dir.create();
    final raw =
        await databaseFactoryFfi.openDatabase('${dir.path}/inventory_app.db',
            options: OpenDatabaseOptions(
                version: 6,
                onCreate: (db, _) async {
                  for (final sql in LocalDatabaseSchema.createStatements
                      .where((sql) => !sql.contains('sync_'))) {
                    await db.execute(sql);
                  }
                }));
    final legacy = LocalInventoryDatabase(database: raw);
    await legacy.saveAuthMode('online');
    await legacy.saveSyncServerUrl('https://example.test');
    await legacy.saveAuthToken('secret');
    await legacy.saveActiveShopId('shop1');
    await inbound(legacy, 'SFOLD');
    await legacy.close();
    final migrated = await open('legacy');
    expect(
        (await migrated.loadInboundHistory()).single.trackingNumber, 'SFOLD');
    expect(File('${dir.path}/inventory_app.db').existsSync(), true);
    final context = await migrated.loadSyncContext();
    expect(context!['token'], 'secret');
    await migrated
        .deleteInboundReceipt((await migrated.loadInboundHistory()).single.id);
    final backup = await migrated.exportBackupBytes(includeImages: false);
    final decoded = jsonDecode(utf8.decode(backup)) as Map;
    final settings = (decoded['tables'] as Map)['app_settings'] as List;
    expect(settings, isEmpty);
    expect(
        (decoded['tables'] as Map)
            .keys
            .any((k) => k.toString().startsWith('sync_')),
        false);
    await expectLater(migrated.importBackupBytes(backup), throwsException);
    await migrated.saveActiveShopId('shop2');
    final other = await open('legacy');
    expect(await other.loadInboundHistory(), isEmpty);
    final offline = await open('offline');
    await offline.importBackupBytes(backup);
    expect(await offline.loadInboundHistory(), hasLength(1));
    expect(await offline.loadAuthToken(), '');
    expect(await offline.pendingSyncRecords(), hasLength(2));
  });
  test(
      'lost push acknowledgement plus pull does not invent conflict; later local edits survive',
      () async {
    final a = await online('lost');
    final receipt = await inbound(a, 'SFLOST');
    final candidate = (await a.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'inbound');
    final data = wire(candidate);
    final op = await a.freezeSyncOperation(candidate, data);
    await a.setReceiptSettled(receipt.id, true);
    await a.applySyncPull(
        [stock(1, 10), record('inbound', receipt.id, 2, data)], 2);
    expect(await a.syncConflictCount(), 0);
    expect((await a.pendingSyncOperations()).single['operation_id'],
        op['operation_id']);
    expect((await a.loadInboundHistory()).single.isSettled, true);
    expect((await a.loadStockTotals()).single.quantity, 10);
    await a.applySyncPushResults([
      {'operation_id': op['operation_id'], 'status': 'duplicate', 'revision': 2}
    ]);
    expect(
        (await a.pendingSyncRecords())
            .firstWhere((r) => r['kind'] == 'inbound')['base_revision'],
        2);
  });

  test(
      'online bulk clear hides views without deleting unuploaded photos or changing business quantities',
      () async {
    final a = await online('clear');
    final image = File('${root.path}/unuploaded.jpg');
    await image.writeAsBytes([1, 2, 3]);
    final receipt = await a.confirmInbound(
        trackingNumber: 'SFCLEAR',
        items: [
          const InboundDraftItem(
              productCode: 'SKU', productName: '商品', quantity: 7)
        ],
        imagePath: image.path,
        isSettled: true);
    await a.clearSettledImagesData();
    await a.clearSettledTextData();
    await a.clearStockAndProducts();
    expect(await a.loadInboundHistory(), isEmpty);
    expect(await a.loadStockTotals(), isEmpty);
    expect(await a.loadProductCatalog(), isEmpty);
    expect(image.existsSync(), true);
    final candidate =
        (await a.pendingSyncRecords()).firstWhere((r) => r['id'] == receipt.id);
    expect((candidate['data'] as Map)['image_path'], image.path);
    await a.restoreLocallyHiddenRecords();
    expect((await a.loadStockTotals()).single.quantity, 7);
    expect((await a.loadInboundHistory()).single.imagePath, image.path);
  });

  test(
      'malformed remote batch rolls back documents and cursor, and dirty triggers remain active',
      () async {
    final a = await online('invalid');
    await expectLater(
        a.applySyncPull([stock(1, 5), stock(2, -1)], 2), throwsFormatException);
    expect(await a.loadSyncCursor(), 0);
    expect(await a.loadStockTotals(), isEmpty);
    await inbound(a, 'SFAFTER');
    expect(await a.pendingSyncRecords(), hasLength(2));
  });
  test(
      'rejected frozen generation does not block edited generation; successful retry archives conflict',
      () async {
    final a = await online('retry');
    final receipt = await inbound(a, 'SFRETRY');
    final first = (await a.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'inbound');
    final old = await a.freezeSyncOperation(first, wire(first));
    await a.applySyncPushResults([
      {
        'operation_id': old['operation_id'],
        'status': 'conflict',
        'code': 'invalid_data',
        'message': 'invalid'
      }
    ]);
    expect((await a.pendingSyncRecords()).where((r) => r['kind'] == 'inbound'),
        isEmpty);
    await a.setReceiptSettled(receipt.id, true);
    final edited = (await a.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'inbound');
    final next = await a.freezeSyncOperation(edited, wire(edited));
    expect(next['operation_id'], isNot(old['operation_id']));
    expect((await a.pendingSyncOperations()).single['operation_id'],
        next['operation_id']);
    expect((await a.loadSyncConflicts()).single['can_abandon'], false);
    await a.applySyncPushResults([
      {'operation_id': next['operation_id'], 'status': 'applied', 'revision': 3}
    ]);
    expect(await a.syncConflictCount(), 0);
    expect(await a.pendingSyncOperations(), isEmpty);
  });

  test(
      'explicit abandonment of rejected new outbound retains archive, compensates only local stock and never requeues',
      () async {
    final a = await online('abandon');
    await a.applySyncPull([stock(1, 10)], 1);
    final order = await a.confirmOutbound(items: [
      const OutboundItem(productCode: 'SKU', productName: '商品', quantity: 3)
    ]);
    final candidate = (await a.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'outbound');
    final op = await a.freezeSyncOperation(candidate, wire(candidate));
    await a.applySyncPushResults([
      {
        'operation_id': op['operation_id'],
        'status': 'conflict',
        'code': 'insufficient_stock',
        'message': 'insufficient'
      }
    ]);
    await a.applySyncPull([stock(2, 1)], 2);
    final conflict = (await a.loadSyncConflicts())
        .firstWhere((r) => r['operation_id'] == op['operation_id']);
    expect(conflict['can_abandon'], true);
    await a.abandonUnacceptedSyncConflict(op['operation_id'] as String);
    expect((await a.loadStockTotals()).single.quantity, 1);
    expect(await a.loadOutboundHistory(), isEmpty);
    expect(await a.pendingSyncRecords(), isEmpty);
    expect(await a.syncConflictCount(), 0);
    final restarted = await open('abandon');
    await restarted.restoreLocallyHiddenRecords();
    expect(await restarted.loadOutboundHistory(), isEmpty);
    expect(await restarted.pendingSyncRecords(), isEmpty);
    expect(await restarted.pendingSyncOperations(), isEmpty);
    final dir = Directory('${root.path}/abandon');
    // Verify the retained archive through the same scoped business file.
    final files = dir.listSync().whereType<File>().where((f) =>
        f.path.endsWith('.db') && !f.path.endsWith('inventory_config.db'));
    var retained = false;
    for (final dbFile in files) {
      final raw = await databaseFactoryFfi.openDatabase(dbFile.path,
          options: OpenDatabaseOptions(singleInstance: false));
      final archives = await raw
          .query('sync_abandoned', where: 'id=?', whereArgs: [order.id]);
      retained = retained || archives.isNotEmpty;
      if (archives.isNotEmpty) {
        expect((jsonDecode(archives.single['data'] as String) as Map)['items'],
            hasLength(1));
      }
      await raw.close();
    }
    expect(retained, true);
  });

  test(
      'abandon rejects accepted or unknown operations and dependent inbound rollback',
      () async {
    final a = await online('dependency');
    final receipt = await inbound(a, 'SFDEPEND');
    final candidate = (await a.pendingSyncRecords())
        .firstWhere((r) => r['kind'] == 'inbound');
    final op = await a.freezeSyncOperation(candidate, wire(candidate));
    await expectLater(
        a.abandonUnacceptedSyncConflict(op['operation_id'] as String),
        throwsException);
    await a.applySyncPushResults([
      {
        'operation_id': op['operation_id'],
        'status': 'conflict',
        'code': 'duplicate_tracking',
        'message': 'duplicate'
      }
    ]);
    await a.confirmOutbound(items: [
      const OutboundItem(productCode: 'SKU', productName: '商品', quantity: 3)
    ]);
    await expectLater(
        a.abandonUnacceptedSyncConflict(op['operation_id'] as String),
        throwsException);
    expect((await a.loadInboundHistory()).single.id, receipt.id);
    expect((await a.loadStockTotals()).single.quantity, 7);
    final b = await online('accepted');
    await inbound(b, 'SFACCEPT');
    await publish(b);
    expect(await b.loadSyncConflicts(), isEmpty);
    await expectLater(
        b.abandonUnacceptedSyncConflict('nonexistent'), throwsException);
  });
}
