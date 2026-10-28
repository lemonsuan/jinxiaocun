import hashlib
import io
import json
import tempfile
from datetime import datetime, timezone
from django.test import TestCase, TransactionTestCase, override_settings
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.core.files.uploadedfile import SimpleUploadedFile
from PIL import Image
from shops.models import CustomUser, Shop, ShopMembership
from shop_sync_backend.api import generate_token
from .models import (InboundReceipt, InboundItem, WarehouseStock, StockLedger,
                     SyncChange, SyncOperation, Product, ShopSyncState, PrivateMedia)


class SyncTests(TestCase):
    def setUp(self):
        self.user = CustomUser.objects.create_user(username='alice', password='test')
        self.shop = Shop.objects.create(name='Shop A')
        self.membership = ShopMembership.objects.create(user=self.user, shop=self.shop, role='CREATOR', status='APPROVED')
        self.headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.user), 'HTTP_X_ACTIVE_SHOP_ID': str(self.shop.pk)}
        self.media_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.media_dir.cleanup)
        self.settings_override = override_settings(PRIVATE_MEDIA_ROOT=self.media_dir.name)
        self.settings_override.enable()
        self.addCleanup(self.settings_override.disable)

    def get(self, path, **params):
        return self.client.get('/api/' + path, params, **self.headers)

    def push(self, kind='inbound', key='in-1', base=0, op='op-1', data=None, device='phone-a'):
        operation = dict(operation_id=op, kind=kind, id=key, base_revision=base, data=self.inbound() if data is None else data)
        return self.client.post('/api/sync/v2/push', json.dumps(dict(device_id=device, operations=[operation])), content_type='application/json', **self.headers)

    def inbound(self, qty=10, tracking='SF1', line_id='line-1', code='sku'):
        return dict(tracking_number=tracking, seller_order_number=None, rebate_order_number='rebate', scheme_number=None, created_at='2026-10-27T10:00:00+08:00', ocr_status='confirmed', is_settled=False, image_sha256=None, items=[dict(id=line_id, product_code=code, product_name='Product', quantity=qty, purchase_price=None, sale_price=None)])

    def outbound(self, qty=3):
        return dict(created_at='2026-10-27T11:00:00+08:00', logistics_number=None, note=None, image_sha256s=[], items=[dict(id='out-line', product_code='sku', product_name='Product', quantity=qty)])

    def applied(self, response):
        self.assertEqual(response.status_code, 200, response.content)
        result = response.json()['results'][0]
        self.assertEqual(result['status'], 'applied', result)
        return result

    def test_two_device_incremental_retry_and_no_delete_propagation(self):
        first = self.applied(self.push())
        self.assertEqual(self.push().json()['results'][0]['status'], 'duplicate')
        self.assertEqual(StockLedger.objects.count(), 1)
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)
        first_page = self.get('sync/v2/pull', limit=1).json()
        self.assertTrue(first_page['has_more'])
        second_page = self.get('sync/v2/pull', cursor=first_page['cursor'], limit=1).json()
        self.assertEqual(second_page['changes'][0]['id'], 'in-1')
        self.assertEqual(second_page['cursor'], first['revision'])
        self.assertEqual(self.get('sync/v2/pull', cursor=second_page['cursor']).json()['changes'], [])
        updated = self.inbound(qty=12)
        self.applied(self.push(base=first['revision'], op='phone-b-update', device='phone-b', data=updated))
        self.assertEqual(WarehouseStock.objects.get().quantity, 12)
        self.assertEqual(list(StockLedger.objects.values_list('delta', flat=True)), [10, 2])
        self.assertEqual(self.client.delete('/api/inventory/inbound/' + str(InboundReceipt.objects.get().pk), **self.headers).status_code, 405)
        self.assertEqual(self.get('view/inbound').json()['total'], 1)
        self.assertEqual(InboundReceipt.objects.count(), 1)

    def test_stale_update_and_durable_conflict_retry(self):
        first = self.applied(self.push())
        self.applied(self.push(base=first['revision'], op='new', data=self.inbound(12)))
        response = self.push(base=first['revision'], op='stale', data=self.inbound(9)).json()['results'][0]
        self.assertEqual(response['code'], 'revision_conflict')
        self.assertEqual(response['record']['data']['items'][0]['quantity'], 12)
        self.assertEqual(self.push(base=first['revision'], op='stale', data=self.inbound(9)).json()['results'][0], response)
        self.assertEqual(WarehouseStock.objects.get().quantity, 12)

    def test_reused_operation_id_rejected(self):
        self.applied(self.push())
        response = self.push(data=self.inbound(99)).json()['results'][0]
        self.assertEqual(response['code'], 'operation_id_reused')
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)

    def test_stock_insufficiency_rolls_back_whole_document(self):
        self.applied(self.push())
        result = self.push(kind='outbound', key='out-1', op='out', data=self.outbound(11)).json()['results'][0]
        self.assertEqual(result['code'], 'insufficient_stock')
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)
        self.assertEqual(StockLedger.objects.count(), 1)
        self.assertEqual(self.get('view/outbound').json()['total'], 0)
        self.assertEqual(SyncOperation.objects.count(), 2)

    def test_inbound_reduction_after_outbound_rejected(self):
        first = self.applied(self.push())
        self.applied(self.push(kind='outbound', key='out-1', op='out', data=self.outbound(8)))
        result = self.push(base=first['revision'], op='reduce', data=self.inbound(1)).json()['results'][0]
        self.assertEqual(result['code'], 'insufficient_stock')
        self.assertEqual(InboundItem.objects.get().quantity, 10)
        self.assertEqual(WarehouseStock.objects.get().quantity, 2)

    def test_duplicate_tracking_and_item_reparent_rejected(self):
        self.applied(self.push())
        duplicate = self.push(key='in-2', op='duplicate').json()['results'][0]
        self.assertEqual(duplicate['code'], 'duplicate_tracking')
        reparent = self.push(key='in-2', op='reparent', data=self.inbound(tracking='SF2')).json()['results'][0]
        self.assertEqual(reparent['code'], 'line_parent_mismatch')
        self.assertEqual(InboundReceipt.objects.count(), 1)
        self.assertFalse(InboundItem.objects.get().is_deleted)
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)

    def test_removed_lines_are_archived_with_revision_snapshots(self):
        first = self.applied(self.push())
        data = self.inbound()
        data['items'] = []
        self.applied(self.push(base=first['revision'], op='remove-line', data=data))
        self.assertTrue(InboundItem.objects.get().is_deleted)
        self.assertEqual(WarehouseStock.objects.get().quantity, 0)
        original = SyncChange.objects.get(revision=first['revision']).record
        self.assertEqual(original['data']['items'][0]['quantity'], 10)

    def test_strict_validation_no_delete_stock_replacement_or_illegal_quantity(self):
        invalid = [{**self.inbound(), **change} for change in ({'is_deleted': True}, {'warehouse_stock': []}, {'revision': 20})]
        invalid.extend(self.inbound(qty) for qty in (0, -1, True, 1.5))
        data = self.inbound()
        data['items'][0]['purchase_price'] = -1
        invalid.append(data)
        for index, payload in enumerate(invalid):
            response = self.push(data=payload, op=f'invalid-{index}')
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()['results'][0]['code'], 'invalid_data')
        self.assertEqual(SyncOperation.objects.count(), len(invalid))
        self.assertEqual(InboundReceipt.objects.count(), 0)

    def test_mixed_invalid_legacy_price_and_valid_batch_isolated_and_durable(self):
        operations = [
            dict(operation_id='legacy-precision', kind='product', id='old', base_revision=0, data={'code': 'old', 'name': 'Legacy', 'default_purchase_price': 1.234}),
            dict(operation_id='legacy-name', kind='product', id='long', base_revision=0, data={'code': 'long', 'name': 'x' * 201}),
            dict(operation_id='valid-product', kind='product', id='sku', base_revision=0, data={'code': 'sku', 'name': 'Valid', 'default_purchase_price': 1.23}),
            dict(operation_id='valid-inbound', kind='inbound', id='in-1', base_revision=0, data=self.inbound()),
        ]
        body = dict(device_id='legacy-phone', operations=operations)
        def send():
            return self.client.post('/api/sync/v2/push', json.dumps(body), content_type='application/json', **self.headers)
        response = send()
        self.assertEqual(response.status_code, 200, response.content)
        results = response.json()['results']
        self.assertEqual([r['status'] for r in results], ['conflict', 'conflict', 'applied', 'applied'])
        self.assertEqual(results[0]['code'], 'invalid_data')
        self.assertIn('decimal places', results[0]['message'])
        self.assertFalse(Product.objects.filter(code='old').exists())
        self.assertEqual(str(Product.objects.get(code='sku').default_purchase_price), '1.23')
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)
        retried = send().json()['results']
        self.assertEqual(retried[:2], results[:2])
        self.assertEqual([r['status'] for r in retried[2:]], ['duplicate', 'duplicate'])
        self.assertEqual(SyncOperation.objects.count(), 4)
        self.assertEqual(StockLedger.objects.count(), 1)
        operations[0]['data']['default_purchase_price'] = 1.23
        self.assertEqual(send().json()['results'][0]['code'], 'operation_id_reused')
        self.assertFalse(Product.objects.filter(code='old').exists())

    def test_bad_operation_metadata_does_not_poison_batch(self):
        body = dict(device_id='phone', operations=[{'operation_id': 'broken', 'kind': 'delete', 'id': 'x', 'data': {}}, dict(operation_id='good', kind='product', id='sku', base_revision=0, data={'code': 'sku', 'name': 'Good'})])
        response = self.client.post('/api/sync/v2/push', json.dumps(body), content_type='application/json', **self.headers)
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['results'][0]['code'], 'invalid_data')
        self.assertEqual(response.json()['results'][1]['status'], 'applied')
        self.assertEqual(SyncOperation.objects.count(), 2)

    def test_cross_shop_pending_and_malformed_header_denied(self):
        other = Shop.objects.create(name='Shop B')
        self.headers['HTTP_X_ACTIVE_SHOP_ID'] = str(other.pk)
        self.assertEqual(self.get('sync/v2/pull').status_code, 403)
        ShopMembership.objects.create(user=self.user, shop=other, status='PENDING')
        self.assertEqual(self.get('view/inbound').status_code, 403)
        self.headers['HTTP_X_ACTIVE_SHOP_ID'] = 'bad-uuid'
        self.assertEqual(self.get('sync/v2/pull').status_code, 403)
        del self.headers['HTTP_X_ACTIVE_SHOP_ID']
        self.assertEqual(self.get('sync/v2/pull').status_code, 400)

    def test_same_client_ids_are_scoped_to_shop(self):
        self.applied(self.push())
        other = Shop.objects.create(name='Shop B')
        ShopMembership.objects.create(user=self.user, shop=other, role='ADMIN', status='APPROVED')
        self.headers['HTTP_X_ACTIVE_SHOP_ID'] = str(other.pk)
        self.applied(self.push(data=self.inbound(5)))
        self.assertEqual(InboundReceipt.objects.count(), 2)
        self.assertEqual(self.get('view/inbound').json()['items'][0]['data']['items'][0]['quantity'], 5)

    def test_legacy_mutators_retired_before_parsing(self):
        for path in ('sync/push', 'sync/pull'):
            self.assertEqual(self.client.post('/api/' + path, {}, **self.headers).status_code, 410)
        for method in ('post', 'put', 'delete'):
            self.assertEqual(getattr(self.client, method)('/api/inventory/products', {}, **self.headers).status_code, 405)

    def test_product_and_view_pagination_filters_detail(self):
        self.applied(self.push(kind='product', key='sku', data={'code': 'sku', 'name': 'Product'}, op='product'))
        self.applied(self.push())
        self.assertEqual(self.get('view/products', q='sku').json()['total'], 1)
        self.assertEqual(self.get('view/inbound', q='rebate', date_from='2026-10-27', is_settled='false').json()['total'], 1)
        self.assertEqual(self.get('view/inbound', date_from='2026-10-28').json()['total'], 0)
        self.assertEqual(self.get('view/inbound/in-1').json()['id'], 'in-1')
        self.assertEqual(self.get('view/inbound/missing').status_code, 404)
        self.assertEqual(self.get('view/inbound', page_size=101).status_code, 400)
        self.assertEqual(self.get('sync/v2/pull', cursor=999).status_code, 409)
        self.assertEqual(self.get('view/ledger').json()['total'], 1)
        self.assertEqual(self.get('view/logs').json()['items'][0]['username'], 'alice')

    def image(self):
        stream = io.BytesIO()
        Image.new('RGB', (4, 4), 'red').save(stream, format='JPEG')
        return stream.getvalue()

    def upload(self, content, claimed=None):
        data = {'file': SimpleUploadedFile('photo.jpg', content, content_type='image/jpeg')}
        if claimed is not None:
            data['sha256'] = claimed
        return self.client.post('/api/sync/v2/media', data, **self.headers)

    def test_private_media_hash_dedupe_and_cross_shop(self):
        content = self.image()
        digest = hashlib.sha256(content).hexdigest()
        self.assertEqual(self.upload(content).status_code, 200)
        self.assertEqual(self.upload(content).json()['sha256'], digest)
        self.assertEqual(PrivateMedia.objects.count(), 1)
        self.assertEqual(self.get('sync/v2/media/' + digest + '/exists').json()['exists'], True)
        downloaded = self.get('sync/v2/media/' + digest)
        self.assertEqual(b''.join(downloaded.streaming_content), content)
        self.assertEqual(downloaded['Cache-Control'], 'private, no-store')
        other = Shop.objects.create(name='Other')
        ShopMembership.objects.create(user=self.user, shop=other, role='ADMIN', status='APPROVED')
        self.headers['HTTP_X_ACTIVE_SHOP_ID'] = str(other.pk)
        self.assertEqual(self.get('sync/v2/media/' + digest).status_code, 404)
        self.assertEqual(self.get('sync/v2/media/' + digest + '/exists').status_code, 404)

    def test_media_invalid_missing_and_hash_mismatch(self):
        self.assertEqual(self.upload(b'not image').status_code, 400)
        self.assertEqual(self.upload(self.image(), '0' * 64).status_code, 400)
        data = self.inbound()
        data['image_sha256'] = '0' * 64
        self.assertEqual(self.push(data=data).json()['results'][0]['code'], 'media_missing')
        self.assertEqual(InboundReceipt.objects.count(), 0)

    def test_member_enum_and_creator_protection(self):
        target = CustomUser.objects.create_user(username='bob')
        member = ShopMembership.objects.create(user=target, shop=self.shop)
        for body in ({'membership_id': str(member.pk), 'role': 'CREATOR'}, {'membership_id': str(member.pk), 'status': 'INVALID'}, {'membership_id': str(self.membership.pk), 'role': 'MEMBER'}):
            response = self.client.post('/api/shops/members/update', json.dumps(body), content_type='application/json', **self.headers)
            self.assertEqual(response.status_code, 400)
        self.membership.refresh_from_db()
        self.assertEqual(self.membership.role, 'CREATOR')

    def test_admin_inventory_read_only(self):
        from inventory.admin import InboundReceiptAdmin
        from django.contrib.admin.sites import AdminSite
        from django.test import RequestFactory
        request = RequestFactory().get('/')
        request.user = self.user
        request.user.is_staff = request.user.is_superuser = True
        admin = InboundReceiptAdmin(InboundReceipt, AdminSite())
        self.assertFalse(admin.has_add_permission(request))
        self.assertFalse(admin.has_change_permission(request))
        self.assertFalse(admin.has_delete_permission(request))

    def test_fresh_operation_identical_zero_base_is_safe_duplicate(self):
        self.applied(self.push())
        result = self.push(op='fresh-identical').json()['results'][0]
        self.assertEqual(result['status'], 'duplicate')
        self.assertEqual(StockLedger.objects.count(), 1)
        self.assertEqual(SyncChange.objects.count(), 2)

    def test_attachment_survives_local_delete_and_readonly_view(self):
        digest = self.upload(self.image()).json()['sha256']
        data = self.inbound()
        data['image_sha256'] = digest
        self.applied(self.push(data=data))
        self.assertEqual(self.get('view/inbound/in-1').json()['data']['image_sha256'], digest)
        self.client.delete('/api/inventory/inbound/' + str(InboundReceipt.objects.get().pk), **self.headers)
        self.assertEqual(self.get('sync/v2/media/' + digest + '/exists').status_code, 200)
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)

    def test_legacy_image_import_respects_trusted_root(self):
        from pathlib import Path
        from django.core.management import call_command
        self.applied(self.push())
        receipt = InboundReceipt.objects.get()
        trusted = Path(self.media_dir.name) / 'legacy'
        trusted.mkdir()
        (trusted / 'photo.jpg').write_bytes(self.image())
        receipt.image_path = 'photo.jpg'
        receipt.save(update_fields=['image_path'])
        output = io.StringIO()
        call_command('import_legacy_media', source_root=str(trusted), shop=str(self.shop.pk), apply=True, stdout=output)
        receipt.refresh_from_db()
        self.assertEqual(receipt.image_sha256, hashlib.sha256(self.image()).hexdigest())
        self.assertEqual(receipt.image_path, 'photo.jpg')
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)
        self.assertEqual(self.get('sync/v2/media/' + receipt.image_sha256).status_code, 200)



