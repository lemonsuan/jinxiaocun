"""数字店铺与管理身份的接口、迁移及真实并发回归。"""
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier

import jwt
from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import connection, connections, close_old_connections
from django.db.migrations.executor import MigrationExecutor
from django.test import RequestFactory, TestCase, TransactionTestCase
from django.utils import timezone

from .models import CustomUser, Shop, ShopMembership, ShopNumberSequence
from shop_sync_backend.api import auth_bearer, generate_token


class NumericShopTests(TestCase):
    def setUp(self):
        self.owner = CustomUser.objects.create_user(username='owner', password='safe-password')
        self.other = CustomUser.objects.create_user(username='manager', password='safe-password')
        self.owner_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.owner)}
        self.other_headers = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(self.other)}

    def post(self, path, body, headers=None):
        return self.client.post('/api/' + path, json.dumps(body), content_type='application/json', **(headers or {}))

    def owned_shop(self, name='示例店铺'):
        shop = Shop.objects.create(name=name)
        ShopMembership.objects.create(user=self.owner, shop=shop, role='CREATOR', status='APPROVED')
        return shop

    def test_numbers_start_at_10000_and_deleted_numbers_are_not_reused(self):
        first = Shop.objects.create(name='第一家')
        second = Shop.objects.create(name='第二家')
        self.assertEqual((first.shop_number, second.shop_number), (10000, 10001))
        first.delete()
        self.assertEqual(Shop.objects.create(name='第三家').shop_number, 10002)
        self.assertEqual(ShopNumberSequence.objects.get(pk=1).next_number, 10003)

    def test_number_is_immutable_and_explicit_high_number_advances_allocator(self):
        shop = Shop.objects.create(name='迁入编号', shop_number=20000)
        self.assertEqual(Shop.objects.create(name='后续自动编号').shop_number, 20001)
        shop.shop_number = 99999
        with self.assertRaises(ValidationError):
            shop.save()
        shop.refresh_from_db()
        self.assertEqual(shop.shop_number, 20000)

    def test_create_and_list_keep_uuid_and_add_string_number(self):
        response = self.post('shops/create', {'name': '新店铺', 'shop_number': '99999'}, self.owner_headers)
        self.assertEqual(response.status_code, 200, response.content)
        body = response.json()
        shop = Shop.objects.get(pk=body['id'])
        self.assertEqual(body['shop_number'], '10000')
        self.assertEqual(str(shop.pk), body['id'])
        memberships = self.client.get('/api/shops/my-shops', **self.owner_headers).json()
        self.assertEqual(memberships[0]['shop_id'], body['id'])
        self.assertEqual(memberships[0]['shop_number'], '10000')
        self.assertEqual(memberships[0]['role'], 'CREATOR')

    def test_numeric_join_and_legacy_uuid_join_use_same_management_application(self):
        shop = self.owned_shop()
        numeric = self.post('shops/join', {'shop_number': str(shop.shop_number)}, self.other_headers)
        self.assertEqual(numeric.status_code, 200, numeric.content)
        membership = ShopMembership.objects.get(shop=shop, user=self.other)
        self.assertEqual((membership.role, membership.status), ('ADMIN', 'PENDING'))
        duplicate = self.post('shops/join', {'shop_id': str(shop.pk)}, self.other_headers)
        self.assertEqual(duplicate.status_code, 400)
        self.assertEqual(ShopMembership.objects.filter(shop=shop, user=self.other).count(), 1)
        self.assertEqual(self.client.get('/api/view/stocks', **{**self.other_headers, 'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)}).status_code, 403)
        approved = self.post('shops/members/update', {'membership_id': str(membership.pk), 'status': 'APPROVED'}, {**self.owner_headers, 'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)})
        self.assertEqual(approved.status_code, 200, approved.content)
        self.assertEqual(self.client.get('/api/view/stocks', **{**self.other_headers, 'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)}).status_code, 200)

    def test_invalid_or_conflicting_identity_never_creates_membership(self):
        shop = self.owned_shop()
        second = self.owned_shop('另一家')
        for body in ({}, {'shop_number': '9999'}, {'shop_number': '010000'}, {'shop_number': 'x10000'}, {'shop_number': '999999999999999999999'}, {'shop_number': '12345'}, {'shop_number': str(shop.shop_number), 'shop_id': str(second.pk)}):
            with self.subTest(body=body):
                self.assertEqual(self.post('shops/join', body, self.other_headers).status_code, 400)
        self.assertFalse(ShopMembership.objects.filter(user=self.other).exists())

    def test_worker_and_legacy_member_tokens_cannot_access_inventory_or_my_shops(self):
        shop = self.owned_shop()
        membership = ShopMembership.objects.create(user=self.other, shop=shop, role='WORKER', status='APPROVED')
        headers = {**self.other_headers, 'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)}
        for path in ('view/stocks', 'sync/v2/pull', 'inventory/products'):
            self.assertEqual(self.client.get('/api/' + path, **headers).status_code, 403)
        self.assertEqual(self.client.get('/api/shops/my-shops', **self.other_headers).json(), [])
        # 历史行即便尚未迁移，认证也不能只靠APPROVED授予库存访问。
        membership.role = 'MEMBER'
        membership.save()
        self.assertEqual(self.client.get('/api/view/stocks', **headers).status_code, 403)
        self.assertEqual(self.client.get('/api/shops/my-shops', **self.other_headers).json(), [])

    def test_role_revoked_after_authentication_cannot_write_inventory(self):
        from inventory.models import Product, ShopSyncState, StockLedger, SyncOperation
        from inventory.sync_service import apply_operation, Rejected
        shop = self.owned_shop()
        membership = ShopMembership.objects.create(user=self.other, shop=shop, role='ADMIN', status='APPROVED')
        request = RequestFactory().post('/', HTTP_X_ACTIVE_SHOP_ID=str(shop.pk))
        self.assertEqual(auth_bearer.authenticate(request, generate_token(self.other)), self.other)
        membership.role = 'WORKER'
        membership.save(update_fields=['role'])
        with self.assertRaises(Rejected) as rejected:
            apply_operation(shop, request.user, 'in-flight-phone', {
                'operation_id': 'after-role-change', 'kind': 'product', 'id': 'SKU',
                'base_revision': 0, 'data': {'code': 'SKU', 'name': '不能写入'},
            })
        self.assertEqual(rejected.exception.code, 'membership_revoked')
        for model in (Product, ShopSyncState, StockLedger, SyncOperation):
            self.assertFalse(model.objects.exists())

    def test_other_token_purpose_is_never_accepted_as_management(self):
        payload = {'user_id': str(self.owner.pk), 'token_type': 'worker', 'exp': timezone.now() + timedelta(days=1)}
        token = jwt.encode(payload, settings.SECRET_KEY, algorithm='HS256')
        self.assertEqual(self.client.get('/api/shops/my-shops', HTTP_AUTHORIZATION='Bearer ' + token).status_code, 401)

    def test_only_creator_can_approve_admin_and_roles_cannot_be_reintroduced(self):
        shop = self.owned_shop()
        admin_membership = ShopMembership.objects.create(user=self.other, shop=shop, role='ADMIN', status='APPROVED')
        third = CustomUser.objects.create_user(username='applicant', password='safe-password')
        pending = ShopMembership.objects.create(user=third, shop=shop, role='ADMIN', status='PENDING')
        admin_headers = {**self.other_headers, 'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)}
        self.assertEqual(self.post('shops/members/update', {'membership_id': str(pending.pk), 'status': 'APPROVED'}, admin_headers).status_code, 400)
        owner_headers = {**self.owner_headers, 'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)}
        for body in ({'membership_id': str(pending.pk), 'role': 'MEMBER'}, {'membership_id': str(pending.pk), 'role': 'WORKER'}, {'membership_id': str(admin_membership.pk), 'role': 'CREATOR'}):
            self.assertEqual(self.post('shops/members/update', body, owner_headers).status_code, 400)
        worker_user = CustomUser.objects.create_user(username='old-worker', password='safe-password')
        ShopMembership.objects.create(user=worker_user, shop=shop, role='WORKER', status='APPROVED')
        roles = {item['role'] for item in self.client.get('/api/shops/members', **owner_headers).json()}
        self.assertEqual(roles, {'CREATOR', 'ADMIN'})


class ShopNumberConcurrencyTests(TransactionTestCase):
    def test_parallel_shop_creation_has_distinct_monotonic_numbers(self):
        if connection.vendor != 'postgresql':
            self.skipTest('真实行锁分配验证需要隔离PostgreSQL。')
        ShopNumberSequence.objects.all().delete()
        barrier = Barrier(6)
        def create(index):
            close_old_connections()
            try:
                barrier.wait(timeout=15)
                return Shop.objects.create(name=f'并发店铺{index}').shop_number
            finally:
                connections.close_all()
        with ThreadPoolExecutor(max_workers=6) as pool:
            numbers = list(pool.map(create, range(6)))
        self.assertEqual(sorted(numbers), list(range(10000, 10006)))
        self.assertEqual(ShopNumberSequence.objects.get(pk=1).next_number, 10006)


class IdentityMigrationTests(TransactionTestCase):
    def test_existing_numbers_credentials_and_legacy_roles_are_preserved(self):
        executor = MigrationExecutor(connection)
        executor.migrate([('shops', '0002_customuser_phone'), ('inventory', '0006_alter_inboundreceipt_ocr_status')])
        old = executor.loader.project_state([('shops', '0002_customuser_phone'), ('inventory', '0006_alter_inboundreceipt_ocr_status')]).apps
        ShopOld = old.get_model('shops', 'Shop')
        UserOld = old.get_model('shops', 'CustomUser')
        MembershipOld = old.get_model('shops', 'ShopMembership')
        first = ShopOld.objects.create(name='旧店甲')
        second = ShopOld.objects.create(name='旧店乙')
        approved = UserOld.objects.create(username='approved', password='pbkdf2_sha256$legacy-hash', phone='13800000000', is_active=True)
        pending = UserOld.objects.create(username='pending', password='pbkdf2_sha256$other-hash', is_active=True)
        inactive = UserOld.objects.create(username='inactive', password='pbkdf2_sha256$inactive-hash', is_active=False)
        long_user = UserOld.objects.create(username='u' * 150, first_name='名' * 150, last_name='姓' * 150, password='pbkdf2_sha256$long-hash', is_active=True)
        for user, status in ((approved, 'APPROVED'), (pending, 'PENDING'), (inactive, 'APPROVED'), (long_user, 'APPROVED')):
            MembershipOld.objects.create(user=user, shop=first, role='MEMBER', status=status)
        MembershipOld.objects.create(user=approved, shop=second, role='MEMBER', status='APPROVED')
        executor = MigrationExecutor(connection)
        executor.migrate(executor.loader.graph.leaf_nodes())
        from jobs.models import WorkerAccount
        self.assertEqual((Shop.objects.get(pk=first.pk).shop_number, Shop.objects.get(pk=second.pk).shop_number), (10000, 10001))
        self.assertEqual(WorkerAccount.objects.filter(legacy_user_id=approved.pk).count(), 2)
        worker = WorkerAccount.objects.get(legacy_user_id=approved.pk, shop_id=first.pk)
        self.assertTrue(worker.is_active)
        self.assertEqual(worker.password, approved.password)
        self.assertEqual(worker.phone, '13800000000')
        self.assertFalse(WorkerAccount.objects.get(legacy_user_id=pending.pk).is_active)
        self.assertFalse(WorkerAccount.objects.get(legacy_user_id=inactive.pk).is_active)
        self.assertEqual(set(ShopMembership.objects.values_list('role', flat=True)), {'WORKER'})
        self.assertEqual(CustomUser.objects.count(), 4)
        migrated_long = WorkerAccount.objects.get(legacy_user_id=long_user.pk)
        self.assertEqual(migrated_long.username, 'u' * 150)
        self.assertEqual(len(migrated_long.display_name), 100)
        self.assertEqual(CustomUser.objects.get(pk=long_user.pk).first_name, '名' * 150)
        # 只回退角色迁移后再次迁移，不覆盖管理员后来重置的拍手密码。
        worker.password = 'changed-hash'
        worker.auth_version = 5
        worker.is_active = False
        worker.save()
        executor = MigrationExecutor(connection)
        executor.migrate([('shops', '0003_shop_number'), ('jobs', '0001_initial')])
        executor = MigrationExecutor(connection)
        executor.migrate(executor.loader.graph.leaf_nodes())
        worker.refresh_from_db()
        self.assertEqual((worker.password, worker.auth_version, worker.is_active), ('changed-hash', 5, False))
        self.assertEqual(Shop.objects.create(name='新店').shop_number, 10002)
