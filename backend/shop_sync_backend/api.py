import jwt
import datetime
from django.conf import settings
from django.contrib.auth import authenticate
from ninja import NinjaAPI, Schema
from ninja.security import HttpBearer
from ninja.errors import HttpError
from typing import List, Optional
from uuid import UUID

from shops.models import CustomUser, Shop, ShopMembership

# 初始化 Ninja API，使用 Unfold 后台一样的莫兰迪青绿风格进行后台描述
api = NinjaAPI(
    title="商品管理系统后台同步 API",
    version="1.0.0",
    description="支持多租户隔离、离线增量同步与设备状态管理的 Django Ninja 后台"
)

# ──── JWT 编解码工具函数 ────

JWT_SECRET = getattr(settings, 'SECRET_KEY', 'default_secret')
JWT_ALGORITHM = 'HS256'

def generate_token(user: CustomUser) -> str:
    payload = {
        'user_id': str(user.id),
        'username': user.username,
        'exp': datetime.datetime.utcnow() + datetime.timedelta(days=14)  # 默认2周免登录，保障离线体验
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)

def decode_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        return None

# ──── 自定义 HttpBearer 认证器 ────

class AuthBearer(HttpBearer):
    def authenticate(self, request, token: str) -> Optional[CustomUser]:
        payload = decode_token(token)
        if not payload:
            return None
        try:
            user = CustomUser.objects.get(id=payload['user_id'])
            # 将 user 绑定到 request.user 以便在 API 和 Django 内部流通
            request.user = user
            
            # 从标头中读取激活的店铺，并做多租户安全性检验
            active_shop_id = request.headers.get('X-Active-Shop-ID')
            if active_shop_id:
                try:
                    # 校验该用户对该店铺有已批准的绑定关系
                    membership = ShopMembership.objects.get(
                        user=user,
                        shop_id=active_shop_id,
                        status='APPROVED'
                    )
                    request.active_shop = membership.shop
                except ShopMembership.DoesNotExist:
                    raise HttpError(403, "你没有访问该店铺数据的权限或申请尚未被确认。")
            else:
                request.active_shop = None
                
            return user
        except CustomUser.DoesNotExist:
            return None

auth_bearer = AuthBearer()

# ──── 数据校验 Schema ────

class RegisterSchema(Schema):
    username: str
    password: str
    email: Optional[str] = ""
    phone: Optional[str] = ""

class LoginSchema(Schema):
    username: str
    password: str

class AuthTokenSchema(Schema):
    token: str
    username: str
    user_id: UUID

class ShopSchema(Schema):
    id: UUID
    name: str
    created_at: datetime.datetime

class ShopMembershipSchema(Schema):
    shop_id: UUID
    shop_name: str
    role: str
    status: str
    joined_at: datetime.datetime

class CreateShopSchema(Schema):
    name: str

class JoinShopSchema(Schema):
    shop_id: UUID

# ──── 1. 用户注册与登录 API ────

@api.post("/auth/register", response={200: AuthTokenSchema, 400: dict}, auth=None)
def register(request, data: RegisterSchema):
    if CustomUser.objects.filter(username=data.username).exists():
        return 400, {"message": "用户名已存在。"}
    
    user = CustomUser.objects.create_user(
        username=data.username,
        password=data.password,
        email=data.email,
        phone=data.phone
    )
    token = generate_token(user)
    return 200, {
        "token": token,
        "username": user.username,
        "user_id": user.id
    }

@api.post("/auth/login", response={200: AuthTokenSchema, 400: dict}, auth=None)
def login(request, data: LoginSchema):
    user = authenticate(username=data.username, password=data.password)
    if not user:
        return 400, {"message": "用户名或密码错误。"}
    
    token = generate_token(user)
    return 200, {
        "token": token,
        "username": user.username,
        "user_id": user.id
    }

# ──── 2. 多租户店铺管理 API ────

