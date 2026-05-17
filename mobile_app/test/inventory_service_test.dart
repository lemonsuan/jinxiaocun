import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/application/inventory_service.dart';
import 'package:inventory_mobile_app/src/domain/models.dart';

void main() {
  test('inbound increases stock and duplicate tracking is rejected', () {
    final inventory = InventoryService();
    final items = [
      const InboundDraftItem(
        productCode: 'E4167300',
        productName: '卡诗山茶花经典香氛护发油 30ml',
        quantity: 5,
      ),
    ];

    inventory.confirmInbound(trackingNumber: 'SF123', items: items);

    expect(inventory.stockTotals.single.quantity, 5);
    expect(
      () => inventory.confirmInbound(trackingNumber: 'SF123', items: items),
      throwsA(isA<InventoryException>()),
    );
  });

  test('outbound cannot make stock negative', () {
    final inventory = InventoryService();
    inventory.confirmInbound(
      trackingNumber: 'SF124',
      items: [
        const InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );

    expect(
      () => inventory.confirmOutbound(
        items: [
          const OutboundItem(
            productCode: 'E4167300',
            productName: '卡诗山茶花经典香氛护发油 30ml',
            quantity: 6,
          ),
        ],
      ),
      throwsA(isA<InventoryException>()),
    );
  });

  test('outbound order stores multiple items and photo attachments', () {
    final inventory = InventoryService();
    inventory.confirmInbound(
      trackingNumber: 'SF12401',
      items: const [
        InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
        InboundDraftItem(
          productCode: 'E4182400',
          productName: '卡诗雪绒花香氛护发油 30ml',
          quantity: 3,
        ),
      ],
    );

    final order = inventory.confirmOutbound(
      items: const [
        OutboundItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 2,
        ),
        OutboundItem(
          productCode: 'E4182400',
          productName: '卡诗雪绒花香氛护发油 30ml',
          quantity: 1,
        ),
      ],
      imagePaths: const [
        '/local/outbound_images/front.jpg',
        '/local/outbound_images/side.jpg',
      ],
      logisticsNumber: 'SF987654321',
    );

    expect(order.items, hasLength(2));
    expect(order.imagePaths, hasLength(2));
    expect(order.logisticsNumber, 'SF987654321');
    expect(inventory.outboundHistory.single.imagePaths, order.imagePaths);
    expect(inventory.outboundHistory.single.logisticsNumber, 'SF987654321');
    expect(
      inventory.stockTotals.map((stock) => stock.quantity),
      containsAll([3, 2]),
    );
  });

  test('settlement marker does not change stock', () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF125',
      isSettled: false,
      items: [
        const InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );

    inventory.setReceiptSettled(receipt.id, true);

    expect(inventory.inboundHistory.single.isSettled, isTrue);
    expect(inventory.stockTotals.single.quantity, 5);
  });

  test('receipt image path survives inbound and settlement updates', () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF12501',
      sellerOrderNumber: 'TSHL2020051400036246',
      rebateOrderNumber: 'FL20260518001',
      imagePath: '/local/inbound_images/list.jpg',
      items: [
        const InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );

    inventory.setReceiptSettled(receipt.id, true);

    expect(inventory.inboundHistory.single.imagePath, receipt.imagePath);
    expect(inventory.inboundHistory.single.imagePath, isNotEmpty);
    expect(
      inventory.inboundHistory.single.sellerOrderNumber,
      'TSHL2020051400036246',
    );
    expect(inventory.inboundHistory.single.rebateOrderNumber, 'FL20260518001');
  });

  test('deleting inbound receipt removes receipt and rolls back stock', () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF12502',
      items: [
        const InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );

    inventory.deleteInboundReceipt(receipt.id);

    expect(inventory.inboundHistory, isEmpty);
    expect(inventory.stockTotals.single.quantity, 0);
    expect(inventory.ledger, isEmpty);
  });

  test('deleting inbound receipt is blocked after stock ships', () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF12503',
      items: [
        const InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );
    inventory.confirmOutbound(
      items: [
        const OutboundItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 1,
        ),
      ],
    );

    expect(
      () => inventory.deleteInboundReceipt(receipt.id),
      throwsA(isA<InventoryException>()),
    );
    expect(inventory.inboundHistory.single.id, receipt.id);
    expect(inventory.stockTotals.single.quantity, 4);
  });

  test('editing inbound receipt quantity increases stock through ledger', () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF12504',
      items: const [
        InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );

    inventory.updateInboundReceiptItems(
      receipt.id,
      [receipt.items.single.copyWith(quantity: 8)],
    );

    expect(inventory.inboundHistory.single.items.single.quantity, 8);
    expect(inventory.stockTotals.single.quantity, 8);
    expect(inventory.ledger.map((entry) => entry.delta), [5, 3]);
  });

  test('editing inbound receipt quantity decreases stock through ledger', () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF12505',
      items: const [
        InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );

    inventory.updateInboundReceiptItems(
      receipt.id,
      [receipt.items.single.copyWith(quantity: 3)],
    );

    expect(inventory.inboundHistory.single.items.single.quantity, 3);
    expect(inventory.stockTotals.single.quantity, 3);
    expect(inventory.ledger.map((entry) => entry.delta), [5, -2]);
  });

  test(
      'editing inbound receipt is blocked when shipped stock would go negative',
      () {
    final inventory = InventoryService();
    final receipt = inventory.confirmInbound(
      trackingNumber: 'SF12506',
      items: const [
        InboundDraftItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 5,
        ),
      ],
    );
    inventory.confirmOutbound(
      items: const [
        OutboundItem(
          productCode: 'E4167300',
          productName: '卡诗山茶花经典香氛护发油 30ml',
          quantity: 3,
        ),
      ],
    );

    expect(
      () => inventory.updateInboundReceiptItems(
        receipt.id,
        [receipt.items.single.copyWith(quantity: 1)],
      ),
      throwsA(isA<InventoryException>()),
    );
    expect(inventory.inboundHistory.single.items.single.quantity, 5);
    expect(inventory.stockTotals.single.quantity, 2);
  });

  test('SF tracking can be received before product rows are recognized', () {
    final inventory = InventoryService();

    final receipt =
        inventory.confirmInbound(trackingNumber: 'SF126', items: const []);

    expect(receipt.items, isEmpty);
    expect(inventory.inboundHistory.single.trackingNumber, 'SF126');
    expect(inventory.stockTotals, isEmpty);
    expect(
      () => inventory.confirmInbound(trackingNumber: 'SF126', items: const []),
      throwsA(isA<InventoryException>()),
    );
  });

  test('empty inbound items still require an SF-style tracking number', () {
    final inventory = InventoryService();

    expect(
      () => inventory.confirmInbound(trackingNumber: 'YT123', items: const []),
      throwsA(isA<InventoryException>()),
    );
  });
}
