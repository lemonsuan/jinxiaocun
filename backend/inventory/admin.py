from django.contrib import admin
from unfold.admin import ModelAdmin, TabularInline
from .models import Product, InboundReceipt, InboundItem, OutboundOrder, OutboundItem, OutboundAttachment, StockLedger, WarehouseStock
from shops.models import Shop, ShopMembership

class TenantBaseAdmin(ModelAdmin):
    """
    多租户 ModelAdmin 基类，限制非超级管理员只能看到和编辑自己店铺的数据
    """
    def has_module_permission(self, request):
        # 非超级管理员左侧侧边栏中隐藏商品、单据等底层子菜单，强制以店铺为入口
        return request.user.is_superuser

    def has_view_permission(self, request, obj=None):
        return request.user.is_staff

    def has_add_permission(self, request):
        return request.user.is_staff

    def has_change_permission(self, request, obj=None):
        return request.user.is_staff

    def has_delete_permission(self, request, obj=None):
        return request.user.is_staff

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        if request.user.is_superuser:
            return qs
        # 当前用户已正式加入且为管理员或创建人的店铺
        my_shops = ShopMembership.objects.filter(
            user=request.user,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).values_list('shop_id', flat=True)
        return qs.filter(shop_id__in=my_shops)

    def get_form(self, request, obj=None, **kwargs):
        form = super().get_form(request, obj, **kwargs)
        # 限制只能选择该管理员有管理权限的店铺
        if 'shop' in form.base_fields and not request.user.is_superuser:
            my_shops = ShopMembership.objects.filter(
                user=request.user,
                role__in=['CREATOR', 'ADMIN'],
                status='APPROVED'
            ).values_list('shop_id', flat=True)
            form.base_fields['shop'].queryset = Shop.objects.filter(id__in=my_shops)
            # 如果只有一个管理的店铺，默认帮其选中
            if len(my_shops) == 1:
                form.base_fields['shop'].initial = my_shops[0]
        return form

# ──── 内联表设计，方便单据录入 ────

class InboundItemInline(TabularInline):
    model = InboundItem
    extra = 1
    fields = ('product_code', 'product_name', 'quantity', 'purchase_price', 'sale_price', 'shop')
    
    def get_formset(self, request, obj=None, **kwargs):
        # 让内联明细也继承 shop 字段的过滤
        formset = super().get_formset(request, obj, **kwargs)
        # 在表单生成时，自动限制内联 shop
        if not request.user.is_superuser:
            my_shops = ShopMembership.objects.filter(
                user=request.user,
                role__in=['CREATOR', 'ADMIN'],
                status='APPROVED'
            ).values_list('shop_id', flat=True)
            formset.form.base_fields['shop'].queryset = Shop.objects.filter(id__in=my_shops)
            if len(my_shops) == 1:
                formset.form.base_fields['shop'].initial = my_shops[0]
        return formset

class OutboundItemInline(TabularInline):
    model = OutboundItem
    extra = 1
    fields = ('product_code', 'product_name', 'quantity', 'sale_price', 'shop')

    def get_formset(self, request, obj=None, **kwargs):
        formset = super().get_formset(request, obj, **kwargs)
        if not request.user.is_superuser:
            my_shops = ShopMembership.objects.filter(
                user=request.user,
                role__in=['CREATOR', 'ADMIN'],
                status='APPROVED'
            ).values_list('shop_id', flat=True)
            formset.form.base_fields['shop'].queryset = Shop.objects.filter(id__in=my_shops)
            if len(my_shops) == 1:
                formset.form.base_fields['shop'].initial = my_shops[0]
        return formset

class OutboundAttachmentInline(TabularInline):
    model = OutboundAttachment
    extra = 1
    fields = ('image_path', 'created_at', 'shop')

    def get_formset(self, request, obj=None, **kwargs):
        formset = super().get_formset(request, obj, **kwargs)
        if not request.user.is_superuser:
            my_shops = ShopMembership.objects.filter(
                user=request.user,
                role__in=['CREATOR', 'ADMIN'],
                status='APPROVED'
            ).values_list('shop_id', flat=True)
            formset.form.base_fields['shop'].queryset = Shop.objects.filter(id__in=my_shops)
            if len(my_shops) == 1:
                formset.form.base_fields['shop'].initial = my_shops[0]
        return formset

# ──── 注册核心 ModelAdmin ────

@admin.register(Product)
class ProductAdmin(TenantBaseAdmin):
    list_display = ('name', 'code', 'default_purchase_price', 'default_sale_price', 'shop', 'is_deleted', 'updated_at')
    list_filter = ('shop', 'is_deleted')
    search_fields = ('name', 'code')

@admin.register(InboundReceipt)
class InboundReceiptAdmin(TenantBaseAdmin):
    list_display = ('tracking_number', 'seller_order_number', 'scheme_number', 'is_settled', 'ocr_status', 'shop', 'created_at')
    list_filter = ('shop', 'is_settled', 'ocr_status', 'is_deleted')
    search_fields = ('tracking_number', 'seller_order_number')
    inlines = [InboundItemInline]

@admin.register(OutboundOrder)
class OutboundOrderAdmin(TenantBaseAdmin):
    list_display = ('id', 'logistics_number', 'note', 'shop', 'created_at')
    list_filter = ('shop', 'is_deleted')
    search_fields = ('logistics_number', 'note')
    inlines = [OutboundItemInline, OutboundAttachmentInline]

@admin.register(StockLedger)
class StockLedgerAdmin(TenantBaseAdmin):
    list_display = ('product_name', 'product_code', 'delta', 'reason', 'source_id', 'shop', 'created_at')
    list_filter = ('shop', 'reason', 'is_deleted')
    search_fields = ('product_name', 'product_code', 'source_id')
    readonly_fields = ('product_name', 'product_code', 'delta', 'reason', 'source_id', 'shop', 'created_at')

@admin.register(WarehouseStock)
class WarehouseStockAdmin(TenantBaseAdmin):
    list_display = ('product_name', 'product_code', 'quantity', 'shop', 'updated_at')
    list_filter = ('shop', 'is_deleted')
    search_fields = ('product_name', 'product_code')
    readonly_fields = ('product_name', 'product_code', 'quantity', 'shop', 'updated_at')
