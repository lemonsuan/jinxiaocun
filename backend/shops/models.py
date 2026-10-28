import uuid

from django.contrib.auth.models import AbstractUser
from django.core.exceptions import ValidationError
from django.db import models, router, transaction


class CustomUser(AbstractUser):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    phone = models.CharField(max_length=20, blank=True, default='', verbose_name='手机号')

    def __str__(self):
        return self.username


class ShopNumberSequence(models.Model):
    """编号计数行独立于店铺，删除店铺也不会回收已分配的数字。"""

    id = models.PositiveSmallIntegerField(primary_key=True, default=1, editable=False)
    next_number = models.PositiveBigIntegerField(default=10000, editable=False)

    class Meta:
        verbose_name = '店铺编号计数器'
        verbose_name_plural = verbose_name
        constraints = [
            models.CheckConstraint(condition=models.Q(id=1), name='shop_number_single_counter'),
            models.CheckConstraint(condition=models.Q(next_number__gte=10000), name='shop_number_counter_floor'),
        ]


class Shop(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop_number = models.PositiveBigIntegerField(unique=True, editable=False, verbose_name='店铺ID')
    name = models.CharField(max_length=100, verbose_name='店铺名称')
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='创建时间')

    class Meta:
        verbose_name = '店铺'
        verbose_name_plural = '店铺'
        constraints = [
            models.CheckConstraint(condition=models.Q(shop_number__gte=10000), name='shop_number_minimum'),
        ]

    def save(self, *args, **kwargs):
        database = kwargs.get('using') or router.db_for_write(type(self), instance=self)
        if not self._state.adding:
            original = type(self).objects.using(database).filter(pk=self.pk).values_list('shop_number', flat=True).first()
            if original is not None and self.shop_number != original:
                raise ValidationError('店铺ID一经分配不可修改。')
            return super().save(*args, **kwargs)
        with transaction.atomic(using=database):
            # 行锁串行分配，首次初始化也由唯一主键解决并发竞争。
            sequence, _ = ShopNumberSequence.objects.using(database).select_for_update().get_or_create(pk=1)
            if self.shop_number is None:
                self.shop_number = sequence.next_number
            if isinstance(self.shop_number, bool) or not isinstance(self.shop_number, int) or self.shop_number < 10000:
                raise ValidationError('店铺ID必须是10000起的数字。')
            if self.shop_number >= 9223372036854775807:
                raise ValidationError('店铺编号已超出可分配范围。')
            sequence.next_number = max(sequence.next_number, self.shop_number + 1)
            sequence.save(using=database, update_fields=['next_number'])
            return super().save(*args, **kwargs)

    def __str__(self):
        return f'{self.name}（{self.shop_number}）'


class ShopMembership(models.Model):
    ROLE_CHOICES = [
        ('CREATOR', '创建人'),
        ('ADMIN', '管理员'),
        ('WORKER', '拍手'),
    ]
    STATUS_CHOICES = [
        ('PENDING', '待确认'),
        ('APPROVED', '已加入'),
        ('REJECTED', '已拒绝'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(CustomUser, on_delete=models.CASCADE, related_name='memberships', verbose_name='用户')
    shop = models.ForeignKey(Shop, on_delete=models.CASCADE, related_name='memberships', verbose_name='店铺')
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default='WORKER', verbose_name='角色')
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='PENDING', verbose_name='状态')
    joined_at = models.DateTimeField(auto_now_add=True, verbose_name='申请/加入时间')

    class Meta:
        verbose_name = '店铺成员关系'
        verbose_name_plural = '店铺成员关系'
        unique_together = ('user', 'shop')

    def __str__(self):
        return f'{self.user.username} @ {self.shop.name} ({self.get_role_display()} - {self.get_status_display()})'
