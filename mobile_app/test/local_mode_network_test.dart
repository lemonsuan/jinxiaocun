import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inventory_mobile_app/src/application/shop_sync_service.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ocr/ai_inbound_extractor.dart';
import 'package:inventory_mobile_app/src/ui/ai_rebuild_warehouse_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  final opened = <LocalInventoryDatabase>[];
  final clients = <http.Client>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('local-network-');
  });
  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    for (final database in opened) {
      await database.close();
    }
    opened.clear();
    await root.delete(recursive: true);
  });

  Future<LocalInventoryDatabase> open() async {
    final database =
        LocalInventoryDatabase(directory: root, factory: databaseFactoryFfi);
    await database.open();
    opened.add(database);
    return database;
  }

  Future<void> configure(LocalInventoryDatabase database) async {
    await database.saveGeminiApiKey('valid-test-key');
    await database.saveGeminiApiUrl('https://ai.example.test');
    await database.saveGeminiModel('test-model');
    await database.saveAiApiFormat('openai');
    await database.saveSelfHostedOcrUrl('https://ocr.example.test/read');
  }

  Future<LocalInventoryDatabase> online({String shop = 'shop-a'}) async {
    final setup = await open();
    await setup.saveAuthMode('online');
    await setup.saveSyncServerUrl('https://shop.example.test');
    await setup.saveAuthToken('test-token');
    await setup.saveActiveShopId(shop);
    await configure(setup);
    return open();
  }

  MockClient client(Future<http.Response> Function(http.Request) handler) {
    final value = MockClient(handler);
    clients.add(value);
    return value;
  }

  Future<int> ledgerRows(LocalInventoryDatabase database) async {
    final backup = jsonDecode(
            utf8.decode(await database.exportBackupBytes(includeImages: false)))
        as Map;
    return ((backup['tables'] as Map)['stock_ledger'] as List).length;
  }

  http.Response result() => http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'items': [
                  {'product_code': 'SKU', 'product_name': '商品', 'quantity': 2}
                ]
              })
            }
          }
        ]
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'});

  test('完整配置的纯本地模式拒绝文本AI和自建OCR，HTTP调用为零', () async {
    final database = await open();
    await database.saveAuthMode('offline');
    await configure(database);
    await database.saveOcrMode('self_hosted');
    var requests = 0;
    final transport = client((_) async {
      requests++;
      return result();
    });
    final extractor = AiInboundExtractor(database, client: transport);
    await expectLater(
        extractor.extract('SKU 商品 2'), throwsA(isA<RemoteAiUnavailable>()));
    // 图片不存在时也先按本地策略拒绝，不能尝试远程OCR或本机桥接。
    await expectLater(extractor.extractFromImage('${root.path}/unused.png'),
        throwsA(isA<RemoteAiUnavailable>()));
    final sync = ShopSyncService(database, client: transport);
    await sync.sync();
    sync.dispose();
    expect(requests, 0);
  });

  test('原本地实例在全局切换在线后仍拒绝请求，新店铺实例可正常请求', () async {
    final local = await open();
    await configure(local);
    final shared = await online();
    var requests = 0;
    final transport = client((request) async {
      requests++;
      expect(request.url.toString(),
          'https://ai.example.test/v1/chat/completions');
      return result();
    });
    await expectLater(
        AiInboundExtractor(local, client: transport).extract('旧本地数据'),
        throwsA(isA<RemoteAiUnavailable>()));
    final extracted =
        await AiInboundExtractor(shared, client: transport).extract('SKU 商品 2');
    expect(extracted.items.single.quantity, 2);
    expect(requests, 1);
  });

  test('旧共享店铺在选择另一店铺后不能发起AI', () async {
    final database = await online();
    await database.saveActiveShopId('shop-b');
    var requests = 0;
    final transport = client((_) async {
      requests++;
      return result();
    });
    await expectLater(
        AiInboundExtractor(database, client: transport).extract('A店数据'),
        throwsA(isA<RemoteAiUnavailable>()));
    expect(requests, 0);
  });

  test('共享A切到B后拒绝迟到AI结果，原令牌和数据不被清除', () async {
    final database = await online();
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final transport = client((_) async {
      requested.complete();
      return response.future;
    });
    final pending =
        AiInboundExtractor(database, client: transport).extract('A店单据');
    final assertion = expectLater(pending, throwsA(isA<RemoteAiUnavailable>()));
    await requested.future;
    await database.saveActiveShopId('shop-b');
    response.complete(result());
    await assertion;
    expect(await database.loadAuthToken(), 'test-token');
    expect(await database.loadActiveShopId(), 'shop-b');
  });

  test('自建OCR在切店后结束时不再发送旧单据到AI', () async {
    final database = await online();
    await database.saveOcrMode('self_hosted');
    final photo = File('${root.path}/photo.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    var requests = 0;
    final transport = client((request) async {
      requests++;
      expect(request.url.host, 'ocr.example.test');
      requested.complete();
      return response.future;
    });
    final pending = AiInboundExtractor(database, client: transport)
        .extractFromImage(photo.path);
    final assertion = expectLater(pending, throwsA(isA<RemoteAiUnavailable>()));
    await requested.future;
    await database.saveActiveShopId('shop-b');
    response.complete(http.Response(jsonEncode({'text': 'SKU 商品 2'}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await assertion;
    expect(requests, 1);
  });

  for (final pureLocal in [true, false]) {
    testWidgets(pureLocal ? '纯本地库房重整禁用，原明细和库存保留' : '共享库房远程分析失败，原明细和库存保留',
        (tester) async {
      late LocalInventoryDatabase database;
      late _PageDatabase pageDatabase;
      late File photo;
      late int ledgerCount;
      var requests = 0;
      await tester.runAsync(() async {
        database = pureLocal ? await open() : await online();
        await configure(database);
        await database.saveOcrMode('self_hosted');
        photo = File('${root.path}/evidence.png');
        await photo.writeAsBytes(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aMFAAAAAASUVORK5CYII='));
        await database.confirmInbound(
            trackingNumber: 'SF-PRESERVE',
            imagePath: photo.path,
            items: const [
              InboundDraftItem(
                  productCode: 'SKU', productName: '原商品', quantity: 5)
            ]);
        ledgerCount = await ledgerRows(database);
        pageDatabase = _PageDatabase(root);
        await pageDatabase.open();
        opened.add(pageDatabase);
      });
      final transport = client((_) async {
        requests++;
        return http.Response('unavailable', 503);
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: AiRebuildWarehousePage(
              database: pageDatabase,
              extractor: AiInboundExtractor(database, client: transport)),
        ));
        await pageDatabase.loaded.future;
      });
      await tester.pumpAndSettle();
      if (pureLocal) {
        final button = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '全部分析'));
        expect(button.onPressed, isNull);
        expect(find.textContaining('完全本地模式不连接服务器'), findsOneWidget);
      } else {
        await tester.runAsync(() async {
          // 完成信号在真实异步区创建，避免SQLite线程回包被测试的模拟时钟阻塞。
          pageDatabase.loaded = Completer<void>();
          await tester.tap(find.widgetWithText(OutlinedButton, '重新分析'));
          await pageDatabase.loaded.future;
        });
        await tester.pumpAndSettle();
        expect(find.textContaining('分析失败'), findsOneWidget);
      }
      await tester.runAsync(() async {
        final receipt = (await database.loadInboundHistory()).single;
        expect(receipt.items.single.quantity, 5);
        expect(receipt.items.single.productName, '原商品');
        expect(receipt.ocrStatus, OcrStatus.confirmed);
        expect((await database.loadStockTotals()).single.quantity, 5);
        expect(await ledgerRows(database), ledgerCount);
        expect(await photo.exists(), true);
      });
      expect(requests, pureLocal ? 0 : 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

/// 用真实数据库执行查询，并向界面测试报告异步加载结束。
class _PageDatabase extends LocalInventoryDatabase {
  _PageDatabase(Directory directory)
      : super(directory: directory, factory: databaseFactoryFfi);
  Completer<void> loaded = Completer<void>();
  @override
  Future<List<InboundReceipt>> loadInboundHistory() async {
    final rows = await super.loadInboundHistory();
    if (!loaded.isCompleted) loaded.complete();
    return rows;
  }
}
