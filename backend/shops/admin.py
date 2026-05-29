from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from unfold.admin import ModelAdmin, TabularInline
from unfold.decorators import action
from django.contrib import messages
from .models import CustomUser, Shop, ShopMembership
from inventory.models import Product, InboundReceipt, OutboundOrder, WarehouseStock

# 注册 CustomUser，引入 Unfold 美化
@admin.register(CustomUser)
class CustomUserAdmin(BaseUserAdmin, ModelAdmin):
    pass

# ──── 定义以店铺为中心的各种业务及成员内联类 (Inlines) ────

class ShopMembershipInline(TabularInline):
    model = ShopMembership
    extra = 0
    verbose_name = "店铺成员用户"
    verbose_name_plural = "店铺成员用户管理"
    fields = ('user', 'role', 'status', 'joined_at')
    readonly_fields = ('joined_at',)

    def has_view_permission(self, request, obj=None):
        return request.user.is_staff

    def _is_shop_manager(self, request, obj):
        if request.user.is_superuser:
            return True
        if obj is None:
            return request.user.is_staff
        return ShopMembership.objects.filter(
            user=request.user,
            shop=obj,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).exists()

    def has_add_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_change_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_delete_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

class ProductInline(TabularInline):
    model = Product
    extra = 0
    verbose_name = "店铺商品"
    verbose_name_plural = "店铺商品管理"
    show_change_link = True
    fields = ('name', 'code', 'default_purchase_price', 'default_sale_price', 'is_deleted')

    def has_view_permission(self, request, obj=None):
        return request.user.is_staff

    def _is_shop_manager(self, request, obj):
        if request.user.is_superuser:
            return True
        if obj is None:
            return request.user.is_staff
        return ShopMembership.objects.filter(
            user=request.user,
            shop=obj,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).exists()

    def has_add_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_change_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_delete_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

class InboundReceiptInline(TabularInline):
    model = InboundReceipt
    extra = 0
    verbose_name = "店铺入库单"
    verbose_name_plural = "店铺入库单记录"
    show_change_link = True
    fields = ('tracking_number', 'seller_order_number', 'is_settled', 'ocr_status', 'created_at', 'is_deleted')
    readonly_fields = ('created_at',)

    def has_view_permission(self, request, obj=None):
        return request.user.is_staff

    def _is_shop_manager(self, request, obj):
        if request.user.is_superuser:
            return True
        if obj is None:
            return request.user.is_staff
        return ShopMembership.objects.filter(
            user=request.user,
            shop=obj,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).exists()

    def has_add_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_change_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_delete_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

class OutboundOrderInline(TabularInline):
    model = OutboundOrder
    extra = 0
    verbose_name = "店铺出库单"
    verbose_name_plural = "店铺出库单记录"
    show_change_link = True
    fields = ('id', 'logistics_number', 'note', 'created_at', 'is_deleted')
    readonly_fields = ('id', 'created_at')

    def has_view_permission(self, request, obj=None):
        return request.user.is_staff

    def _is_shop_manager(self, request, obj):
        if request.user.is_superuser:
            return True
        if obj is None:
            return request.user.is_staff
        return ShopMembership.objects.filter(
            user=request.user,
            shop=obj,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).exists()

    def has_add_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_change_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

    def has_delete_permission(self, request, obj=None):
        return self._is_shop_manager(request, obj)

class WarehouseStockInline(TabularInline):
    model = WarehouseStock
    extra = 0
    verbose_name = "当前库存商品"
    verbose_name_plural = "当前库存状态 (只读)"
    fields = ('product_name', 'product_code', 'quantity', 'updated_at')
    readonly_fields = ('product_name', 'product_code', 'quantity', 'updated_at')
    
    def has_view_permission(self, request, obj=None):
        return request.user.is_staff
    
    has_add_permission = lambda self, r, o=None: False
    has_change_permission = lambda self, r, o=None: False
    has_delete_permission = lambda self, r, o=None: False

# ──── 注册店铺 Admin ────

