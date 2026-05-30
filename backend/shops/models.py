import uuid
from django.db import models
from django.contrib.auth.models import AbstractUser

class CustomUser(AbstractUser):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    phone = models.CharField(max_length=20, blank=True, default="", verbose_name="手机号")

    def __str__(self):
        return self.username

class Shop(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(max_length=100, verbose_name="店铺名称")
    created_at = models.DateTimeField(auto_now_add=True, verbose_name="创建时间")

    class Meta:
        verbose_name = "店铺"
        verbose_name_plural = "店铺"

    def __str__(self):
        return self.name

class ShopMembership(models.Model):
    ROLE_CHOICES = [
        ('CREATOR', '创建人'),
        ('ADMIN', '管理员'),
        ('MEMBER', '普通成员'),
    ]
    STATUS_CHOICES = [
        ('PENDING', '待确认'),
        ('APPROVED', '已加入'),
        ('REJECTED', '已拒绝'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.ForeignKey(CustomUser, on_delete=models.CASCADE, related_name='memberships', verbose_name="用户")
    shop = models.ForeignKey(Shop, on_delete=models.CASCADE, related_name='memberships', verbose_name="店铺")
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default='MEMBER', verbose_name="角色")
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default='PENDING', verbose_name="状态")
    joined_at = models.DateTimeField(auto_now_add=True, verbose_name="申请/加入时间")

    class Meta:
        verbose_name = "店铺成员关系"
        verbose_name_plural = "店铺成员关系"
        unique_together = ('user', 'shop')

    def __str__(self):
        return f"{self.user.username} @ {self.shop.name} ({self.get_role_display()} - {self.get_status_display()})"