class RetainedMigrationTests(TransactionTestCase):
    def test_existing_uuid_documents_stock_and_archives_survive(self):
        executor = MigrationExecutor(connection)
        executor.migrate([('inventory', '0002_inboundactionlog')])
        old = executor.loader.project_state([('inventory', '0002_inboundactionlog')]).apps
        ShopOld = old.get_model('shops', 'Shop')
        shop = ShopOld.objects.create(name='Legacy')
        receipt = old.get_model('inventory', 'InboundReceipt').objects.create(shop=shop, tracking_number='OLD', created_at=datetime.now(timezone.utc))
        line = old.get_model('inventory', 'InboundItem').objects.create(shop=shop, receipt=receipt, product_code='old', product_name='Old', quantity=100)
        stock = old.get_model('inventory', 'WarehouseStock').objects.create(shop=shop, product_code='old', product_name='Old', quantity=7)
        archive = old.get_model('inventory', 'Product').objects.create(shop=shop, code='archive', name='Archived', is_deleted=True)
        executor = MigrationExecutor(connection)
        executor.migrate(executor.loader.graph.leaf_nodes())
        self.assertEqual(InboundReceipt.objects.get(pk=receipt.pk).client_key, str(receipt.pk))
        self.assertEqual(InboundItem.objects.get(pk=line.pk).quantity, 100)
        self.assertEqual(WarehouseStock.objects.get(pk=stock.pk).quantity, 7)
        self.assertTrue(Product.objects.get(pk=archive.pk).is_deleted)
        self.assertEqual(SyncChange.objects.filter(shop_id=shop.pk).count(), 2)
        self.assertEqual(ShopSyncState.objects.get(shop_id=shop.pk).revision, 2)
        self.assertEqual(StockLedger.objects.get(shop_id=shop.pk).delta, 7)
        self.assertEqual(StockLedger.objects.get(shop_id=shop.pk).source_id, 'sync-v2-opening-balance')


