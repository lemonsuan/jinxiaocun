import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/ocr/pp_structure_post_processor.dart';

void main() {
  test('extracts product rows from PP-Structure table rows', () {
    final processor = PpStructurePostProcessor();

    final items = processor.processRows([
      ['产品编号', '产品名称', '数量'],
      ['E4167300', '卡诗山茶花经典香氛护发油 30ml', '5'],
      ['E4182400', '卡诗雪绒花香氛护发油 30ml', '5'],
      ['温馨提示', '请核对商品', ''],
    ]);

    expect(items, hasLength(2));
    expect(items.first.productCode, 'E4167300');
    expect(items.first.productName, '卡诗山茶花经典香氛护发油 30ml');
    expect(items.first.quantity, 5);
  });

  test('merges continuation rows into previous product name', () {
    final processor = PpStructurePostProcessor();

    final items = processor.processRows([
      ['F863701', '卡诗赋源芯丝系列沁透洗发水', '12'],
      ['', '80ml', ''],
    ]);

    expect(items, hasLength(1));
    expect(items.single.productName, '卡诗赋源芯丝系列沁透洗发水 80ml');
  });

  test('splits single-cell OCR rows into Chinese product drafts', () {
    final processor = PpStructurePostProcessor();

    final items = processor.processRows([
      ['产品编号 产品名称 数量'],
      ['E4167300 卡诗山茶花经典香氛护发油 30ml 5'],
      ['E4182400 卡诗雪绒花香氛护发油 30ml 5'],
    ]);

    expect(items, hasLength(2));
    expect(items.first.productCode, 'E4167300');
    expect(items.first.productName, '卡诗山茶花经典香氛护发油 30ml');
    expect(items.first.quantity, 5);
  });

  test('splits multiple product rows merged into one OCR row', () {
    final processor = PpStructurePostProcessor();

    final items = processor.processRows([
      [
        'E4167300 卡诗山茶花经典香氛护发油 30ml 5 '
            'E4182400 卡诗雪绒花香氛护发油 30ml 3',
      ],
    ]);

    expect(items, hasLength(2));
    expect(items.first.productCode, 'E4167300');
    expect(items.first.quantity, 5);
    expect(items.last.productCode, 'E4182400');
    expect(items.last.quantity, 3);
  });

  test('keeps code-prefixed lines as separate products with default quantity',
      () {
    final processor = PpStructurePostProcessor();

    final items = processor.processPlainText('''
KERASTASE
PARIS
订购清单
订单号：TSHL2020051400036246 卡诗天猫官方旗舰店
产品编号 产品名称 数量
E4167300 卡诗山茶花经典香氛护发油30m 5
E4182400 卡诗雪绒花香氛护发油30m 5
F8633900 卡诗照钻系列洗发水80ml 2
F8633701 卡诗赋源芯丝系列沁透洗发水80ml 12
F8634102 卡诗白金赋活洗发水80ml 20
F8634202 卡诗双重功效洗发水80ml
F8634001 卡诗赋源芯丝系列沁养洗发水80m 15
UCN03720 卡诗活动专用礼盒7
温家提示，消规立良好时需意识，远离电信网络诉骗降耕！
''');

    expect(items, hasLength(8));
    expect(items[4].productCode, 'F8634102');
    expect(items[4].productName, '卡诗白金赋活洗发水80ml');
    expect(items[4].quantity, 20);
    expect(items[5].productCode, 'F8634202');
    expect(items[5].productName, '卡诗双重功效洗发水80ml');
    expect(items[5].quantity, 1);
    expect(items[7].productCode, 'UCN03720');
    expect(items[7].productName, '卡诗活动专用礼盒7');
    expect(items[7].quantity, 1);
  });

  test('extracts seller order number from OCR text', () {
    final processor = PpStructurePostProcessor();

    expect(
      processor.extractSellerOrderNumber(
        '订单号：TSHL2020051400036246 卡诗天猫官方旗舰店',
      ),
      'TSHL2020051400036246',
    );
  });
}