@api.get("/shops/my-shops", response=List[ShopMembershipSchema], auth=auth_bearer)
def my_shops(request):
    memberships = ShopMembership.objects.filter(user=request.user)
    res = []
    for m in memberships:
        res.append({
            "shop_id": m.shop.id,
            "shop_name": m.shop.name,
            "role": m.role,
            "status": m.status,
            "joined_at": m.joined_at
        })
    return res

@api.post("/shops/create", response={200: ShopSchema, 400: dict}, auth=auth_bearer)
def create_shop(request, data: CreateShopSchema):
    shop_name = data.name.strip()
    if not shop_name:
        return 400, {"message": "店铺名称不能为空。"}
        
    shop = Shop.objects.create(name=shop_name)
    # 创建人自动成为该店铺最高管理员 (CREATOR) 且免审批 (APPROVED)
    ShopMembership.objects.create(
        user=request.user,
        shop=shop,
        role='CREATOR',
        status='APPROVED'
    )
    return 200, shop

@api.post("/shops/join", response={200: dict, 400: dict}, auth=auth_bearer)
def join_shop(request, data: JoinShopSchema):
    try:
        shop = Shop.objects.get(id=data.shop_id)
    except Shop.DoesNotExist:
        return 400, {"message": "找不到对应的店铺。"}
        
    membership, created = ShopMembership.objects.get_or_create(
        user=request.user,
        shop=shop,
        defaults={
            'role': 'MEMBER',
            'status': 'PENDING'
        }
    )
    if not created:
        if membership.status == 'APPROVED':
            return 400, {"message": "你已是该店铺的成员。"}
        elif membership.status == 'PENDING':
            return 400, {"message": "申请已提交，请耐心等待管理员审核。"}
        else:
            # 允许重新提交加入申请（将 REJECTED 重新置为 PENDING）
            membership.status = 'PENDING'
            membership.save()
            
    return 200, {"message": "申请已提交，等待管理员确认。"}

# ──── 3. 增量同步数据 Schema ────

from django.db import transaction
from inventory.models import Product, InboundReceipt, InboundItem, OutboundOrder, OutboundItem, OutboundAttachment, StockLedger, WarehouseStock, InboundActionLog

class ProductSyncSchema(Schema):
    id: UUID
    code: str
    name: str
    default_purchase_price: Optional[float] = None
    default_sale_price: Optional[float] = None
    is_deleted: bool
    updated_at: datetime.datetime

class InboundReceiptSyncSchema(Schema):
    id: UUID
    tracking_number: str
    seller_order_number: Optional[str] = None
    scheme_number: Optional[str] = None
    image_path: Optional[str] = None
    ocr_status: str
    is_settled: bool
    created_at: datetime.datetime
    is_deleted: bool
    updated_at: datetime.datetime

class InboundItemSyncSchema(Schema):
    id: UUID
    receipt_id: UUID
    product_code: str
    product_name: str
    quantity: int
    purchase_price: Optional[float] = None
    sale_price: Optional[float] = None
    is_deleted: bool
    updated_at: datetime.datetime

class OutboundOrderSyncSchema(Schema):
    id: UUID
    logistics_number: Optional[str] = None
    note: Optional[str] = None
    created_at: datetime.datetime
    is_deleted: bool
    updated_at: datetime.datetime

class OutboundItemSyncSchema(Schema):
    id: UUID
    order_id: UUID
    product_code: str
    product_name: str
    quantity: int
    sale_price: Optional[float] = None
    is_deleted: bool
    updated_at: datetime.datetime

class OutboundAttachmentSyncSchema(Schema):
    id: UUID
    order_id: UUID
    image_path: str
    created_at: datetime.datetime
    is_deleted: bool
    updated_at: datetime.datetime

class StockLedgerSyncSchema(Schema):
    id: UUID
    product_code: str
    product_name: str
    delta: int
    reason: str
    source_id: str
    created_at: datetime.datetime
    is_deleted: bool
    updated_at: datetime.datetime