class PostgreSQLConcurrencyTests(TransactionTestCase):
    """SQLite tests exercise behavior; real row-lock races require PostgreSQL."""
    def setUp(self):
        if connection.vendor != 'postgresql':
            self.skipTest('Run with postgres_test_settings for real row-lock concurrency.')
        self.user = CustomUser.objects.create_user(username='concurrent')
        self.shop = Shop.objects.create(name='Concurrent shop')
        ShopMembership.objects.create(user=self.user, shop=self.shop, role='ADMIN', status='APPROVED')

    def run_ops(self, operations):
        from concurrent.futures import ThreadPoolExecutor
        from threading import Barrier
        from django.db import close_old_connections
        from inventory.sync_schema import Operation
        from inventory.sync_service import apply_operation
        barrier = Barrier(len(operations))
        def apply(payload):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return apply_operation(self.shop, self.user, 'device', Operation.model_validate(payload))
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=len(operations)) as pool:
            return list(pool.map(apply, operations))

    def inbound_op(self, op='same'):
        return dict(operation_id=op, kind='inbound', id='in-1', base_revision=0, data=dict(tracking_number='SF1', created_at='2026-10-27T10:00:00+08:00', items=[dict(id='line', product_code='sku', product_name='Name', quantity=10)]))

    def test_simultaneous_first_write_same_operation_is_once(self):
        results = self.run_ops([self.inbound_op(), self.inbound_op()])
        self.assertCountEqual([r['status'] for r in results], ['applied', 'duplicate'])
        self.assertEqual(WarehouseStock.objects.get().quantity, 10)
        self.assertEqual(StockLedger.objects.count(), 1)
        self.assertEqual(SyncOperation.objects.count(), 1)
        self.assertEqual(ShopSyncState.objects.get().revision, 2)

    def test_simultaneous_outbound_cannot_oversell(self):
        from inventory.sync_schema import Operation
        from inventory.sync_service import apply_operation
        apply_operation(self.shop, self.user, 'a', Operation.model_validate(self.inbound_op()))
        operations = [dict(operation_id=f'out-op-{i}', kind='outbound', id=f'out-{i}', base_revision=0, data=dict(created_at='2026-10-27T11:00:00+08:00', items=[dict(id=f'out-line-{i}', product_code='sku', product_name='Name', quantity=8)])) for i in range(2)]
        results = self.run_ops(operations)
        self.assertCountEqual([r['status'] for r in results], ['applied', 'conflict'])
        self.assertEqual(WarehouseStock.objects.get().quantity, 2)
        self.assertEqual(StockLedger.objects.count(), 2)
        self.assertEqual(SyncChange.objects.count(), 4)

    def test_simultaneous_stale_document_updates_have_one_winner(self):
        from inventory.sync_schema import Operation
        from inventory.sync_service import apply_operation
        initial = apply_operation(self.shop, self.user, 'a', Operation.model_validate(self.inbound_op()))
        operations = []
        for i in range(2):
            operation = self.inbound_op(f'update-{i}')
            operation['base_revision'] = initial['revision']
            operation['data']['items'][0]['quantity'] = 11 + i
            operations.append(operation)
        results = self.run_ops(operations)
        self.assertCountEqual([r['status'] for r in results], ['applied', 'conflict'])
        winner = next(r for r in results if r['status'] == 'applied')
        self.assertEqual(WarehouseStock.objects.get().quantity, winner['record']['data']['items'][0]['quantity'])
        self.assertEqual(StockLedger.objects.count(), 2)



