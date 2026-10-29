"""本人补充图片、收款资料与结算历史的隔离回归。"""
import io
import json
import uuid
from unittest.mock import patch
from PIL import Image
from django.core.files.uploadedfile import SimpleUploadedFile
from django.db import connection
from django.test import TestCase, TransactionTestCase
from . import tests as legacy
from .models import JobAudit, JobOrder, JobParcel, Settlement, WorkerMediaUpload, WorkerPayoutProfile


class PayoutTests(TestCase):
    setUp = legacy.JobsTests.setUp
    post = legacy.JobsTests.post
    get = legacy.JobsTests.get
    register = legacy.JobsTests.register
    create_job = legacy.JobsTests.create_job
    order = legacy.JobsTests.order
    receipt = legacy.JobsTests.receipt
    detail = legacy.JobsTests.detail
    settle_payload = legacy.JobsTests.settle_payload

    def upload(self, purpose='order', headers=None, color='red', filename='proof.png'):
        data = io.BytesIO()
        Image.new('RGB', (15, 12), color).save(data, format='PNG')
        response = self.client.post('/api/worker/media', {'purpose': purpose,
            'file': SimpleUploadedFile(filename, data.getvalue(), content_type='image/png')}, **(headers or self.headers))
        self.assertEqual(response.status_code, 200, response.content)
        return response.json()

    def payout(self, **overrides):
        body = {'wechat': 'worker-wechat', 'alipay_phone': '+86 138-0000-0000', 'alipay_name': '验收拍手',
                'qr_sha256': None, 'expected_version': 0, 'operation_id': 'payout-first'}
        body.update(overrides)
        return body

    def test_payout_defaults_partial_save_idempotency_and_validation(self):
        empty = self.get('/worker/payout', self.headers).json()
        self.assertEqual(empty, {'wechat': '', 'alipay_phone': '', 'alipay_name': '',
                                'qr_sha256': None, 'version': 0, 'updated_at': None})
        body = self.payout(alipay_name='', alipay_phone='')
        response = self.post('/worker/payout', body, self.headers, 'patch')
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['version'], 1)
        self.assertEqual(self.post('/worker/payout', body, self.headers, 'patch').status_code, 200)
        self.assertEqual(WorkerPayoutProfile.objects.get().version, 1)
        self.assertEqual(JobAudit.objects.filter(action='WORKER_PAYOUT_UPDATED').count(), 1)
        self.worker.refresh_from_db()
        self.assertEqual(self.worker.auth_version, 1)
        self.assertEqual(self.get('/worker/me', self.headers).status_code, 200)
        self.assertEqual(self.post('/worker/payout', {**body, 'wechat': 'changed'}, self.headers, 'patch').status_code, 409)
        self.assertEqual(self.post('/worker/payout', {**body, 'operation_id': 'stale'}, self.headers, 'patch').status_code, 409)
        invalid = self.payout(alipay_phone='not-a-phone', expected_version=1, operation_id='invalid')
        self.assertEqual(self.post('/worker/payout', invalid, self.headers, 'patch').status_code, 422)
        invalid = self.payout(wechat='a\x00b', expected_version=1, operation_id='control')
        self.assertEqual(self.post('/worker/payout', invalid, self.headers, 'patch').status_code, 422)
        self.assertEqual(self.get('/worker/payout', self.second_headers).json()['version'], 0)
        self.assertEqual(self.get('/worker/payout', self.admin_headers).status_code, 401)
        self.assertEqual(self.client.get('/api/worker/payout').status_code, 401)

    def test_media_is_owner_scoped_and_purpose_scoped(self):
        photo = self.upload()
        read = self.get('/worker/media/' + photo['sha256'], self.headers)
        self.assertEqual(read.status_code, 200)
        self.assertEqual(read['Cache-Control'], 'private, no-store')
        # 消费流让测试客户端释放响应，避免直接close触发关闭外层测试事务连接。
        self.assertTrue(b''.join(read.streaming_content))
        self.assertEqual(self.get('/worker/media/' + photo['sha256'], self.second_headers).status_code, 404)
        self.assertEqual(self.client.get('/api/worker/media/' + photo['sha256']).status_code, 401)
        wrong_purpose = self.payout(qr_sha256=photo['sha256'])
        self.assertEqual(self.post('/worker/payout', wrong_purpose, self.headers, 'patch').status_code, 400)
        code = self.upload('payout', color='blue')
        body = self.payout(qr_sha256=code['sha256'])
        self.assertEqual(self.post('/worker/payout', body, self.second_headers, 'patch').status_code, 400)
        self.assertEqual(self.post('/worker/payout', body, self.headers, 'patch').status_code, 200)
        order_body = {'job_id': self.job['id'], 'order_number': 'MEDIA', 'tracking_numbers': ['TRACK'],
                      'operation_id': 'media-order', 'photo_sha256s': [code['sha256']]}
        self.assertEqual(self.post('/worker/orders', order_body, self.headers).status_code, 400)
        order_body['photo_sha256s'] = [photo['sha256']]
        self.assertEqual(self.post('/worker/orders', order_body, self.second_headers).status_code, 400)
        # 同一内容由另一个拍手本人重新上传后，才拥有自己的使用权限。
        self.upload(headers=self.second_headers)
        self.assertEqual(self.post('/worker/orders', order_body, self.second_headers).status_code, 200)

    def test_cross_shop_and_disabled_workers_cannot_read_or_bind_payout_media(self):
        code = self.upload('payout')
        outsider, outsider_headers = self.register('outsider', self.other_shop)
        self.assertEqual(self.get('/worker/media/' + code['sha256'], outsider_headers).status_code, 404)
        self.assertEqual(self.post('/worker/payout', self.payout(qr_sha256=code['sha256']),
                                   outsider_headers, 'patch').status_code, 400)
        self.assertEqual(self.get('/worker/payout', outsider_headers).json()['version'], 0)
        self.worker.is_active = False
        self.worker.auth_version += 1
        self.worker.save()
        for endpoint in ['/worker/payout', '/worker/orders/summary', '/worker/media/' + code['sha256']]:
            self.assertEqual(self.get(endpoint, self.headers).status_code, 403)
        self.assertEqual(self.post('/worker/payout', self.payout(), self.headers, 'patch').status_code, 403)
        self.assertEqual(WorkerPayoutProfile.objects.count(), 0)

    def test_upload_rejects_bad_image_oversize_and_invalid_purpose(self):
        for purpose, content, expected in [('order', b'not-image', 400), ('wrong', b'not-image', 422)]:
            response = self.client.post('/api/worker/media', {'purpose': purpose,
                'file': SimpleUploadedFile('bad.png', content)}, **self.headers)
            self.assertEqual(response.status_code, expected, response.content)
        with patch('jobs.api.MAX_IMAGE_BYTES', 10):
            response = self.client.post('/api/worker/media', {'purpose': 'order',
                'file': SimpleUploadedFile('large.png', b'x' * 11)}, **self.headers)
            self.assertEqual(response.status_code, 413)
        self.assertEqual(WorkerMediaUpload.objects.count(), 0)

    def test_order_note_photo_patch_omission_clear_and_ownership(self):
        photo = self.upload(filename='supplement.png')
        body = {'job_id': self.job['id'], 'order_number': 'SUPPLEMENT', 'tracking_numbers': ['A'],
                'operation_id': 'supp-create', 'note': '补充说明\n第二行',
                'photo_sha256s': [photo['sha256'], photo['sha256']]}
        response = self.post('/worker/orders', body, self.headers)
        self.assertEqual(response.status_code, 200, response.content)
        order = response.json()
        self.assertEqual(order['note'], body['note'])
        self.assertEqual(order['photos'], [{'sha256': photo['sha256'], 'name': 'supplement.png'}])
        self.assertNotIn('products', order)
        self.assertNotIn('payout', order)
        self.assertEqual(self.detail(order)['photos'], order['photos'])
        edit = {'order_number': 'SUPPLEMENT', 'tracking_numbers': ['A', 'B'],
                'expected_version': order['version'], 'operation_id': 'legacy-patch'}
        response = self.post('/worker/orders/' + order['id'], edit, self.headers, 'patch')
        self.assertEqual(response.status_code, 200, response.content)
        self.assertEqual(response.json()['note'], body['note'])
        self.assertEqual(response.json()['photos'], order['photos'])
        edit.update(expected_version=response.json()['version'], operation_id='clear', note='', photo_sha256s=[])
        cleared = self.post('/worker/orders/' + order['id'], edit, self.headers, 'patch')
        self.assertEqual(cleared.status_code, 200, cleared.content)
        self.assertEqual((cleared.json()['note'], cleared.json()['photos']), ('', []))
        self.assertTrue(WorkerMediaUpload.objects.filter(media__sha256=photo['sha256']).exists())
        for extras in [{'note': 'a' * 2001}, {'note': 'a\x00b'}, {'photo_sha256s': [str(i).zfill(64) for i in range(11)]}]:
            invalid = {**body, **extras, 'order_number': str(uuid.uuid4()), 'operation_id': str(uuid.uuid4())}
            self.assertEqual(self.post('/worker/orders', invalid, self.headers).status_code, 422)

    def test_settlement_freezes_payout_and_supplement_and_retries_after_changes(self):
        photo = self.upload()
        code = self.upload('payout', color='blue')
        first = self.post('/worker/payout', self.payout(qr_sha256=code['sha256']), self.headers, 'patch').json()
        body = {'job_id': self.job['id'], 'order_number': 'FROZEN', 'tracking_numbers': ['DELIVERED'],
                'operation_id': 'frozen-order', 'note': '原文字', 'photo_sha256s': [photo['sha256']]}
        order = self.post('/worker/orders', body, self.headers).json()
        self.receipt('DELIVERED')
        pending = self.order(['LATER'], name='PENDING')
        self.assertEqual(self.detail(order)['payout']['version'], first['version'])
        payload = {**self.settle_payload(order), 'expected_payout_version': first['version']}
        response = self.post('/jobs/orders/' + order['id'] + '/settle', payload)
        self.assertEqual(response.status_code, 200, response.content)
        changed_code = self.upload('payout', color='green')
        changed = self.payout(wechat='new-wechat', alipay_phone='13900000000', alipay_name='新姓名',
                             qr_sha256=changed_code['sha256'], expected_version=1, operation_id='payout-second')
        self.assertEqual(self.post('/worker/payout', changed, self.headers, 'patch').status_code, 200)
        detail = self.detail(order)
        self.assertTrue(detail['payout_is_snapshot'])
        self.assertEqual(detail['payout']['qr_sha256'], code['sha256'])
        self.assertEqual(detail['payout']['alipay_name'], '验收拍手')
        self.assertEqual(self.detail(pending)['payout']['alipay_name'], '新姓名')
        self.assertFalse(self.detail(pending)['payout_is_snapshot'])
        snapshot = Settlement.objects.get().snapshot
        self.assertEqual(snapshot['note'], '原文字')
        self.assertEqual(snapshot['photos'], order['photos'])
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', payload).status_code, 200)
        edit = {'order_number': 'FROZEN', 'tracking_numbers': ['DELIVERED'], 'note': '覆盖',
                'photo_sha256s': [], 'expected_version': response.json()['version'], 'operation_id': 'locked'}
        self.assertEqual(self.post('/worker/orders/' + order['id'], edit, self.headers, 'patch').status_code, 409)
        self.assertEqual(self.get('/jobs/orders/' + order['id'], self.other_headers).status_code, 404)

    def test_payout_version_must_be_rechecked_for_settlement(self):
        order = self.order(['ARRIVED'])
        self.receipt('ARRIVED')
        payload = self.settle_payload(order)
        self.post('/worker/payout', self.payout(), self.headers, 'patch')
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', payload).status_code, 409)
        self.assertEqual(self.post('/jobs/orders/' + order['id'] + '/settle', {**payload, 'expected_payout_version': 0}).status_code, 409)
        response = self.post('/jobs/orders/' + order['id'] + '/settle', {**payload, 'expected_payout_version': 1})
        self.assertEqual(response.status_code, 200, response.content)

    def test_old_settlement_without_payout_does_not_show_new_profile(self):
        order = self.order(['ARRIVED'])
        self.receipt('ARRIVED')
        response = self.post('/jobs/orders/' + order['id'] + '/settle', self.settle_payload(order))
        self.assertEqual(response.status_code, 200, response.content)
        settlement = Settlement.objects.get()
        snapshot = settlement.snapshot
        snapshot.pop('payout')
        settlement.snapshot = snapshot
        settlement.save()
        self.post('/worker/payout', self.payout(), self.headers, 'patch')
        detail = self.detail(order)
        self.assertIsNone(detail['payout'])
        self.assertTrue(detail['payout_is_snapshot'])

    def test_summary_is_whole_personal_scope_not_page(self):
        self.order(['PARTIAL-A', 'PARTIAL-B'], name='PARTIAL')
        self.receipt('PARTIAL-A')
        arrived = self.order(['ALL'], name='ARRIVED')
        self.receipt('ALL')
        settled = self.order(['PAID'], name='PAID')
        self.receipt('PAID')
        self.post('/jobs/orders/' + settled['id'] + '/settle', self.settle_payload(settled))
        for i in range(21):
            self.order([f'TRANSIT-{i}'], name=f'TRANSIT-{i}')
        self.order(['OTHER'], name='OTHER', headers=self.second_headers)
        summary = self.get('/worker/orders/summary', self.headers)
        self.assertEqual(summary.status_code, 200, summary.content)
        self.assertEqual(summary.json(), {'in_transit': 22, 'arrived': 1, 'total': 24})
        self.assertEqual(self.get('/worker/orders', self.headers, page_size=1).json()['total'], 24)
        self.assertEqual(self.get('/worker/orders/summary', self.second_headers).json()['total'], 1)

    def test_old_request_hash_is_compatible_after_optional_fields_added(self):
        from .schemas import OrderCreate, Settle
        from .services import operation_hash
        import hashlib
        values = {'job_id': self.job['id'], 'order_number': 'LEGACY', 'tracking_numbers': ['TRACK'], 'operation_id': 'legacy'}
        expected = hashlib.sha256(json.dumps({'action': 'create_order', 'data': values}, sort_keys=True,
                                            ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
        self.assertEqual(operation_hash('create_order', OrderCreate.model_validate(values)), expected)
        explicit = OrderCreate.model_validate({**values, 'note': '', 'photo_sha256s': []})
        self.assertNotEqual(operation_hash('create_order', explicit), expected)


class PayoutConcurrencyTests(TransactionTestCase):
    race = legacy.JobConcurrencyTests.race

    def setUp(self):
        legacy.JobConcurrencyTests.setUp(self)
        WorkerPayoutProfile.objects.create(worker=self.worker, version=1, alipay_name='旧姓名')
        self.payload['expected_payout_version'] = 1

    def profile_payload(self, operation='profile-new', name='新姓名'):
        return {'wechat': '', 'alipay_phone': '', 'alipay_name': name, 'qr_sha256': None,
                'expected_version': 1, 'operation_id': operation}

    def test_profile_change_and_settlement_keep_confirmed_payout(self):
        results = self.race([('/worker/payout', self.profile_payload(), self.worker_headers, 'patch'),
            ('/jobs/orders/' + str(self.order.pk) + '/settle', self.payload, self.admin_headers, 'post')])
        self.assertEqual(results[0][0], 200, results)
        self.assertIn(results[1][0], [200, 409], results)
        settlement = Settlement.objects.first()
        if settlement:
            self.assertEqual(settlement.snapshot['payout']['alipay_name'], '旧姓名')
            self.assertEqual(settlement.snapshot['payout']['version'], 1)
        self.assertEqual(WorkerPayoutProfile.objects.get().version, 2)

    def test_same_profile_retry_is_once(self):
        payload = self.profile_payload()
        results = self.race([('/worker/payout', payload, self.worker_headers, 'patch')] * 2)
        self.assertEqual([r[0] for r in results], [200, 200], results)
        self.assertEqual(WorkerPayoutProfile.objects.get().version, 2)
        self.assertEqual(JobAudit.objects.filter(action='WORKER_PAYOUT_UPDATED').count(), 1)

    def test_stale_concurrent_profile_changes_have_one_winner(self):
        results = self.race([('/worker/payout', self.profile_payload('one', '一'), self.worker_headers, 'patch'),
            ('/worker/payout', self.profile_payload('two', '二'), self.worker_headers, 'patch')])
        self.assertEqual(sorted(r[0] for r in results), [200, 409], results)
        self.assertEqual(WorkerPayoutProfile.objects.get().version, 2)

    def test_disable_and_profile_change_recheck_live_worker(self):
        results = self.race([('/jobs/workers/' + str(self.worker.pk) + '/enabled',
            {'expected_version': 1, 'enabled': False}, self.admin_headers, 'post'),
            ('/worker/payout', self.profile_payload(), self.worker_headers, 'patch')])
        self.assertEqual(results[0][0], 200, results)
        self.assertIn(results[1][0], [200, 403], results)
        profile = WorkerPayoutProfile.objects.get()
        self.assertEqual(profile.version, 2 if results[1][0] == 200 else 1)
        self.worker.refresh_from_db()
        self.assertFalse(self.worker.is_active)