class WarehouseStockSyncSchema(Schema):
    id: UUID
    product_code: str
    product_name: str
    quantity: int
    is_deleted: bool
    updated_at: datetime.datetime

class SyncPushSchema(Schema):
    products: List[ProductSyncSchema] = []
    inbound_receipts: List[InboundReceiptSyncSchema] = []
    inbound_items: List[InboundItemSyncSchema] = []
    outbound_orders: List[OutboundOrderSyncSchema] = []
    outbound_items: List[OutboundItemSyncSchema] = []
    outbound_attachments: List[OutboundAttachmentSyncSchema] = []
    stock_ledger: List[StockLedgerSyncSchema] = []
    warehouse_stock: List[WarehouseStockSyncSchema] = []

class SyncPullResponseSchema(Schema):
    server_time: datetime.datetime
    products: List[ProductSyncSchema]
    inbound_receipts: List[InboundReceiptSyncSchema]
    inbound_items: List[InboundItemSyncSchema]
    outbound_orders: List[OutboundOrderSyncSchema]
    outbound_items: List[OutboundItemSyncSchema]
    outbound_attachments: List[OutboundAttachmentSyncSchema]
    stock_ledger: List[StockLedgerSyncSchema]
    warehouse_stock: List[WarehouseStockSyncSchema]

# ──── 4. 增量数据同步接口 ────

@api.post("/sync/push", response={200: dict, 400: dict}, auth=auth_bearer)
def sync_push(request, data: SyncPushSchema):
    if not request.active_shop:
        return 400, {"message": "请求标头中必须包含激活的店铺 ID (X-Active-Shop-ID)。"}
        
    shop = request.active_shop
    
    try:
        # 使用数据库事务，确保这一批同步变更强一致性写入，不产生悬挂单据
        with transaction.atomic():
            # 1. 同步商品
            for p in data.products:
                Product.objects.update_or_create(
                    id=p.id,
                    shop=shop,
                    defaults={
                        'code': p.code,
                        'name': p.name,
                        'default_purchase_price': p.default_purchase_price,
                        'default_sale_price': p.default_sale_price,
                        'is_deleted': p.is_deleted,
                    }
                )
            
            # 2. 同步入库单
            for r in data.inbound_receipts:
                InboundReceipt.objects.update_or_create(
                    id=r.id,
                    shop=shop,
                    defaults={
                        'tracking_number': r.tracking_number,
                        'seller_order_number': r.seller_order_number,
                        'scheme_number': r.scheme_number,
                        'image_path': r.image_path,
                        'ocr_status': r.ocr_status,
                        'is_settled': r.is_settled,
                        'created_at': r.created_at,
                        'is_deleted': r.is_deleted,
                    }
                )
                
            # 3. 同步入库明细
            for item in data.inbound_items:
                InboundItem.objects.update_or_create(
                    id=item.id,
                    shop=shop,
                    defaults={
                        'receipt_id': item.receipt_id,
                        'product_code': item.product_code,
                        'product_name': item.product_name,
                        'quantity': item.quantity,
                        'purchase_price': item.purchase_price,
                        'sale_price': item.sale_price,
                        'is_deleted': item.is_deleted,
                    }
                )
                
            # 4. 同步出库单
            for o in data.outbound_orders:
                OutboundOrder.objects.update_or_create(
                    id=o.id,
                    shop=shop,
                    defaults={
                        'logistics_number': o.logistics_number,
                        'note': o.note,
                        'created_at': o.created_at,
                        'is_deleted': o.is_deleted,
                    }
                )
                
            # 5. 同步出库明细
            for item in data.outbound_items:
                OutboundItem.objects.update_or_create(
                    id=item.id,
                    shop=shop,
                    defaults={
                        'order_id': item.order_id,
                        'product_code': item.product_code,
                        'product_name': item.product_name,
                        'quantity': item.quantity,
                        'sale_price': item.sale_price,
                        'is_deleted': item.is_deleted,
                    }
                )
                
            # 6. 同步出库单图片附件
            for attach in data.outbound_attachments:
                OutboundAttachment.objects.update_or_create(
                    id=attach.id,
                    shop=shop,
                    defaults={
                        'order_id': attach.order_id,
                        'image_path': attach.image_path,
                        'created_at': attach.created_at,
                        'is_deleted': attach.is_deleted,
                    }
                )
                
            # 7. 同步库存变更流水
            for ledger in data.stock_ledger:
                StockLedger.objects.update_or_create(
                    id=ledger.id,
                    shop=shop,
                    defaults={
                        'product_code': ledger.product_code,
                        'product_name': ledger.product_name,
                        'delta': ledger.delta,
                        'reason': ledger.reason,
                        'source_id': ledger.source_id,
                        'created_at': ledger.created_at,
                        'is_deleted': ledger.is_deleted,
                    }
                )
                
            # 8. 同步当前库存状态
            for stock in data.warehouse_stock:
                WarehouseStock.objects.update_or_create(
                    id=stock.id,
                    shop=shop,
                    defaults={
                        'product_code': stock.product_code,
                        'product_name': stock.product_name,
                        'quantity': stock.quantity,
                        'is_deleted': stock.is_deleted,
                    }
                )
                
        return 200, {"message": "同步数据推送成功。"}
    except Exception as e:
        return 400, {"message": f"同步推送写入失败: {str(e)}"}

