"""真实店铺数据上的批量查单、汇总、分页与权限回归。"""
import json
from datetime import datetime, timezone

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext

from shops.models import CustomUser, Shop, ShopMembership
from shop_sync_backend.api import generate_token
from .models import InboundItem, InboundReceipt, StockLedger, WarehouseStock


class BatchInboundTests(TestCase):
    def setUp(self):
        self.shop = Shop.objects.create(name='店铺甲')
        self.other_shop = Shop.objects.create(name='店铺乙')
        self.owner = CustomUser.objects.create_user(username='owner', password='safe-password')
        ShopMembership.objects.create(shop=self.shop, user=self.owner, role='CREATOR', status='APPROVED')
        self.headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.owner), 'HTTP_X_ACTIVE_SHOP_ID': str(self.shop.pk)}
        self.first = self.receipt('001A', [('SKU', '商品', 2), ('SKU', '商品', 3), ('', '无编码同名', 1), (' ', '无编码同名', 2)])
        self.second = self.receipt('SF2', [('SKU', '另一名称', 4), ('OTHER', '商品', 5)])
        self.receipt('SF-ARCHIVE', [('SKU', '归档商品', 100)], archived=True)
        self.receipt('ONLY-OTHER', [('SECRET', '别店商品', 999)], shop=self.other_shop)
        self.receipt('001A', [('SECRET', '别店同号商品', 999)], shop=self.other_shop)

    def receipt(self, number, items, shop=None, archived=False):
        shop = shop or self.shop
        receipt = InboundReceipt.objects.create(
            shop=shop, client_key='in-' + number, tracking_number=number,
            created_at=datetime(2026, 10, 28, tzinfo=timezone.utc),
            ocr_status='confirmed', is_deleted=archived, revision=3,
        )
        for index, (code, name, quantity) in enumerate(items):
            InboundItem.objects.create(
                shop=shop, receipt=receipt, client_key=f'line-{number}-{index}',
                product_code=code, product_name=name, quantity=quantity,
            )
        return receipt

    def batch(self, body, headers=None):
        return self.client.post('/api/view/inbound/batch', json.dumps(body), content_type='application/json', **(self.headers if headers is None else headers))

    def test_multiple_numbers_deduplicate_exact_match_and_full_batch_totals(self):
        result = self.batch({'tracking_numbers': ['SF2,001A', '001A；MISSING\nONLY-OTHER']})
        self.assertEqual(result.status_code, 200, result.content)
        result = result.json()
        self.assertEqual(result['tracking_numbers'], ['SF2', '001A', 'MISSING', 'ONLY-OTHER'])
        self.assertEqual(result['duplicate_count'], 1)
        self.assertEqual(result['unmatched_numbers'], ['MISSING', 'ONLY-OTHER'])
        self.assertEqual(result['matched_count'], 2)
        self.assertEqual([row['data']['tracking_number'] for row in result['documents']['items']], ['SF2', '001A'])
        self.assertEqual(result['totals'], {'document_count': 2, 'product_count': 4, 'total_quantity': 17})
        products = result['products']['items']
        sku = next(row for row in products if row['product_code'] == 'SKU')
        self.assertEqual((sku['quantity'], sku['receipt_count']), (9, 2))
        self.assertEqual(sku['tracking_numbers'], ['SF2', '001A'])
        self.assertEqual(sku['name_variants'], ['另一名称', '商品'])
        self.assertEqual(len([row for row in products if row['key'].startswith('line:')]), 2)
        self.assertFalse(any('SECRET' in row['product_code'] for row in products))
        self.assertIsNone(result['documents']['items'][0]['data']['image_sha256'])

    def test_document_and_product_pagination_do_not_change_whole_batch_totals(self):
        body = {'tracking_numbers': ['001A', 'SF2'], 'page_size': 1, 'product_page_size': 1}
        first = self.batch(body).json()
        second = self.batch({**body, 'page': 2, 'product_page': 2}).json()
        self.assertEqual(first['totals'], second['totals'])
        self.assertEqual(first['documents']['total'], 2)
        self.assertEqual(first['products']['total'], 4)
        self.assertEqual(second['documents']['items'][0]['data']['tracking_number'], 'SF2')
        self.assertNotEqual(first['products']['items'][0]['key'], second['products']['items'][0]['key'])
        huge_page = self.batch({**body, 'page': 10 ** 30, 'product_page': 10 ** 30})
        self.assertEqual(huge_page.status_code, 200, huge_page.content)
        self.assertEqual(huge_page.json()['products']['items'], [])
        self.assertEqual(huge_page.json()['documents']['items'], [])
        self.assertEqual(huge_page.json()['totals'], first['totals'])

    def test_archive_option_and_deleted_lines_are_handled_explicitly(self):
        self.assertEqual(self.batch({'tracking_numbers': ['SF-ARCHIVE']}).json()['unmatched_numbers'], ['SF-ARCHIVE'])
        result = self.batch({'tracking_numbers': ['SF-ARCHIVE'], 'include_archived': True}).json()
        self.assertEqual(result['totals']['total_quantity'], 100)
        InboundItem.objects.create(shop=self.shop, receipt=self.first, client_key='deleted-line', product_code='SKU', product_name='不可计入', quantity=1000, is_deleted=True)
        result = self.batch({'tracking_numbers': ['001A']}).json()
        self.assertEqual(result['totals']['total_quantity'], 8)
        self.assertEqual(len(result['documents']['items'][0]['data']['items']), 4)

    def test_invalid_queries_are_bounded_and_empty_query_does_not_return_entire_shop(self):
        for body in ({}, {'tracking_numbers': []}, {'tracking_numbers': [12]}, {'tracking_numbers': ['A'], 'page_size': 21}, {'tracking_numbers': ['A'], 'product_page_size': 101}, {'tracking_numbers': ['A'], 'page': True}, {'tracking_numbers': ['A'], 'include_archived': 'true'}, {'tracking_numbers': ['A'], 'shop_id': str(self.other_shop.pk)}):
            self.assertEqual(self.batch(body).status_code, 422, body)
        for numbers in [[' \n，； '], ['A' * 101], [f'SF{index}' for index in range(201)], ['A ' * 31000]]:
            self.assertEqual(self.batch({'tracking_numbers': numbers}).status_code, 400)
        case = self.batch({'tracking_numbers': ['001a', '01A']}).json()
        self.assertEqual(case['matched_count'], 0)
        self.assertEqual(case['products']['total'], 0)
        self.assertEqual(case['totals']['total_quantity'], 0)

    def test_only_approved_managers_can_query_and_static_route_preserves_details(self):
        self.assertEqual(self.batch({'tracking_numbers': ['001A']}, headers={}).status_code, 401)
        for role, status in [('WORKER', 'APPROVED'), ('MEMBER', 'APPROVED'), ('ADMIN', 'PENDING')]:
            user = CustomUser.objects.create_user(username=role + status, password='safe-password')
            ShopMembership.objects.create(shop=self.shop, user=user, role=role, status=status)
            headers = {**self.headers, 'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(user)}
            self.assertEqual(self.batch({'tracking_numbers': ['001A']}, headers=headers).status_code, 403)
        self.assertEqual(self.client.get('/api/view/inbound/in-001A', **self.headers).status_code, 200)
        self.assertEqual(self.client.get('/api/view/inbound', **self.headers).status_code, 200)
        no_shop = {'HTTP_AUTHORIZATION': self.headers['HTTP_AUTHORIZATION']}
        self.assertEqual(self.batch({'tracking_numbers': ['001A']}, headers=no_shop).status_code, 400)

    def test_batch_is_read_only_and_query_count_does_not_grow_per_receipt(self):
        for index in range(20):
            self.receipt(f'BULK-{index}', [('SAME', '批量商品', 1)])
        numbers = [f'BULK-{index}' for index in range(20)]
        before = (InboundReceipt.objects.count(), InboundItem.objects.count(), StockLedger.objects.count(), WarehouseStock.objects.count())
        with CaptureQueriesContext(connection) as captured:
            result = self.batch({'tracking_numbers': numbers, 'page_size': 20})
        self.assertEqual(result.status_code, 200, result.content)
        self.assertEqual(result.json()['totals'], {'document_count': 20, 'product_count': 1, 'total_quantity': 20})
        # 包括鉴权、店铺锁、汇总与整页预取，不能每单再做一次明细查询。
        selects = [item['sql'] for item in captured if item['sql'].lstrip().upper().startswith('SELECT')]
        self.assertLessEqual(len(selects), 11)
        with CaptureQueriesContext(connection) as one_receipt:
            self.assertEqual(self.batch({'tracking_numbers': numbers[:1]}).status_code, 200)
        one_selects = [item['sql'] for item in one_receipt if item['sql'].lstrip().upper().startswith('SELECT')]
        self.assertEqual(len(selects), len(one_selects))
        self.assertEqual(before, (InboundReceipt.objects.count(), InboundItem.objects.count(), StockLedger.objects.count(), WarehouseStock.objects.count()))
