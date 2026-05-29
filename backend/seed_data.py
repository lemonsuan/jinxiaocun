import os
import django
import datetime
from django.utils import timezone

# 配置 Django 环境
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'shop_sync_backend.settings')
django.setup()

from shops.models import CustomUser, Shop, ShopMembership
from inventory.models import Product, InboundReceipt, InboundItem, OutboundOrder, OutboundItem, StockLedger, WarehouseStock

def seed():
    print("Starting database seeding...")
    
    # 1. 创建店铺
    shop1, _ = Shop.objects.get_or_create(
        name="雅诗兰黛官方旗舰店"
    )
    shop2, _ = Shop.objects.get_or_create(
        name="科颜氏自营免税店"
    )
    
    # 获取我们的超级管理员
    admin_user = CustomUser.objects.filter(username='admin').first()
    if admin_user:
        # 将超级管理员绑定为 shop1 的创建者
        ShopMembership.objects.get_or_create(
            user=admin_user,
            shop=shop1,
            defaults={'role': 'CREATOR', 'status': 'APPROVED'}
        )
    
    # 2. 创建普通店员和管理员用户
    user_member, member_created = CustomUser.objects.get_or_create(username='member1')
    if member_created:
        user_member.set_password('member123')
        user_member.is_staff = True
        user_member.save()
        
    user_admin, admin_created = CustomUser.objects.get_or_create(username='shop_admin1')
    if admin_created:
        user_admin.set_password('admin123')
        user_admin.is_staff = True
        user_admin.save()
        
    user_pending, pending_created = CustomUser.objects.get_or_create(username='applicant1')
    if pending_created:
        user_pending.set_password('applicant123')
        user_pending.is_staff = True
        user_pending.save()

    # 3. 创建成员关系
    # user_member 是 shop1 的 APPROVED MEMBER
    ShopMembership.objects.get_or_create(
        user=user_member,
        shop=shop1,
        defaults={'role': 'MEMBER', 'status': 'APPROVED'}
    )
    # user_admin 是 shop1 的 APPROVED ADMIN
    ShopMembership.objects.get_or_create(
        user=user_admin,
        shop=shop1,
        defaults={'role': 'ADMIN', 'status': 'APPROVED'}
    )
    # user_pending 申请加入 shop1，状态为 PENDING
    ShopMembership.objects.get_or_create(
        user=user_pending,
        shop=shop1,
        defaults={'role': 'MEMBER', 'status': 'PENDING'}
    )
    
    # 4. 创建商品数据 (shop1)
    p1, _ = Product.objects.update_or_create(
        code="ESTEE-ANR-50",
        shop=shop1,
        defaults={
            "name": "雅诗兰黛特润修护肌活精华露 (小棕瓶) 50ml",
            "default_purchase_price": 420.00,
            "default_sale_price": 850.00
        }
    )
    p2, _ = Product.objects.update_or_create(
        code="ESTEE-EYE-15",
        shop=shop1,
        defaults={
            "name": "雅诗兰黛特润修护肌透精华眼霜 15ml",
            "default_purchase_price": 280.00,
            "default_sale_price": 540.00
        }
    )
    
    # 5. 创建商品数据 (shop2)
    p3, _ = Product.objects.update_or_create(
        code="KIEHLS-ULTRA-125",
        shop=shop2,
        defaults={
            "name": "科颜氏高保湿霜 125ml",
            "default_purchase_price": 190.00,
            "default_sale_price": 350.00
        }
    )

    # 6. 录入入库单 (shop1)
    receipt, _ = InboundReceipt.objects.update_or_create(
        tracking_number="SF168493019482",
        shop=shop1,
        defaults={
            "seller_order_number": "ORDER-2026-90184",
            "scheme_number": "PLAN-8820",
            "ocr_status": "confirmed",
            "is_settled": True,
            "created_at": timezone.now() - datetime.timedelta(days=1)
        }
    )
    
    InboundItem.objects.update_or_create(
        receipt=receipt,
        product_code=p1.code,
        shop=shop1,
        defaults={
            "product_name": p1.name,
            "quantity": 100,
            "purchase_price": 415.00,
            "sale_price": 850.00
        }
    )
    InboundItem.objects.update_or_create(
        receipt=receipt,
        product_code=p2.code,
        shop=shop1,
        defaults={
            "product_name": p2.name,
            "quantity": 50,
            "purchase_price": 275.00,
            "sale_price": 540.00
        }
    )
    
    # 7. 写入对应的库存和流水
    WarehouseStock.objects.update_or_create(
        shop=shop1,
        product_code=p1.code,
        defaults={"product_name": p1.name, "quantity": 100}
    )
    WarehouseStock.objects.update_or_create(
        shop=shop1,
        product_code=p2.code,
        defaults={"product_name": p2.name, "quantity": 50}
    )
    
    StockLedger.objects.update_or_create(
        shop=shop1,
        product_code=p1.code,
        source_id=str(receipt.id),
        defaults={
            "product_name": p1.name,
            "delta": 100,
            "reason": "inbound",
            "created_at": timezone.now() - datetime.timedelta(days=1)
        }
    )
    StockLedger.objects.update_or_create(
        shop=shop1,
        product_code=p2.code,
        source_id=str(receipt.id),
        defaults={
            "product_name": p2.name,
            "delta": 50,
            "reason": "inbound",
            "created_at": timezone.now() - datetime.timedelta(days=1)
        }
    )
    
    print("Database seeding completed successfully!")

if __name__ == '__main__':
    seed()
