"""演示种子只追加、按真实流程生成状态且重跑不覆盖用户编辑。"""
import tempfile

from django.test import TestCase, override_settings
from inventory.models import InboundReceipt
from jobs.models import Job, JobOrder, Settlement, WorkerAccount, WorkerPayoutProfile
from shops.models import CustomUser, Shop, ShopMembership
from seed_jobs_demo import DEMO_SHOP_NAME, PREFIX, seed


class DemoSeedTests(TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.override = override_settings(PRIVATE_MEDIA_ROOT=self.directory.name)
        self.override.enable()
        self.addCleanup(self.override.disable)
        self.admin = CustomUser.objects.create_user(username='seed-owner', password='test-password')
        self.shop = Shop.objects.create(name=DEMO_SHOP_NAME)
        ShopMembership.objects.create(shop=self.shop, user=self.admin, role='CREATOR', status='APPROVED')

    def test_normal_api_states_and_repeat_does_not_duplicate_or_overwrite(self):
        first = seed(self.shop.shop_number, self.admin.username)
        self.assertEqual((Job.objects.count(), JobOrder.objects.count(), WorkerAccount.objects.count()), (3, 8, 2))
        self.assertEqual(InboundReceipt.objects.count(), 7)
        self.assertEqual(Settlement.objects.count(), 1)
        self.assertEqual(first['summaries'], [{'total': 6, 'in_transit': 4, 'arrived': 1},
                                            {'total': 2, 'in_transit': 1, 'arrived': 1}])
        settlement = Settlement.objects.get()
        self.assertEqual(settlement.snapshot['payout']['wechat'], 'demo_wechat_a')
        profile = WorkerPayoutProfile.objects.get(worker__username='ux20261029_a')
        self.assertEqual(profile.wechat, 'demo_wechat_a_new')
        order = JobOrder.objects.get(order_number=PREFIX + '-A001')
        order.note = '验收者已改动，请保留'
        order.save(update_fields=['note'])
        seed(self.shop.shop_number, self.admin.username)
        self.assertEqual((Job.objects.count(), JobOrder.objects.count(), InboundReceipt.objects.count(), Settlement.objects.count()), (3, 8, 7, 1))
        order.refresh_from_db()
        self.assertEqual(order.note, '验收者已改动，请保留')

    def test_refuses_non_demo_shop_and_non_manager(self):
        self.shop.name = '真实业务店'
        self.shop.save()
        with self.assertRaisesRegex(ValueError, '专用演示店'):
            seed(self.shop.shop_number, self.admin.username)
        self.shop.name = DEMO_SHOP_NAME
        self.shop.save()
        ShopMembership.objects.filter(shop=self.shop).update(status='REJECTED')
        with self.assertRaisesRegex(ValueError, '管理资格'):
            seed(self.shop.shop_number, self.admin.username)
        self.assertEqual(JobOrder.objects.count(), 0)
