import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/express_capture.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:inventory_mobile_app/src/ocr/pp_structure_post_processor.dart';
import 'package:inventory_mobile_app/src/platform/paddle_ocr_channel.dart';
import 'package:inventory_mobile_app/src/ui/express_inbound_page.dart';

class EmptyInventoryDatabase extends LocalInventoryDatabase {
  @override
  Future<ExpressImageJob?> nextExpressImageJob() async => null;
  @override
  Future<List<InboundReceipt>> loadRecentInboundReceipts(int limit) async => [];
}

void main() {
  testWidgets(
      'express back exits route once instead of leaving disposed-camera page',
      (tester) async {
    var refreshes = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(
        paths, (_) async => '/tmp/express_navigation_test');
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => ExpressInboundPage(
                                    database: EmptyInventoryDatabase(),
                                    paddleOcr: PaddleOcrChannel(),
                                    postProcessor: PpStructurePostProcessor(),
                                    ocrRowMergeTolerance: .3,
                                    onRefreshHomeData: () => refreshes++,
                                  ))),
                      child: const Text('打开极速入库')),
                ))));
    await tester.tap(find.text('打开极速入库'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('极速入库'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('极速入库'), findsNothing);
    expect(find.text('打开极速入库'), findsOneWidget);
    expect(refreshes, 1);
    messenger.setMockMethodCallHandler(paths, null);
  });
}
