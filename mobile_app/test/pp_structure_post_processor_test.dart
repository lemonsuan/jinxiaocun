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
}