class AuthShopFlowTests(TestCase):
    def post(self, path, body, headers=None):
        return self.client.post('/api/' + path, json.dumps(body), content_type='application/json', **(headers or {}))

    def test_register_join_approve_login_and_revoke(self):
        a = self.post('auth/register', {'username': 'owner', 'password': 'testpass'}).json()
        b = self.post('auth/register', {'username': 'worker', 'password': 'testpass'}).json()
        ah = {'HTTP_AUTHORIZATION': 'Bearer ' + a['token']}
        bh = {'HTTP_AUTHORIZATION': 'Bearer ' + b['token']}
        shop = self.post('shops/create', {'name': 'Workflow'}, ah).json()
        ah['HTTP_X_ACTIVE_SHOP_ID'] = bh['HTTP_X_ACTIVE_SHOP_ID'] = shop['id']
        # Join is done without the still-unapproved active-shop header.
        self.assertEqual(self.post('shops/join', {'shop_id': shop['id']}, {'HTTP_AUTHORIZATION': bh['HTTP_AUTHORIZATION']}).status_code, 200)
        self.assertEqual(self.client.get('/api/view/stocks', **bh).status_code, 403)
        member = ShopMembership.objects.get(user_id=b['user_id'], shop_id=shop['id'])
        self.assertEqual(self.post('shops/members/update', {'membership_id': str(member.id), 'status': 'APPROVED'}, ah).status_code, 200)
        self.assertEqual(self.client.get('/api/view/stocks', **bh).status_code, 200)
        self.assertEqual(self.post('shops/members/update', {'membership_id': str(member.id), 'status': 'REJECTED'}, ah).status_code, 200)
        self.assertEqual(self.client.get('/api/sync/v2/pull', **bh).status_code, 403)
        self.assertEqual(self.post('auth/login', {'username': 'worker', 'password': 'testpass'}).status_code, 200)
