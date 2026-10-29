"""独立检查资料事务回滚与撤销结算后的历史不可变性。"""
from django.test import TestCase

from . import tests as legacy
from . import test_payout as payout_cases
from .models import JobAudit, Settlement, WorkerPayoutProfile


class PayoutReviewTests(TestCase):
    setUp = legacy.JobsTests.setUp
    post = legacy.JobsTests.post
    get = legacy.JobsTests.get
    register = legacy.JobsTests.register
    create_job = legacy.JobsTests.create_job
    order = legacy.JobsTests.order
    receipt = legacy.JobsTests.receipt
    detail = legacy.JobsTests.detail
    settle_payload = legacy.JobsTests.settle_payload
    upload = payout_cases.PayoutTests.upload
    payout = payout_cases.PayoutTests.payout

    def test_rejected_first_profile_rolls_back_before_valid_first_save(self):
        other_code = self.upload('payout', headers=self.second_headers)
        denied = self.post('/worker/payout', self.payout(qr_sha256=other_code['sha256']),
                           self.headers, 'patch')
        self.assertEqual(denied.status_code, 400, denied.content)
        self.assertFalse(WorkerPayoutProfile.objects.filter(worker=self.worker).exists())
        self.assertFalse(JobAudit.objects.filter(action='WORKER_PAYOUT_UPDATED').exists())
        valid = self.post('/worker/payout', self.payout(), self.headers, 'patch')
        self.assertEqual(valid.status_code, 200, valid.content)
        self.assertEqual(valid.json()['version'], 1)
        self.worker.refresh_from_db()
        self.assertEqual(self.worker.auth_version, 1)

    def test_reopen_then_edit_keeps_original_supplement_and_payout_history(self):
        first_photo = self.upload(color='red')
        first_code = self.upload('payout', color='blue')
        self.post('/worker/payout', self.payout(qr_sha256=first_code['sha256']), self.headers, 'patch')
        created = self.post('/worker/orders', {'job_id': self.job['id'], 'order_number': 'HISTORY',
            'tracking_numbers': ['HISTORY-TRACK'], 'note': '原始补充',
            'photo_sha256s': [first_photo['sha256']], 'operation_id': 'review-create'}, self.headers)
        self.assertEqual(created.status_code, 200, created.content)
        order = created.json()
        self.receipt('HISTORY-TRACK')
        settled = self.post('/jobs/orders/' + order['id'] + '/settle',
            {**self.settle_payload(order), 'expected_payout_version': 1})
        self.assertEqual(settled.status_code, 200, settled.content)
        original = Settlement.objects.get().snapshot
        reopened = self.post('/jobs/orders/' + order['id'] + '/reopen', {
            'expected_version': settled.json()['version'], 'operation_id': 'review-reopen', 'reason': '演示核对修正'})
        self.assertEqual(reopened.status_code, 200, reopened.content)
        second_photo = self.upload(color='green')
        changed = self.post('/worker/orders/' + order['id'], {
            'order_number': 'HISTORY-EDITED', 'tracking_numbers': ['HISTORY-TRACK'], 'note': '修改后补充',
            'photo_sha256s': [second_photo['sha256']], 'expected_version': reopened.json()['version'],
            'operation_id': 'review-edit'}, self.headers, 'patch')
        self.assertEqual(changed.status_code, 200, changed.content)
        payout = self.post('/worker/payout', self.payout(alipay_name='新姓名', expected_version=1,
            operation_id='review-payout-new'), self.headers, 'patch')
        self.assertEqual(payout.status_code, 200, payout.content)
        detail = self.detail(order)
        self.assertFalse(detail['payout_is_snapshot'])
        self.assertEqual(detail['payout']['alipay_name'], '新姓名')
        self.assertEqual(detail['note'], '修改后补充')
        history = detail['settlement_history'][0]
        self.assertFalse(history['is_active'])
        self.assertEqual(history['snapshot'], original)
        self.assertEqual(history['snapshot']['note'], '原始补充')
        self.assertEqual(history['snapshot']['payout']['qr_sha256'], first_code['sha256'])
        self.assertEqual(history['snapshot']['photos'][0]['sha256'], first_photo['sha256'])
