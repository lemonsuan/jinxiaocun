import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  final databases = <LocalInventoryDatabase>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zip-roundtrip-');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(paths, null);
    for (final database in databases) {
      await database.close();
    }
    databases.clear();
    await root.delete(recursive: true);
  });

  Future<LocalInventoryDatabase> open(String name) async {
    final directory = Directory('${root.path}/$name');
    await directory.create();
    final database = LocalInventoryDatabase(
        directory: directory, factory: databaseFactoryFfi);
    await database.open();
    databases.add(database);
    return database;
  }

  test('ZIP导出完成即可读取全部照片，恢复到独立设备保留单据及库存', () async {
    final source = await open('source');
    final imageA = await File('${root.path}/a.jpg').writeAsBytes([1, 2, 3, 4]);
    final imageB = await File('${root.path}/b.jpg').writeAsBytes([9, 8, 7]);
    for (final (tracking, image, quantity) in [
      ('ZIP-001', imageA, 3),
      ('ZIP-002', imageB, 2),
    ]) {
      await source.confirmInbound(
          trackingNumber: tracking,
          imagePath: image.path,
          items: [
            InboundDraftItem(
                productCode: 'SKU-ZIP', productName: '备份商品', quantity: quantity)
          ]);
    }
    final zip = File('${root.path}/inventory.zip');
    await source.exportBackupZipFile(zip);
    final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    expect(archive.files.map((file) => file.name),
        containsAll(['backup_data.json', 'images/a.jpg', 'images/b.jpg']));
    expect(archive.findFile('images/a.jpg')!.content, [1, 2, 3, 4]);
    expect(archive.findFile('images/b.jpg')!.content, [9, 8, 7]);

    final target = await open('target');
    await target.importBackupFromFile(zip);
    final receipts = await target.loadInboundHistory();
    expect(receipts.map((receipt) => receipt.trackingNumber),
        unorderedEquals(['ZIP-001', 'ZIP-002']));
    expect((await target.loadStockTotals()).single.quantity, 5);
    for (final receipt in receipts) {
      final bytes = await File(receipt.imagePath!).readAsBytes();
      expect(bytes,
          receipt.trackingNumber == 'ZIP-001' ? [1, 2, 3, 4] : [9, 8, 7]);
      expect(receipt.imagePath, startsWith('${root.path}/target/'));
    }
  });

  test('文件头识别的改名ZIP和大写ZIP均可恢复照片及库存', () async {
    final source = await open('renamed-source');
    final photo =
        await File('${root.path}/renamed.jpg').writeAsBytes([3, 5, 8]);
    await source.confirmInbound(
        trackingNumber: 'RENAMED-ZIP-001',
        imagePath: photo.path,
        items: const [
          InboundDraftItem(
              productCode: 'RENAMED', productName: '改名备份商品', quantity: 4)
        ]);
    final original = File('${root.path}/original.zip');
    await source.exportBackupZipFile(original);
    for (final (index, extension) in ['bin', 'ZIP'].indexed) {
      final renamed = await original.copy('${root.path}/backup.$extension');
      final target = await open('renamed-target-$index');
      await target.importBackupFromFile(renamed);
      final receipt = (await target.loadInboundHistory()).single;
      expect(receipt.trackingNumber, 'RENAMED-ZIP-001');
      expect(await File(receipt.imagePath!).readAsBytes(), [3, 5, 8]);
      expect((await target.loadStockTotals()).single.quantity, 4);
    }
  });

  test('损坏ZIP的异步解码错误归属恢复请求，原单据和库存不被清空', () async {
    final database = await open('existing');
    await database.confirmInbound(trackingNumber: 'KEEP-001', items: const [
      InboundDraftItem(productCode: 'KEEP', productName: '原商品', quantity: 7)
    ]);
    final corrupt =
        await File('${root.path}/corrupt.zip').writeAsBytes([0, 1, 2, 3]);
    await expectLater(
        database.importBackupFromFile(corrupt), throwsA(anything));
    expect((await database.loadInboundHistory()).single.trackingNumber,
        'KEEP-001');
    expect((await database.loadStockTotals()).single.quantity, 7);
  });
}