@admin.register(Shop)
class ShopAdmin(ModelAdmin):
    list_display = ('name', 'id', 'created_at')
    search_fields = ('name',)
    readonly_fields = ('id', 'created_at')

    # 挂载全部内联模块实现店铺核心功能整合
    inlines = [
        ShopMembershipInline,
        ProductInline,
        InboundReceiptInline,
        OutboundOrderInline,
        WarehouseStockInline
    ]

    def has_view_permission(self, request, obj=None):
        print(f"[DEBUG] has_view_permission called. User: {request.user}, is_staff: {getattr(request.user, 'is_staff', None)}, obj: {obj}")
        return request.user.is_staff

    def has_add_permission(self, request):
        return request.user.is_staff

    def has_change_permission(self, request, obj=None):
        if request.user.is_superuser:
            return True
        if obj is None:
            return request.user.is_staff
        # 非超管必须是本店铺的 CREATOR 或 ADMIN 才能修改店铺信息
        exists = ShopMembership.objects.filter(
            user=request.user,
            shop=obj,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).exists()
        print(f"[DEBUG] has_change_permission called. User: {request.user}, shop: {obj}, exists: {exists}")
        return exists

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        if request.user.is_superuser:
            return qs
        # 非超级管理员只能看到自己是 CREATOR 或者是 ADMIN 的店铺
        my_shop_ids = ShopMembership.objects.filter(
            user=request.user,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).values_list('shop_id', flat=True)
        return qs.filter(id__in=my_shop_ids)

# 注册独立的 ShopMembership (供全局或大跨度管理使用)
@admin.register(ShopMembership)
class ShopMembershipAdmin(ModelAdmin):
    list_display = ('user', 'shop', 'role', 'status', 'joined_at')
    list_filter = ('role', 'status', 'shop')
    search_fields = ('user__username', 'shop__name')
    readonly_fields = ('joined_at',)

    actions = ['approve_applications', 'reject_applications', 'promote_to_admin', 'demote_to_member']

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        if request.user.is_superuser:
            return qs
        managed_shop_ids = ShopMembership.objects.filter(
            user=request.user,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).values_list('shop_id', flat=True)
        return qs.filter(shop_id__in=managed_shop_ids)

    def has_change_permission(self, request, obj=None):
        if not request.user.is_superuser and obj is not None:
            try:
                my_membership = ShopMembership.objects.get(
                    user=request.user,
                    shop=obj.shop,
                    status='APPROVED'
                )
                if my_membership.role == 'MEMBER':
                    return False
                if my_membership.role == 'ADMIN' and obj.role in ['CREATOR', 'ADMIN'] and obj.user != request.user:
                    return False
            except ShopMembership.DoesNotExist:
                return False
        return super().has_change_permission(request, obj)

    def has_delete_permission(self, request, obj=None):
        if not request.user.is_superuser and obj is not None:
            try:
                my_membership = ShopMembership.objects.get(
                    user=request.user,
                    shop=obj.shop,
                    status='APPROVED'
                )
                if my_membership.role == 'MEMBER':
                    return False
                if my_membership.role == 'ADMIN' and obj.role in ['CREATOR', 'ADMIN']:
                    return False
            except ShopMembership.DoesNotExist:
                return False
        return super().has_delete_permission(request, obj)

    @action(description="同意所选加入申请")
    def approve_applications(self, request, queryset):
        count = 0
        for membership in queryset:
            if membership.status == 'PENDING':
                membership.status = 'APPROVED'
                membership.save()
                count += 1
        if count > 0:
            self.message_user(request, f"成功同意 {count} 位成员的加入申请。", messages.SUCCESS)
        else:
            self.message_user(request, "选中的记录中没有待确认的申请。", messages.WARNING)

    @action(description="拒绝所选加入申请")
    def reject_applications(self, request, queryset):
        count = 0
        for membership in queryset:
            if membership.status == 'PENDING':
                membership.status = 'REJECTED'
                membership.save()
                count += 1
        if count > 0:
            self.message_user(request, f"已拒绝 {count} 位成员的加入申请。", messages.SUCCESS)
        else:
            self.message_user(request, "选中的记录中没有待确认的申请。", messages.WARNING)

    @action(description="提升为店铺管理员 (ADMIN)")
    def promote_to_admin(self, request, queryset):
        updated = 0
        for membership in queryset:
            if membership.status == 'APPROVED' and membership.role == 'MEMBER':
                membership.role = 'ADMIN'
                membership.save()
                updated += 1
        if updated > 0:
            self.message_user(request, f"已成功将 {updated} 位成员提升为店铺管理员。", messages.SUCCESS)
        else:
            self.message_user(request, "无合法的提升对象（成员需已加入且角色当前为普通成员）。", messages.WARNING)

    @action(description="降级为普通店铺成员 (MEMBER)")
    def demote_to_member(self, request, queryset):
        updated = 0
        for membership in queryset:
            if membership.status == 'APPROVED' and membership.role == 'ADMIN':
                membership.role = 'MEMBER'
                membership.save()
                updated += 1
        if updated > 0:
            self.message_user(request, f"已将 {updated} 位管理员降级为普通成员。", messages.SUCCESS)
        else:
            self.message_user(request, "无合法的降级对象（无法降级创建人或非管理员）。", messages.WARNING)
