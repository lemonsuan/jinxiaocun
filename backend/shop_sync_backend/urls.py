"""
URL configuration for shop_sync_backend project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/5.2/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
from django.contrib import admin
from django.urls import path
from django.views.generic import RedirectView
from django.shortcuts import render
from shops.models import ShopMembership, Shop
from .api import api

# 动态重写 Django Admin 首页视图以支持“店铺卡片网格首页”
def custom_admin_index(request, extra_context=None):
    if not request.user.is_authenticated:
        return admin.site.login(request, extra_context)
        
    if request.user.is_superuser:
        my_shops = Shop.objects.all()
    else:
        my_shop_ids = ShopMembership.objects.filter(
            user=request.user,
            role__in=['CREATOR', 'ADMIN'],
            status='APPROVED'
        ).values_list('shop_id', flat=True)
        my_shops = Shop.objects.filter(id__in=my_shop_ids)
        
    context = {
        **(extra_context or {}),
        'my_shops': my_shops,
        'title': '店铺管理控制台',
    }
    return render(request, 'admin/index.html', context)

admin.site.index = custom_admin_index

urlpatterns = [
    path('', RedirectView.as_view(url='/admin/', permanent=True)),
    path('admin/', admin.site.urls),
    path('api/', api.urls),
]
