"""隔离验证拍手权限、多快递状态、结算快照与会话撤销。"""
import io
import json
import tempfile
import uuid
from decimal import Decimal
from datetime import timedelta
from unittest.mock import patch
import jwt
from PIL import Image
from django.conf import settings
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import connection, close_old_connections
from django.test import TestCase, TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from inventory.media import store_image
from inventory.models import InboundReceipt, InboundItem, WarehouseStock, StockLedger
from shops.models import CustomUser, Shop, ShopMembership
from shop_sync_backend.api import generate_token
from .auth import worker_token
from .models import Job, JobAudit, JobOrder, JobParcel, OperationReceipt, Settlement, WorkerAccount


class JobsTests(TestCase):
    def setUp(self):
        cache.clear()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.override = override_settings(PRIVATE_MEDIA_ROOT=self.temp.name)
        self.override.enable()
        self.addCleanup(self.override.disable)
        self.admin = CustomUser.objects.create_user(username='creator', password='admin-password')
        self.shop = Shop.objects.create(name='验收店A')
        ShopMembership.objects.create(shop=self.shop, user=self.admin, role='CREATOR', status='APPROVED')
        self.admin_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.admin), 'HTTP_X_ACTIVE_SHOP_ID': str(self.shop.pk)}
        self.other_shop = Shop.objects.create(name='验收店B')
        self.other_admin = CustomUser.objects.create_user(username='other', password='admin-password')
        ShopMembership.objects.create(shop=self.other_shop, user=self.other_admin, role='CREATOR', status='APPROVED')
        self.other_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.other_admin), 'HTTP_X_ACTIVE_SHOP_ID': str(self.other_shop.pk)}
        self.worker, self.headers = self.register('worker-a')
        self.second, self.second_headers = self.register('worker-b')
        self.job = self.create_job()

    def post(self, path, data, headers=None, method='post'):
        return getattr(self.client, method)('/api' + path, json.dumps(data), content_type='application/json', **(headers or self.admin_headers))

    def get(self, path, headers=None, **params):
        return self.client.get('/api' + path, params, **(headers or self.admin_headers))

    def register(self, name, shop=None):
        shop = shop or self.shop
        response = self.post('/worker/register', {'shop_number': str(shop.shop_number), 'username': name,
            'password': 'worker-password', 'display_name': name, 'phone': '13800000000'})
        self.assertEqual(response.status_code, 200, response.content)
        token = response.json()['token']
        worker = WorkerAccount.objects.get(pk=response.json()['worker']['id'])
        return worker, {'HTTP_AUTHORIZATION': 'Bearer ' + token}

    def create_job(self, **overrides):
        data = dict(title='新作业', description='作业说明', cost_amount='10.25', refund_amount='12.50', photo_sha256s=[], status='open')
        data.update(overrides)
        response = self.post('/jobs', data)
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def order(self, numbers=None, name='000123', headers=None, operation=None):
        response = self.post('/worker/orders', {'job_id': self.job['id'], 'order_number': name,
            'tracking_numbers': numbers or ['SF001', 'SF002'], 'operation_id': operation or str(uuid.uuid4())}, headers or self.headers)
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def receipt(self, number, shop=None, qty=3):
        receipt = InboundReceipt.objects.create(shop=shop or self.shop, tracking_number=number, client_key='in-' + str(uuid.uuid4()),
            revision=10, created_at=timezone.now(), ocr_status='confirmed')
        InboundItem.objects.create(shop=receipt.shop, receipt=receipt, client_key=str(uuid.uuid4()),
            product_code='SKU001', product_name='验收商品', quantity=qty, purchase_price='1.20', sale_price='2.50')
        return receipt

    def detail(self, order, headers=None):
        response = self.get('/jobs/orders/' + order['id'], headers)
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def settle_payload(self, order, operation=None):
        detail = self.detail(order)
        return {'expected_version': detail['version'], 'expected_job_version': detail['job']['version'],
                'operation_id': operation or str(uuid.uuid4()), 'evidence': [dict(tracking_number=p['tracking_number'],
                    receipt_id=p['receipt']['receipt_id'], revision=p['receipt']['revision']) for p in detail['parcels'] if p['receipt']]}

    def test_admin_revoked_while_waiting_for_shop_lock_cannot_write(self):
        from .services import lock_shop
        manager = CustomUser.objects.create_user(username='revoked-manager', password='admin-password')
        membership = ShopMembership.objects.create(
            shop=self.shop, user=manager, role='ADMIN', status='APPROVED',
        )
        headers = {**self.admin_headers, 'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(manager)}

        def revoke_then_lock(shop):
            # 模拟请求初次鉴权通过、取得店铺锁之前，创建人已撤销管理员资格。
            ShopMembership.objects.filter(pk=membership.pk).update(status='REJECTED')
            return lock_shop(shop)

        before = Job.objects.count()
        with patch('jobs.services.lock_shop', side_effect=revoke_then_lock):
            response = self.post('/jobs', {
                'title': '不应创建', 'description': '', 'cost_amount': '1.00',
                'refund_amount': '2.00', 'photo_sha256s': [], 'status': 'open',
            }, headers)
        self.assertEqual(response.status_code, 403, response.content)
        self.assertEqual(Job.objects.count(), before)

    def test_public_shop_numeric_registration_and_no_inventory_identity(self):
        response = self.get('/worker/shop', shop_number=str(self.shop.shop_number))
        self.assertEqual(response.json(), {'shop_number': str(self.shop.shop_number), 'name': self.shop.name})
        self.assertFalse(CustomUser.objects.filter(username='worker-a').exists())
        self.assertFalse(ShopMembership.objects.filter(user__username='worker-a').exists())
        self.assertTrue(self.worker.check_password('worker-password'))
        me = self.get('/worker/me', self.headers)
        self.assertEqual(me.json()['shop_number'], str(self.shop.shop_number))
        for field in ('password', 'token', 'auth_version', 'legacy_user'):
            self.assertNotIn(field, me.json())
        self.assertEqual(self.get('/worker/shop', shop_number='9999').status_code, 422)
        self.assertEqual(self.get('/worker/shop', shop_number='999999999').status_code, 404)

    def test_worker_and_admin_tokens_cannot_be_exchanged(self):
        for endpoint in ['/view/inbound', '/sync/v2/pull', '/shops/my-shops', '/jobs', '/shops/members']:
            headers = {**self.headers, 'HTTP_X_ACTIVE_SHOP_ID': str(self.shop.pk)}
            self.assertEqual(self.get(endpoint, headers).status_code, 401, endpoint)
        self.assertEqual(self.post('/shops/create', {'name': '越权店'}, self.headers).status_code, 401)
        self.assertEqual(self.get('/worker/jobs', self.admin_headers).status_code, 401)

    def test_registration_rejects_owner_and_duplicate_disabled_bypass(self):
        body = {'shop_number': str(self.shop.shop_number), 'username': 'forged', 'password': 'worker-password',
                'display_name': '伪造', 'role': 'ADMIN'}
        self.assertEqual(self.post('/worker/register', body).status_code, 422)
        self.worker.is_active = False
        self.worker.save()
        body.pop('role')
        body['username'] = self.worker.username
        self.assertEqual(self.post('/worker/register', body).status_code, 400)
        self.assertFalse(WorkerAccount.objects.get(pk=self.worker.pk).is_active)

    def test_static_routes_are_not_captured_by_job_uuid(self):
        for endpoint in ['/jobs/orders', '/jobs/workers', '/worker/orders', '/worker/jobs']:
            headers = self.headers if endpoint.startswith('/worker') else self.admin_headers
            response = self.get(endpoint, headers)
            self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(self.post('/jobs/media', {}).status_code, 422)

    def test_own_order_preserves_zero_and_partial_then_full_arrival(self):
        order = self.order()
        self.assertEqual(order['order_number'], '000123')
        self.assertEqual(order['status'], 'in_transit')
        self.receipt('SF001')
        response = self.get('/worker/orders/' + order['id'], self.headers).json()
        self.assertEqual((response['arrived_count'], response['parcel_count'], response['status']), (1, 2, 'in_transit'))
        self.receipt('SF002', self.other_shop)
        response = self.get('/worker/orders/' + order['id'], self.headers).json()
        self.assertEqual(response['arrived_count'], 1)
        self.receipt('SF002')
        response = self.get('/worker/orders/' + order['id'], self.headers).json()
        self.assertEqual(response['status'], 'arrived')
        for parcel in response['parcels']:
            self.assertEqual(set(parcel), {'id', 'tracking_number', 'arrived', 'arrived_at'})
        self.assertNotIn('products', response)
        self.assertNotIn('worker', response)
        arrived = self.get('/worker/orders', self.headers, status='arrived').json()
        self.assertEqual(arrived['total'], 1)
        self.assertEqual(self.get('/worker/orders', self.headers, status='in_transit').json()['total'], 0)

    def test_order_owner_and_shop_are_server_decided(self):
        order = self.order()
        self.assertEqual(self.get('/worker/orders/' + order['id'], self.second_headers).status_code, 404)
        edit = {'order_number': 'new', 'tracking_numbers': ['OTHER'], 'expected_version': 1, 'operation_id': 'edit'}
        self.assertEqual(self.post('/worker/orders/' + order['id'], edit, self.second_headers, 'patch').status_code, 404)
        self.assertEqual(self.get('/jobs/orders/' + order['id'], self.other_headers).status_code, 404)
        forged = {'job_id': self.job['id'], 'order_number': 'NEW', 'tracking_numbers': ['SF0'],
                  'operation_id': 'forge', 'worker_id': str(self.second.pk)}
        self.assertEqual(self.post('/worker/orders', forged, self.headers).status_code, 422)
        self.assertEqual(self.get('/worker/orders', self.second_headers).json()['total'], 0)

    def test_order_create_and_update_retry_are_idempotent_and_versioned(self):
        order = self.order(operation='create-once')
        duplicate = self.order(operation='create-once')
        self.assertEqual(order['id'], duplicate['id'])
        self.assertEqual(JobOrder.objects.count(), 1)
        data = {'order_number': '000124', 'tracking_numbers': ['SF003', 'SF003', 'SF004'],
                'expected_version': order['version'], 'operation_id': 'update-once'}
        edited = self.post('/worker/orders/' + order['id'], data, self.headers, 'patch')
        self.assertEqual(edited.status_code, 200, edited.content)
        self.assertEqual(edited.json()['parcel_count'], 2)
        self.assertEqual(self.post('/worker/orders/' + order['id'], data, self.headers, 'patch').status_code, 200)
        self.assertEqual(JobParcel.objects.filter(order_id=order['id'], is_active=False).count(), 2)
        data['operation_id'] = 'stale-edit'
        self.assertEqual(self.post('/worker/orders/' + order['id'], data, self.headers, 'patch').status_code, 409)
        data['order_number'] = 'DIFFERENT'
        data['operation_id'] = 'update-once'
        self.assertEqual(self.post('/worker/orders/' + order['id'], data, self.headers, 'patch').status_code, 409)

    def test_closed_jobs_hide_from_other_workers_but_keep_own_unsettled_edit(self):
        order = self.order()
        row = Job.objects.get(pk=self.job['id'])
        row.status = 'closed'
        row.save()
        self.assertEqual(self.get('/worker/jobs', self.second_headers).json()['total'], 0)
        self.assertEqual(self.get('/worker/jobs/' + self.job['id'], self.second_headers).status_code, 404)
        self.assertEqual(self.get('/worker/jobs', self.headers).json()['total'], 1)
        data = {'order_number': 'changed', 'tracking_numbers': ['SF003'], 'expected_version': 1, 'operation_id': 'closed-edit'}
        self.assertEqual(self.post('/worker/orders/' + order['id'], data, self.headers, 'patch').status_code, 200)
        data = {'job_id': self.job['id'], 'order_number': 'new', 'tracking_numbers': ['SF9'], 'operation_id': 'closed-new'}
        self.assertEqual(self.post('/worker/orders', data, self.headers).status_code, 404)

    def test_settlement_snapshot_idempotency_lock_and_no_inventory_mutation(self):
        order = self.order()
        r1, r2 = self.receipt('SF001'), self.receipt('SF002')
        stock = WarehouseStock.objects.create(shop=self.shop, product_code='SKU001', product_name='商品', quantity=23)
        ledger_before = StockLedger.objects.count()
        payload = self.settle_payload(order, 'settle-once')
        response = self.post('/jobs/orders/' + order['id'] + '/settle', payload)
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['status'], 'settled')
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', payload).status_code, 200)
        self.assertEqual(Settlement.objects.count(), 1)
        self.assertEqual(JobAudit.objects.filter(action='ORDER_SETTLED').count(), 1)
        stock.refresh_from_db()
        r1.refresh_from_db()
        self.assertEqual(stock.quantity, 23)
        self.assertEqual(StockLedger.objects.count(), ledger_before)
        self.assertFalse(r1.is_settled)
        row = Job.objects.get(pk=self.job['id'])
        row.refund_amount = Decimal('99.99')
        row.version += 1
        row.save()
        own = self.get('/worker/orders/' + order['id'], self.headers).json()
        self.assertEqual(own['settlement']['refund_amount'], '12.50')
        self.assertEqual(own['job']['refund_amount'], '99.99')
        self.assertNotIn('snapshot', own['settlement'])
        edit = {'order_number': 'changed', 'tracking_numbers': ['OTHER'], 'expected_version': own['version'], 'operation_id': 'settled-edit'}
        self.assertEqual(self.post('/worker/orders/' + order['id'], edit, self.headers, 'patch').status_code, 409)

    def test_settle_rejects_partial_stale_order_job_and_evidence(self):
        order = self.order()
        self.receipt('SF001')
        partial = self.settle_payload(order)
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', partial).status_code, 409)
        r2 = self.receipt('SF002')
        payload = self.settle_payload(order)
        r2.revision += 1
        r2.save()
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', payload).status_code, 409)
        payload = self.settle_payload(order)
        payload['expected_version'] = 99
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', payload).status_code, 409)
        payload = self.settle_payload(order)
        payload['expected_job_version'] = 99
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', payload).status_code, 409)
        self.assertEqual(Settlement.objects.count(), 0)

    def test_reopen_retains_settlement_and_allows_edit_with_fresh_version(self):
        order = self.order()
        self.receipt('SF001')
        self.receipt('SF002')
        settled = self.post('/jobs/orders/' + order['id'] + '/settle', self.settle_payload(order)).json()
        payload = {'expected_version': settled['version'], 'operation_id': 'reopen-once', 'reason': '单号需要更正'}
        response = self.post('/jobs/orders/' + order['id'] + '/reopen', payload)
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['status'], 'arrived')
        self.assertFalse(Settlement.objects.get().is_active)
        self.assertEqual(Settlement.objects.get().reopen_reason, '单号需要更正')
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/reopen', payload).status_code, 200)
        data = {'order_number': 'new', 'tracking_numbers': ['NOTARRIVED'], 'expected_version': response.json()['version'], 'operation_id': 'after-reopen'}
        changed = self.post('/worker/orders/' + order['id'], data, self.headers, 'patch')
        self.assertEqual(changed.status_code, 200, changed.content)
        self.assertEqual(changed.json()['status'], 'in_transit')
        self.assertEqual(Settlement.objects.count(), 1)

    def test_duplicate_tracking_warns_only_admin_and_admin_sees_whole_order_products(self):
        order = self.order()
        self.order(['SF001'], name='another', headers=self.second_headers)
        self.receipt('SF001', qty=3)
        self.receipt('SF002', qty=4)
        detail = self.detail(order)
        self.assertEqual(len(detail['parcels']), 2)
        self.assertTrue(detail['parcels'][0]['duplicate_claim'])
        self.assertEqual(detail['products'][0]['quantity'], 7)
        self.assertEqual(detail['products'][0]['tracking_numbers'], ['SF001', 'SF002'])
        self.assertIn('receipt', detail['parcels'][0])
        own = self.get('/worker/orders/' + order['id'], self.headers).json()
        self.assertNotIn('duplicate_claim', own['parcels'][0])
        self.assertNotIn('products', own)
        self.assertEqual(self.get('/jobs/orders', q='SF002').json()['total'], 1)

    def test_disable_enable_and_reset_revoke_old_tokens_without_deleting_orders(self):
        order = self.order()
        response = self.post('/jobs/workers/' + str(self.worker.pk) + '/enabled', {'enabled': False, 'expected_version': 1})
        self.assertEqual(response.status_code, 200, response.content)
        for endpoint in ['/worker/me', '/worker/jobs', '/worker/orders', '/worker/orders/' + order['id']]:
            self.assertEqual(self.get(endpoint, self.headers).status_code, 403)
        login = {'shop_number': str(self.shop.shop_number), 'username': self.worker.username, 'password': 'worker-password'}
        self.assertEqual(self.post('/worker/login', login).status_code, 403)
        response = self.post('/jobs/workers/' + str(self.worker.pk) + '/enabled', {'enabled': True, 'expected_version': 2})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.get('/worker/orders', self.headers).status_code, 401)
        fresh = self.post('/worker/login', login)
        new_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + fresh.json()['token']}
        self.assertEqual(self.get('/worker/orders', new_headers).json()['total'], 1)
        response = self.post('/jobs/workers/' + str(self.worker.pk) + '/password', {'new_password': 'brand-new-password', 'expected_version': 3})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.get('/worker/orders', new_headers).status_code, 401)
        self.assertEqual(self.post('/worker/login', login).status_code, 400)
        login['password'] = 'brand-new-password'
        self.assertEqual(self.post('/worker/login', login).status_code, 200)
        self.assertEqual(JobOrder.objects.count(), 1)
        self.assertFalse(any('password' in row.detail for row in JobAudit.objects.filter(worker=self.worker)))

    def test_admin_cannot_manage_other_shop_worker_or_customuser_id(self):
        data = {'enabled': False, 'expected_version': 1}
        self.assertEqual(self.post('/jobs/workers/' + str(self.worker.pk) + '/enabled', data, self.other_headers).status_code, 404)
        self.assertEqual(self.post('/jobs/workers/' + str(self.admin.pk) + '/enabled', data).status_code, 404)
        self.assertEqual(self.get('/jobs/workers', self.other_headers).json()['total'], 0)
        data['role'] = 'CREATOR'
        self.assertEqual(self.post('/jobs/workers/' + str(self.worker.pk) + '/enabled', data).status_code, 422)

    def test_protected_job_photos_and_disabled_token(self):
        image = io.BytesIO()
        Image.new('RGB', (12, 12), 'red').save(image, 'PNG')
        media = store_image(self.shop, image.getvalue())
        other = store_image(self.other_shop, image.getvalue())
        job = self.create_job(photo_sha256s=[media.sha256])
        endpoint = '/worker/jobs/' + job['id'] + '/photos/' + media.sha256
        response = self.get(endpoint, self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(b''.join(response.streaming_content), image.getvalue())
        self.assertEqual(self.get('/worker/jobs/' + self.job['id'] + '/photos/' + media.sha256, self.headers).status_code, 404)
        other_worker, other_headers = self.register('worker-a', self.other_shop)
        self.assertEqual(self.get(endpoint, other_headers).status_code, 404)
        self.worker.is_active = False
        self.worker.save()
        self.assertEqual(self.get(endpoint, self.headers).status_code, 403)
        self.assertEqual(self.get('/sync/v2/media/' + media.sha256, self.headers).status_code, 401)

    def test_job_validation_versions_and_photo_membership(self):
        invalid = {'title': '无效', 'cost_amount': '1.234', 'refund_amount': '2.00'}
        self.assertEqual(self.post('/jobs', invalid).status_code, 422)
        invalid['cost_amount'] = '-1'
        self.assertEqual(self.post('/jobs', invalid).status_code, 422)
        invalid['cost_amount'] = '1.00'
        invalid['photo_sha256s'] = ['a' * 64]
        self.assertEqual(self.post('/jobs', invalid).status_code, 400)
        data = dict(title='改名', description='', cost_amount='1.00', refund_amount='3.00', photo_sha256s=[], status='closed', expected_version=99)
        self.assertEqual(self.post('/jobs/' + self.job['id'], data, method='patch').status_code, 409)
        data['expected_version'] = 1
        self.assertEqual(self.post('/jobs/' + self.job['id'], data, method='patch').status_code, 200)

    def test_order_list_query_count_is_bounded_and_filters_are_global(self):
        self.receipt('SF001')
        self.receipt('SF002')
        for i in range(6):
            self.order(name=f'ORDER-{i}')
        with CaptureQueriesContext(connection) as queries:
            response = self.get('/jobs/orders', page_size=3, status='arrived')
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['total'], 6)
        self.assertEqual(len(response.json()['items']), 3)
        # 补充图片通过单次预取新增一条查询，订单数增加不能产生逐单查询。
        self.assertLessEqual(len(queries), 13)
        with CaptureQueriesContext(connection) as expanded_queries:
            expanded = self.get('/jobs/orders', page_size=6, status='arrived')
        self.assertEqual(len(expanded.json()['items']), 6)
        self.assertLessEqual(len(expanded_queries), len(queries))

    def test_worker_claim_rejects_malformed_or_wrong_purpose_tokens(self):
        malformed = jwt.encode({'sub': 'invalid', 'shop': str(self.shop.pk), 'version': 1, 'purpose': 'worker',
                                'aud': 'shop-job-worker', 'exp': timezone.now() + timedelta(days=1)}, settings.SECRET_KEY, algorithm='HS256')
        self.assertEqual(self.get('/worker/me', {'HTTP_AUTHORIZATION': 'Bearer ' + malformed}).status_code, 401)


    def test_public_input_bounds_and_login_throttle(self):
        invalid = {'shop_number': str(self.shop.shop_number), 'username': 'new-worker', 'password': 'worker-password', 'display_name': '   '}
        self.assertEqual(self.post('/worker/register', invalid).status_code, 422)
        body = {'shop_number': str(self.shop.shop_number), 'username': self.worker.username, 'password': 'wrong-password'}
        for attempt in range(10):
            self.assertEqual(self.post('/worker/login', body).status_code, 400)
        self.assertEqual(self.post('/worker/login', body).status_code, 429)
        cache.clear()
        body['password'] = 'worker-password'
        self.assertEqual(self.post('/worker/login', body).status_code, 200)
        self.assertEqual(self.post('/worker/login', body).status_code, 200)

    def test_reused_operation_cannot_target_another_order(self):
        first = self.order(name='FIRST')
        second = self.order(name='SECOND')
        update = {'order_number': 'NEW', 'tracking_numbers': ['OTHER'], 'expected_version': 1, 'operation_id': 'same-edit-key'}
        self.assertEqual(self.post('/worker/orders/' + first['id'], update, self.headers, 'patch').status_code, 200)
        self.assertEqual(self.post('/worker/orders/' + second['id'], update, self.headers, 'patch').status_code, 409)
        self.assertEqual(JobOrder.objects.get(pk=second['id']).order_number, 'SECOND')


    def test_settlement_keeps_full_original_receipt_and_job_evidence(self):
        order = self.order(['SF001'])
        receipt = self.receipt('SF001', qty=3)
        response = self.post('/jobs/orders/' + order['id'] + '/settle', self.settle_payload(order))
        self.assertEqual(response.status_code, 200, response.content)
        settlement = Settlement.objects.get()
        self.assertEqual(settlement.snapshot['receipt_snapshots'][0]['items'][0]['quantity'], 3)
        self.assertEqual(settlement.snapshot['job']['refund_amount'], '12.50')
        receipt.revision += 1
        receipt.save()
        receipt.items.update(quantity=99)
        detail = self.detail(order)
        self.assertTrue(detail['evidence_changed'])
        settlement.refresh_from_db()
        self.assertEqual(settlement.snapshot['receipt_snapshots'][0]['items'][0]['quantity'], 3)

    def test_internal_django_admin_cannot_bypass_shop_scope(self):
        from django.contrib import admin
        from django.test import RequestFactory
        request = RequestFactory().get('/admin/jobs/workeraccount/')
        self.admin.is_staff = True
        request.user = self.admin
        model_admin = admin.site._registry[WorkerAccount]
        self.assertFalse(model_admin.has_view_permission(request))
        self.assertFalse(model_admin.has_add_permission(request))
        self.assertFalse(model_admin.has_change_permission(request))
        self.assertEqual(model_admin.get_queryset(request).count(), 0)
        self.assertIn('password', model_admin.get_exclude(request))


    def test_legacy_short_username_and_long_password_are_usable(self):
        worker = WorkerAccount(shop=self.shop, username='a', display_name='旧拍手')
        worker.set_password('legacy-password')
        worker.save()
        body = {'shop_number': str(self.shop.shop_number), 'username': 'a', 'password': 'legacy-password'}
        response = self.post('/worker/login', body)
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['worker']['id'], str(worker.pk))


