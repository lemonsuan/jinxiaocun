"""店铺拍手与作业资料独立保存，不授予库存成员身份。"""
import uuid
from django.conf import settings
from django.contrib.auth.hashers import check_password, make_password
from django.db import models
from django.db.models import Q


class WorkerAccount(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT, related_name='worker_accounts')
    username = models.CharField(max_length=150)
    password = models.CharField(max_length=128)
    display_name = models.CharField(max_length=100)
    phone = models.CharField(max_length=20, blank=True, default='')
    is_active = models.BooleanField(default=True)
    auth_version = models.PositiveIntegerField(default=1)
    legacy_user = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['shop', 'username'], name='worker_shop_username')]
        verbose_name = '店铺拍手'
        verbose_name_plural = '店铺拍手'

    def set_password(self, raw_password):
        self.password = make_password(raw_password)

    def check_password(self, raw_password):
        return check_password(raw_password, self.password)

    def __str__(self):
        return f'{self.display_name}（{self.username}）'


class Job(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT, related_name='jobs')
    title = models.CharField(max_length=150)
    description = models.TextField(blank=True, default='')
    cost_amount = models.DecimalField(max_digits=12, decimal_places=2)
    refund_amount = models.DecimalField(max_digits=12, decimal_places=2)
    status = models.CharField(max_length=10, choices=[('open', '开放'), ('closed', '已关闭')], default='open')
    version = models.PositiveIntegerField(default=1)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, on_delete=models.SET_NULL)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.CheckConstraint(condition=Q(cost_amount__gte=0) & Q(refund_amount__gte=0), name='job_amounts_nonnegative')]
        indexes = [models.Index(fields=['shop', 'status', '-created_at'])]
        verbose_name = '作业'
        verbose_name_plural = '作业'


class JobPhoto(models.Model):
    job = models.ForeignKey(Job, on_delete=models.PROTECT, related_name='photos')
    media = models.ForeignKey('inventory.PrivateMedia', on_delete=models.PROTECT)
    position = models.PositiveIntegerField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=['job', 'position'], name='job_photo_position'), models.UniqueConstraint(fields=['job', 'media'], name='job_photo_media')]
        ordering = ['position', 'id']


class JobOrder(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT)
    job = models.ForeignKey(Job, on_delete=models.PROTECT, related_name='orders')
    worker = models.ForeignKey(WorkerAccount, on_delete=models.PROTECT, related_name='orders')
    order_number = models.CharField(max_length=100)
    version = models.PositiveIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['job', 'worker', 'order_number'], name='worker_job_order_number')]
        indexes = [models.Index(fields=['shop', '-updated_at']), models.Index(fields=['worker', '-updated_at'])]


class JobParcel(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT)
    order = models.ForeignKey(JobOrder, on_delete=models.PROTECT, related_name='parcels')
    tracking_number = models.CharField(max_length=100)
    position = models.PositiveIntegerField()
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    retired_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['order', 'tracking_number'], condition=Q(is_active=True), name='active_order_tracking')]
        indexes = [models.Index(fields=['shop', 'tracking_number', 'is_active'])]
        ordering = ['position', 'id']


class Settlement(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT)
    order = models.ForeignKey(JobOrder, on_delete=models.PROTECT, related_name='settlements')
    cost_amount = models.DecimalField(max_digits=12, decimal_places=2)
    refund_amount = models.DecimalField(max_digits=12, decimal_places=2)
    snapshot = models.JSONField()
    operator = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, on_delete=models.SET_NULL, related_name='job_settlements')
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    reopened_at = models.DateTimeField(null=True, blank=True)
    reopened_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.SET_NULL, related_name='reopened_job_settlements')
    reopen_reason = models.CharField(max_length=1000, blank=True, default='')

    class Meta:
        constraints = [models.UniqueConstraint(fields=['order'], condition=Q(is_active=True), name='one_active_order_settlement')]


class JobAudit(models.Model):
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT)
    job = models.ForeignKey(Job, null=True, on_delete=models.PROTECT)
    order = models.ForeignKey(JobOrder, null=True, on_delete=models.PROTECT)
    worker = models.ForeignKey(WorkerAccount, null=True, on_delete=models.PROTECT)
    operator = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, on_delete=models.SET_NULL)
    action = models.CharField(max_length=40)
    detail = models.JSONField(default=dict)
    created_at = models.DateTimeField(auto_now_add=True)


class OperationReceipt(models.Model):
    shop = models.ForeignKey('shops.Shop', on_delete=models.PROTECT)
    actor_key = models.CharField(max_length=80)
    operation_id = models.CharField(max_length=100)
    request_hash = models.CharField(max_length=64)
    order = models.ForeignKey(JobOrder, on_delete=models.PROTECT)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=['shop', 'actor_key', 'operation_id'], name='job_actor_operation')]
