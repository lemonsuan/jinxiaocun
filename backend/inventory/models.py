import uuid
from django.db import models
from shops.models import Shop

class SyncModel(models.Model):
    """
    增量同步基类，包含同步所需的 UUID 主键、软删除标记和更新时间戳
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey(Shop, on_delete=models.CASCADE, verbose_name="所属店铺")
    is_deleted = models.BooleanField(default=False, verbose_name="是否已删除")
    updated_at = models.DateTimeField(auto_now=True, verbose_name="更新时间")

    class Meta:
        abstract = True

class Product(SyncModel):
    code = models.CharField(max_length=100, verbose_name="商品编码")
    name = models.CharField(max_length=200, verbose_name="商品名称")
    default_purchase_price = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True, verbose_name="默认采购价")
    default_sale_price = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True, verbose_name="默认零售价")

    class Meta:
        verbose_name = "商品"
        verbose_name_plural = "商品"
        unique_together = ('shop', 'code')

    def __str__(self):
        return f"{self.name} ({self.code})"

class InboundReceipt(SyncModel):
    OCR_STATUS_CHOICES = [
        ('pending', '识别中'),
        ('confirmed', '已确认'),
        ('failed', '识别失败'),
    ]

    tracking_number = models.CharField(max_length=100, verbose_name="快递单号")
    seller_order_number = models.CharField(max_length=100, null=True, blank=True, verbose_name="商家订单号")
    scheme_number = models.CharField(max_length=100, null=True, blank=True, verbose_name="计划单号")
    image_path = models.CharField(max_length=500, null=True, blank=True, verbose_name="单据图片路径")
    ocr_status = models.CharField(max_length=20, choices=OCR_STATUS_CHOICES, default='confirmed', verbose_name="OCR状态")
    is_settled = models.BooleanField(default=False, verbose_name="是否结清")
    created_at = models.DateTimeField(verbose_name="创建时间")

    class Meta:
        verbose_name = "入库单"
        verbose_name_plural = "入库单"
        unique_together = ('shop', 'tracking_number')

    def __str__(self):
        return f"入库单: {self.tracking_number} ({self.shop.name})"

class InboundItem(SyncModel):
    receipt = models.ForeignKey(InboundReceipt, on_delete=models.CASCADE, related_name='items', verbose_name="入库单")
    product_code = models.CharField(max_length=100, verbose_name="商品编码")
    product_name = models.CharField(max_length=200, verbose_name="商品名称")
    quantity = models.IntegerField(verbose_name="入库数量")
    purchase_price = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True, verbose_name="采购价")
    sale_price = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True, verbose_name="零售价")

    class Meta:
        verbose_name = "入库商品明细"
        verbose_name_plural = "入库商品明细"

    def __str__(self):
        return f"{self.product_name} x {self.quantity}"

class OutboundOrder(SyncModel):
    logistics_number = models.CharField(max_length=100, null=True, blank=True, verbose_name="物流单号")
    note = models.TextField(null=True, blank=True, verbose_name="备注")
    created_at = models.DateTimeField(verbose_name="创建时间")

    class Meta:
        verbose_name = "出库单"
        verbose_name_plural = "出库单"

    def __str__(self):
        return f"出库单: {self.id} ({self.shop.name})"

class OutboundItem(SyncModel):
    order = models.ForeignKey(OutboundOrder, on_delete=models.CASCADE, related_name='items', verbose_name="出库单")
    product_code = models.CharField(max_length=100, verbose_name="商品编码")
    product_name = models.CharField(max_length=200, verbose_name="商品名称")
    quantity = models.IntegerField(verbose_name="出库数量")
    sale_price = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True, verbose_name="销售价")

    class Meta:
        verbose_name = "出库商品明细"
        verbose_name_plural = "出库商品明细"

    def __str__(self):
        return f"{self.product_name} x {self.quantity}"

class OutboundAttachment(SyncModel):
    order = models.ForeignKey(OutboundOrder, on_delete=models.CASCADE, related_name='attachments', verbose_name="出库单")
    image_path = models.CharField(max_length=500, verbose_name="图片文件路径")
    created_at = models.DateTimeField(verbose_name="创建时间")

    class Meta:
        verbose_name = "出库图片附件"
        verbose_name_plural = "出库图片附件"

    def __str__(self):
        return f"附件: {self.image_path}"

class StockLedger(SyncModel):
    REASON_CHOICES = [
        ('inbound', '扫码入库'),
        ('outbound', '出库出货'),
        ('adjustment', '库存校准'),
    ]

    product_code = models.CharField(max_length=100, verbose_name="商品编码")
    product_name = models.CharField(max_length=200, verbose_name="商品名称")
    delta = models.IntegerField(verbose_name="库存变动量")
    reason = models.CharField(max_length=30, choices=REASON_CHOICES, verbose_name="变动原因")
    source_id = models.CharField(max_length=100, verbose_name="关联单据ID")
    created_at = models.DateTimeField(verbose_name="创建时间")

    class Meta:
        verbose_name = "库存流水账本"
        verbose_name_plural = "库存流水账本"

    def __str__(self):
        return f"{self.product_name} 变动 {self.delta} ({self.reason})"

class WarehouseStock(SyncModel):
    product_code = models.CharField(max_length=100, verbose_name="商品编码")
    product_name = models.CharField(max_length=200, verbose_name="商品名称")
    quantity = models.IntegerField(default=0, verbose_name="当前库存量")

    class Meta:
        verbose_name = "当前库存状态"
        verbose_name_plural = "当前库存状态"
        unique_together = ('shop', 'product_code')

    def __str__(self):
        return f"{self.product_name}: {self.quantity}件"


class InboundActionLog(models.Model):
    ACTION_CHOICES = [
        ('CREATE', '新增'),
        ('UPDATE', '修改'),
        ('DELETE', '删除'),
    ]

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shop = models.ForeignKey(Shop, on_delete=models.CASCADE, verbose_name="所属店铺")
    user = models.ForeignKey('shops.CustomUser', on_delete=models.SET_NULL, null=True, verbose_name="操作人")
    action_type = models.CharField(max_length=20, choices=ACTION_CHOICES, verbose_name="操作类型")
    tracking_number = models.CharField(max_length=100, verbose_name="快递单号")
    detail = models.TextField(verbose_name="变更详情")
    created_at = models.DateTimeField(auto_now_add=True, verbose_name="记录时间")

    class Meta:
        verbose_name = "入库单操作日志"
        verbose_name_plural = "入库单操作日志"

    def __str__(self):
        return f"{self.user.username if self.user else '未知'} - {self.get_action_type_display()} - {self.tracking_number}"