class JobConcurrencyTests(TransactionTestCase):
    """只有真实PostgreSQL行锁能验证结算与拍手编辑的提交顺序。"""
    def setUp(self):
        if connection.vendor != 'postgresql':
            self.skipTest('此组需要独立PostgreSQL验证真实行锁。')
        self.admin = CustomUser.objects.create_user(username='parallel-admin', password='admin-password')
        self.shop = Shop.objects.create(name='并发验收店')
        ShopMembership.objects.create(user=self.admin, shop=self.shop, role='CREATOR', status='APPROVED')
        self.worker = WorkerAccount(shop=self.shop, username='parallel-worker', display_name='并发拍手')
        self.worker.set_password('worker-password')
        self.worker.save()
        self.admin_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.admin), 'HTTP_X_ACTIVE_SHOP_ID': str(self.shop.pk)}
        self.worker_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + worker_token(self.worker)}
        self.job = Job.objects.create(shop=self.shop, title='并发作业', cost_amount='1.00', refund_amount='2.00', created_by=self.admin)
        self.order = JobOrder.objects.create(shop=self.shop, job=self.job, worker=self.worker, order_number='ORDER')
        self.parcel = JobParcel.objects.create(shop=self.shop, order=self.order, tracking_number='TRACK', position=0)
        self.receipt = InboundReceipt.objects.create(shop=self.shop, tracking_number='TRACK', client_key='parallel-in', revision=11,
                                                    created_at=timezone.now(), ocr_status='confirmed')
        self.payload = {'expected_version': 1, 'expected_job_version': 1, 'operation_id': 'parallel-settle',
                        'evidence': [{'tracking_number': 'TRACK', 'receipt_id': str(self.receipt.pk), 'revision': 11}]}

    def race(self, calls):
        from concurrent.futures import ThreadPoolExecutor
        from threading import Barrier
        from django.test import Client
        barrier = Barrier(len(calls))
        def run(call):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                path, data, headers, method = call
                response = getattr(Client(), method)('/api' + path, json.dumps(data), content_type='application/json', **headers)
                return response.status_code, response.json()
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=len(calls)) as executor:
            return list(executor.map(run, calls))

    def test_simultaneous_same_settlement_is_once(self):
        path = '/jobs/orders/' + str(self.order.pk) + '/settle'
        results = self.race([(path, self.payload, self.admin_headers, 'post')] * 2)
        self.assertEqual([result[0] for result in results], [200, 200], results)
        self.assertEqual(Settlement.objects.filter(is_active=True).count(), 1)
        self.assertEqual(JobAudit.objects.filter(action='ORDER_SETTLED').count(), 1)
        self.assertEqual(OperationReceipt.objects.count(), 1)

    def test_simultaneous_different_settlement_keys_have_one_winner(self):
        path = '/jobs/orders/' + str(self.order.pk) + '/settle'
        other = {**self.payload, 'operation_id': 'other-settle'}
        results = self.race([(path, self.payload, self.admin_headers, 'post'), (path, other, self.admin_headers, 'post')])
        self.assertEqual(sorted(result[0] for result in results), [200, 409], results)
        self.assertEqual(Settlement.objects.filter(is_active=True).count(), 1)

    def test_simultaneous_edit_and_settle_never_settle_new_tracking_with_old_evidence(self):
        edit = {'expected_version': 1, 'operation_id': 'concurrent-edit', 'order_number': 'CHANGED', 'tracking_numbers': ['NOT-ARRIVED']}
        results = self.race([('/jobs/orders/' + str(self.order.pk) + '/settle', self.payload, self.admin_headers, 'post'),
                             ('/worker/orders/' + str(self.order.pk), edit, self.worker_headers, 'patch')])
        self.assertEqual(sorted(result[0] for result in results), [200, 409], results)
        self.order.refresh_from_db()
        active = Settlement.objects.filter(order=self.order, is_active=True).first()
        if active:
            self.assertEqual(self.order.order_number, 'ORDER')
            self.assertEqual(active.snapshot['tracking_numbers'], ['TRACK'])
        else:
            self.assertEqual(self.order.order_number, 'CHANGED')
            self.assertEqual(list(self.order.parcels.filter(is_active=True).values_list('tracking_number', flat=True)), ['NOT-ARRIVED'])

    def test_simultaneous_order_retry_creates_one_order(self):
        payload = {'job_id': str(self.job.pk), 'order_number': 'NEW', 'tracking_numbers': ['TRACK-NEW'], 'operation_id': 'parallel-create'}
        results = self.race([('/worker/orders', payload, self.worker_headers, 'post')] * 2)
        self.assertEqual([result[0] for result in results], [200, 200], results)
        self.assertEqual(JobOrder.objects.filter(order_number='NEW').count(), 1)
        self.assertEqual(JobAudit.objects.filter(action='ORDER_CREATED').count(), 1)

    def test_simultaneous_reopen_is_once_and_keeps_history(self):
        response = self.client.post('/api/jobs/orders/' + str(self.order.pk) + '/settle', json.dumps(self.payload),
                                    content_type='application/json', **self.admin_headers)
        self.assertEqual(response.status_code, 200, response.content)
        payload = {'expected_version': response.json()['version'], 'operation_id': 'parallel-reopen', 'reason': '更正凭证'}
        results = self.race([('/jobs/orders/' + str(self.order.pk) + '/reopen', payload, self.admin_headers, 'post')] * 2)
        self.assertEqual([result[0] for result in results], [200, 200], results)
        self.assertEqual(Settlement.objects.count(), 1)
        self.assertEqual(Settlement.objects.filter(is_active=True).count(), 0)
        self.assertEqual(JobAudit.objects.filter(action='SETTLEMENT_REOPENED').count(), 1)

    def test_disable_serializes_with_edit_and_old_token_stays_revoked(self):
        edit = {'expected_version': 1, 'operation_id': 'disable-race-edit', 'order_number': 'MAY-CHANGE', 'tracking_numbers': ['NEXT']}
        results = self.race([('/jobs/workers/' + str(self.worker.pk) + '/enabled', {'expected_version': 1, 'enabled': False}, self.admin_headers, 'post'),
                             ('/worker/orders/' + str(self.order.pk), edit, self.worker_headers, 'patch')])
        self.assertEqual(results[0][0], 200, results)
        self.assertIn(results[1][0], [200, 401, 403], results)
        self.assertEqual(self.client.get('/api/worker/orders', **self.worker_headers).status_code, 403)
        self.assertEqual(JobOrder.objects.count(), 1)