@api.get("/sync/pull", response=SyncPullResponseSchema, auth=auth_bearer)
def sync_pull(request, last_sync_time: datetime.datetime):
    if not request.active_shop:
        raise HttpError(400, "请求标头中必须包含激活的店铺 ID (X-Active-Shop-ID)。")
        
    shop = request.active_shop
    server_time = datetime.datetime.now(datetime.timezone.utc)
    
    # 核心过滤逻辑：拉取在 last_sync_time 之后发生过任何属性变更（更新/删除）的数据
    return {
        "server_time": server_time,
        "products": list(Product.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "inbound_receipts": list(InboundReceipt.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "inbound_items": list(InboundItem.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "outbound_orders": list(OutboundOrder.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "outbound_items": list(OutboundItem.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "outbound_attachments": list(OutboundAttachment.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "stock_ledger": list(StockLedger.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
        "warehouse_stock": list(WarehouseStock.objects.filter(shop=shop, updated_at__gt=last_sync_time)),
    }


# ──── Web 管理端 API Schema ────

class UserSchema(Schema):
    id: UUID
    username: str

class MemberOutSchema(Schema):
    id: UUID
    user: UserSchema
    role: str
    status: str
    joined_at: datetime.datetime

class MemberUpdateSchema(Schema):
    membership_id: UUID
    role: Optional[str] = None
    status: Optional[str] = None

class ProductCreateSchema(Schema):
    code: str
    name: str
    default_purchase_price: Optional[float] = None
    default_sale_price: Optional[float] = None

class ProductOutSchema(Schema):
    id: UUID
    code: str
    name: str
    default_purchase_price: Optional[float] = None
    default_sale_price: Optional[float] = None
    updated_at: datetime.datetime

class InboundItemCreateSchema(Schema):
    product_code: str
    product_name: str
    quantity: int
    purchase_price: float
    sale_price: float

class InboundReceiptCreateSchema(Schema):
    tracking_number: str
    seller_order_number: Optional[str] = None
    scheme_number: Optional[str] = None
    items: List[InboundItemCreateSchema]

class InboundItemOutSchema(Schema):
    id: UUID
    product_code: str
    product_name: str
    quantity: int
    purchase_price: float
    sale_price: float

class InboundReceiptOutSchema(Schema):
    id: UUID
    tracking_number: str
    seller_order_number: Optional[str] = None
    scheme_number: Optional[str] = None
    ocr_status: str
    is_settled: bool
    created_at: datetime.datetime
    items: List[InboundItemOutSchema]

class OutboundItemCreateSchema(Schema):
    product_code: str
    product_name: str
    quantity: int
    sale_price: float

class OutboundOrderCreateSchema(Schema):
    logistics_number: Optional[str] = None
    note: Optional[str] = None
    items: List[OutboundItemCreateSchema]

class OutboundItemOutSchema(Schema):
    id: UUID
    product_code: str
    product_name: str
    quantity: int
    sale_price: float

class OutboundOrderOutSchema(Schema):
    id: UUID
    logistics_number: Optional[str] = None
    note: Optional[str] = None
    created_at: datetime.datetime
    items: List[OutboundItemOutSchema]

class WarehouseStockOutSchema(Schema):
    id: UUID
    product_code: str
    product_name: str
    quantity: int
    updated_at: datetime.datetime

class StockLedgerOutSchema(Schema):
    id: UUID
    product_code: str
    product_name: str
    delta: int
    reason: str
    source_id: str
    created_at: datetime.datetime


# ──── 5. Web 管理端 API 视图 ────

@api.get("/shops/members", response=List[MemberOutSchema], auth=auth_bearer)
def list_members(request):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    # 仅允许管理员或创建人查看成员
    membership = ShopMembership.objects.filter(
        user=request.user, 
        shop=request.active_shop, 
        status='APPROVED',
        role__in=['CREATOR', 'ADMIN']
    ).first()
    if not membership:
        raise HttpError(403, "只有店铺创建人或管理员可以管理成员")
        
    return list(ShopMembership.objects.filter(shop=request.active_shop).order_by('-joined_at'))

@api.post("/shops/members/update", response={200: dict, 400: dict}, auth=auth_bearer)
def update_member(request, data: MemberUpdateSchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    my_membership = ShopMembership.objects.filter(
        user=request.user, 
        shop=request.active_shop, 
        status='APPROVED',
        role__in=['CREATOR', 'ADMIN']
    ).first()
    if not my_membership:
        return 400, {"message": "只有店铺创建人或管理员可以管理成员"}
        
    try:
        target_membership = ShopMembership.objects.get(id=data.membership_id, shop=request.active_shop)
    except ShopMembership.DoesNotExist:
        return 400, {"message": "未找到对应的成员记录"}
        
    # 防止管理员越权修改创建人
    if target_membership.role == 'CREATOR' and my_membership.role != 'CREATOR':
        return 400, {"message": "无法修改店铺创建人的角色或状态"}
        
    if data.role:
        target_membership.role = data.role
    if data.status:
        target_membership.status = data.status
        
    target_membership.save()
    return 200, {"message": "成员状态更新成功"}

@api.get("/inventory/products", response=List[ProductOutSchema], auth=auth_bearer)
def list_products(request, search: Optional[str] = None):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    qs = Product.objects.filter(shop=request.active_shop, is_deleted=False)
    if search:
        qs = qs.filter(models.Q(name__icontains=search) | models.Q(code__icontains=search))
    return list(qs.order_by('-updated_at'))

@api.post("/inventory/products", response={200: ProductOutSchema, 400: dict}, auth=auth_bearer)
def create_product(request, data: ProductCreateSchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    if Product.objects.filter(shop=request.active_shop, code=data.code, is_deleted=False).exists():
        return 400, {"message": f"商品编码 [{data.code}] 已存在"}
        
    # 如果软删除了，则恢复并更新
    deleted_p = Product.objects.filter(shop=request.active_shop, code=data.code, is_deleted=True).first()
    if deleted_p:
        deleted_p.is_deleted = False
        deleted_p.name = data.name
        deleted_p.default_purchase_price = data.default_purchase_price
        deleted_p.default_sale_price = data.default_sale_price
        deleted_p.save()
        return 200, deleted_p
        
    product = Product.objects.create(
        shop=request.active_shop,
        code=data.code,
        name=data.name,
        default_purchase_price=data.default_purchase_price,
        default_sale_price=data.default_sale_price
    )
    return 200, product

@api.put("/inventory/products/{product_id}", response={200: ProductOutSchema, 400: dict}, auth=auth_bearer)
def update_product(request, product_id: UUID, data: ProductCreateSchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    try:
        product = Product.objects.get(id=product_id, shop=request.active_shop)
    except Product.DoesNotExist:
        return 400, {"message": "找不到对应的商品"}
        
    # 检查 code 唯一性
    if Product.objects.filter(shop=request.active_shop, code=data.code, is_deleted=False).exclude(id=product_id).exists():
        return 400, {"message": f"商品编码 [{data.code}] 已被其他商品占用"}
        
    product.code = data.code
    product.name = data.name
    product.default_purchase_price = data.default_purchase_price
    product.default_sale_price = data.default_sale_price
    product.save()
    return 200, product

@api.delete("/inventory/products/{product_id}", response={200: dict, 400: dict}, auth=auth_bearer)
def delete_product(request, product_id: UUID):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    try:
        product = Product.objects.get(id=product_id, shop=request.active_shop)
    except Product.DoesNotExist:
        return 400, {"message": "找不到对应的商品"}
        
    product.is_deleted = True
    product.save()
    return 200, {"message": "商品已成功删除"}

@api.get("/inventory/inbound", response=List[InboundReceiptOutSchema], auth=auth_bearer)
def list_inbound(request):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    return list(InboundReceipt.objects.filter(shop=request.active_shop, is_deleted=False).order_by('-created_at'))

@api.post("/inventory/inbound", response={200: InboundReceiptOutSchema, 400: dict}, auth=auth_bearer)
def create_inbound(request, data: InboundReceiptCreateSchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    if InboundReceipt.objects.filter(shop=request.active_shop, tracking_number=data.tracking_number, is_deleted=False).exists():
        return 400, {"message": f"快递单号 [{data.tracking_number}] 的入库单已存在"}
        
    try:
        with transaction.atomic():
            now = datetime.datetime.now(datetime.timezone.utc)
            receipt = InboundReceipt.objects.create(
                shop=request.active_shop,
                tracking_number=data.tracking_number,
                seller_order_number=data.seller_order_number,
                scheme_number=data.scheme_number,
                created_at=now,
                ocr_status='confirmed'
            )
            for item in data.items:
                # 创建明细
                InboundItem.objects.create(
                    shop=request.active_shop,
                    receipt=receipt,
                    product_code=item.product_code,
                    product_name=item.product_name,
                    quantity=item.quantity,
                    purchase_price=item.purchase_price,
                    sale_price=item.sale_price
                )
                # 更新商品库存
                stock, _ = WarehouseStock.objects.get_or_create(
                    shop=request.active_shop,
                    product_code=item.product_code,
                    defaults={'product_name': item.product_name, 'quantity': 0}
                )
                stock.quantity += item.quantity
                stock.product_name = item.product_name  # 更新名称以防修改
                stock.save()
                
                # 写入账本流水
                StockLedger.objects.create(
                    shop=request.active_shop,
                    product_code=item.product_code,
                    product_name=item.product_name,
                    delta=item.quantity,
                    reason='inbound',
                    source_id=str(receipt.id),
                    created_at=now
                )
            # 写入审计日志
            InboundActionLog.objects.create(
                shop=request.active_shop,
                user=request.user,
                action_type='CREATE',
                tracking_number=receipt.tracking_number,
                detail=f"登记新入库单。明细: {', '.join([f'{it.product_name} x {it.quantity}件' for it in data.items])}"
            )
            return 200, receipt
    except Exception as e:
        return 400, {"message": f"入库记账失败: {str(e)}"}

@api.get("/inventory/outbound", response=List[OutboundOrderOutSchema], auth=auth_bearer)
def list_outbound(request):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    return list(OutboundOrder.objects.filter(shop=request.active_shop, is_deleted=False).order_by('-created_at'))

@api.post("/inventory/outbound", response={200: OutboundOrderOutSchema, 400: dict}, auth=auth_bearer)
def create_outbound(request, data: OutboundOrderCreateSchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
        
    try:
        with transaction.atomic():
            now = datetime.datetime.now(datetime.timezone.utc)
            order = OutboundOrder.objects.create(
                shop=request.active_shop,
                logistics_number=data.logistics_number,
                note=data.note,
                created_at=now
            )
            for item in data.items:
                # 扣减库存，先检查当前库存是否充足
                stock, _ = WarehouseStock.objects.get_or_create(
                    shop=request.active_shop,
                    product_code=item.product_code,
                    defaults={'product_name': item.product_name, 'quantity': 0}
                )
                if stock.quantity < item.quantity:
                    raise Exception(f"商品 [{item.product_name}] 库存不足，当前库存: {stock.quantity}，出库需求: {item.quantity}")
                
                # 创建明细
                OutboundItem.objects.create(
                    shop=request.active_shop,
                    order=order,
                    product_code=item.product_code,
                    product_name=item.product_name,
                    quantity=item.quantity,
                    sale_price=item.sale_price
                )
                
                # 更新库存量
                stock.quantity -= item.quantity
                stock.save()
                
                # 写入账本流水
                StockLedger.objects.create(
                    shop=request.active_shop,
                    product_code=item.product_code,
                    product_name=item.product_name,
                    delta=-item.quantity,
                    reason='outbound',
                    source_id=str(order.id),
                    created_at=now
                )
            return 200, order
    except Exception as e:
        return 400, {"message": f"出库记账失败: {str(e)}"}

@api.get("/inventory/stocks", response=List[WarehouseStockOutSchema], auth=auth_bearer)
def list_stocks(request):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    return list(WarehouseStock.objects.filter(shop=request.active_shop, is_deleted=False).order_by('-quantity'))

@api.get("/inventory/ledger", response=List[StockLedgerOutSchema], auth=auth_bearer)
def list_ledger(request):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    return list(StockLedger.objects.filter(shop=request.active_shop, is_deleted=False).order_by('-created_at'))


class UpdateInboundStatusSchema(Schema):
    is_settled: bool

class UpdateInboundItemQtySchema(Schema):
    quantity: int

class InboundActionLogOutSchema(Schema):
    id: UUID
    user: Optional[UserSchema] = None
    action_type: str
    tracking_number: str
    detail: str
    created_at: datetime.datetime

@api.put("/inventory/inbound/{receipt_id}/status", response={200: dict, 400: dict}, auth=auth_bearer)
def update_inbound_status(request, receipt_id: UUID, data: UpdateInboundStatusSchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    try:
        receipt = InboundReceipt.objects.get(id=receipt_id, shop=request.active_shop)
        receipt.is_settled = data.is_settled
        receipt.save()
        
        # 写入审计日志
        InboundActionLog.objects.create(
            shop=request.active_shop,
            user=request.user,
            action_type='UPDATE',
            tracking_number=receipt.tracking_number,
            detail=f"修改结算状态为: {'已结清' if data.is_settled else '未结清'}"
        )
        return 200, {"message": "入库单结算状态已更新"}
    except InboundReceipt.DoesNotExist:
        return 400, {"message": "找不到对应的入库单"}

@api.put("/inventory/inbound/item/{item_id}", response={200: dict, 400: dict}, auth=auth_bearer)
def update_inbound_item_qty(request, item_id: UUID, data: UpdateInboundItemQtySchema):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    
    if data.quantity <= 0:
        return 400, {"message": "修改后的数量必须大于 0"}
        
    try:
        with transaction.atomic():
            item = InboundItem.objects.select_for_update().get(id=item_id, shop=request.active_shop)
            receipt = item.receipt
            old_qty = item.quantity
            new_qty = data.quantity
            diff_qty = new_qty - old_qty
            
            if diff_qty == 0:
                return 200, {"message": "数量未发生变更"}
                
            # 1. 更新明细行数量
            item.quantity = new_qty
            item.save()
            
            # 2. 级联调整即时库存 WarehouseStock
            stock, _ = WarehouseStock.objects.get_or_create(
                shop=request.active_shop,
                product_code=item.product_code,
                defaults={'product_name': item.product_name, 'quantity': 0}
            )
            
            if stock.quantity + diff_qty < 0:
                raise Exception(f"库存扣减失败。当前总库存仅有 {stock.quantity} 件，修改差额为 {diff_qty} 件，会导致库存出现负数！")
            
            stock.quantity += diff_qty
            stock.save()
            
            # 3. 级联调整库存异动日志 StockLedger
            ledger = StockLedger.objects.filter(
                shop=request.active_shop,
                source_id=str(receipt.id),
                product_code=item.product_code,
                reason='inbound'
            ).first()
            
            if ledger:
                ledger.delta = new_qty
                ledger.save()
            else:
                StockLedger.objects.create(
                    shop=request.active_shop,
                    product_code=item.product_code,
                    product_name=item.product_name,
                    delta=diff_qty,
                    reason='adjustment',
                    source_id=str(receipt.id),
                    created_at=datetime.datetime.now(datetime.timezone.utc)
                )
                
            # 4. 写入审计日志
            InboundActionLog.objects.create(
                shop=request.active_shop,
                user=request.user,
                action_type='UPDATE',
                tracking_number=receipt.tracking_number,
                detail=f"修改入库数量。商品: {item.product_name} ({item.product_code})，由 {old_qty}件 变更为 {new_qty}件 (库存异动差值: {diff_qty}件)"
            )
            return 200, {"message": "入库数量及库存已同步更新"}
    except Exception as e:
        return 400, {"message": f"修改入库数量失败: {str(e)}"}

@api.delete("/inventory/inbound/{receipt_id}", response={200: dict, 400: dict}, auth=auth_bearer)
def delete_inbound(request, receipt_id: UUID):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    try:
        with transaction.atomic():
            receipt = InboundReceipt.objects.select_for_update().get(id=receipt_id, shop=request.active_shop)
            
            # 扣减库存，并硬删除流水
            for item in receipt.items.all():
                stock = WarehouseStock.objects.filter(shop=request.active_shop, product_code=item.product_code).first()
                if stock:
                    if stock.quantity - item.quantity < 0:
                        raise Exception(f"删除失败！回退库存时会导致商品 [{item.product_name}] 的总库存出现负数 (在库仅剩 {stock.quantity} 件，需回退扣减 {item.quantity} 件)！")
                    stock.quantity -= item.quantity
                    stock.save()
                
                # 删除库存变更记录
                StockLedger.objects.filter(
                    shop=request.active_shop,
                    source_id=str(receipt.id),
                    product_code=item.product_code,
                    reason='inbound'
                ).delete()
            
            # 写入审计日志
            InboundActionLog.objects.create(
                shop=request.active_shop,
                user=request.user,
                action_type='DELETE',
                tracking_number=receipt.tracking_number,
                detail=f"删除了该入库单。原包含明细: {', '.join([f'{it.product_name} x {it.quantity}件' for it in receipt.items.all()])}"
            )
            
            # 物理删除单据及关联明细
            receipt.delete()
            return 200, {"message": "入库单已成功删除，仓储库存已扣减回退"}
    except Exception as e:
        return 400, {"message": f"删除入库单失败: {str(e)}"}

@api.get("/inventory/inbound/logs", response=List[InboundActionLogOutSchema], auth=auth_bearer)
def list_inbound_logs(request):
    if not request.active_shop:
        raise HttpError(400, "X-Active-Shop-ID is required")
    return list(InboundActionLog.objects.filter(shop=request.active_shop).select_related('user').order_by('-created_at'))
