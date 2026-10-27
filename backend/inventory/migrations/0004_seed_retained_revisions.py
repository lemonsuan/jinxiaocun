"""Keep all legacy UUID rows and opening stock, seed only live sync snapshots.

No inventory reconstruction: historical manually adjusted balances remain unchanged.
Archived rows remain available through include_archived in the read-only viewer.
"""
from django.db import migrations
from django.db.models import Sum
from django.utils import timezone


def seed(apps, schema_editor):
    db = schema_editor.connection.alias
    model_names = ['Product', 'InboundReceipt', 'InboundItem', 'OutboundOrder', 'OutboundItem', 'OutboundAttachment', 'StockLedger', 'WarehouseStock']
    for name in model_names:
        model = apps.get_model('inventory', name)
        for obj in model.objects.using(db).iterator():
            obj.client_key = obj.code if name == 'Product' else obj.product_code if name == 'WarehouseStock' else str(obj.id)
            obj.save(using=db, update_fields=['client_key'])
    # Preserve historical entries and reconcile the retained opening summary explicitly.
    Ledger = apps.get_model('inventory', 'StockLedger')
    for stock in apps.get_model('inventory', 'WarehouseStock').objects.using(db).filter(is_deleted=False).iterator():
        prior = Ledger.objects.using(db).filter(shop_id=stock.shop_id, product_code=stock.product_code, is_deleted=False).aggregate(total=Sum('delta'))['total'] or 0
        if stock.quantity != prior:
            Ledger.objects.using(db).create(shop_id=stock.shop_id, product_code=stock.product_code, product_name=stock.product_name, delta=stock.quantity-prior, reason='adjustment', source_id='sync-v2-opening-balance', created_at=timezone.now())
    State = apps.get_model('inventory', 'ShopSyncState')
    Change = apps.get_model('inventory', 'SyncChange')
    for shop in apps.get_model('shops', 'Shop').objects.using(db).iterator():
        revision = 0
        for kind, name in [('product', 'Product'), ('inbound', 'InboundReceipt'), ('outbound', 'OutboundOrder'), ('stock', 'WarehouseStock')]:
            model = apps.get_model('inventory', name)
            for obj in model.objects.using(db).filter(shop_id=shop.pk, is_deleted=False).order_by('id').iterator():
                revision += 1
                obj.revision = revision
                obj.save(using=db, update_fields=['revision'])
                if kind == 'product':
                    data = dict(code=obj.code, name=obj.name, default_purchase_price=float(obj.default_purchase_price) if obj.default_purchase_price is not None else None, default_sale_price=float(obj.default_sale_price) if obj.default_sale_price is not None else None)
                elif kind == 'stock':
                    data = dict(product_code=obj.product_code, product_name=obj.product_name, quantity=obj.quantity)
                else:
                    data = dict(created_at=obj.created_at.isoformat(), items=[])
                    line_model = apps.get_model('inventory', 'InboundItem' if kind == 'inbound' else 'OutboundItem')
                    parent = 'receipt_id' if kind == 'inbound' else 'order_id'
                    for line in line_model.objects.using(db).filter(shop_id=shop.pk, is_deleted=False, **{parent: obj.id}).order_by('client_key'):
                        item = dict(id=line.client_key, product_code=line.product_code, product_name=line.product_name, quantity=line.quantity)
                        if kind == 'inbound':
                            item.update(purchase_price=float(line.purchase_price) if line.purchase_price is not None else None, sale_price=float(line.sale_price) if line.sale_price is not None else None)
                        data['items'].append(item)
                    if kind == 'inbound':
                        for field in ['tracking_number', 'seller_order_number', 'rebate_order_number', 'scheme_number', 'ocr_status', 'is_settled', 'image_sha256']:
                            data[field] = getattr(obj, field)
                    else:
                        data.update(logistics_number=obj.logistics_number, note=obj.note, image_sha256s=[])
                record = dict(kind=kind, id=obj.client_key, revision=revision, data=data)
                Change.objects.using(db).create(shop_id=shop.pk, revision=revision, record=record)
        State.objects.using(db).create(shop_id=shop.pk, revision=revision)


class Migration(migrations.Migration):
    dependencies = [('inventory', '0003_shopsyncstate_inbounditem_client_key_and_more')]
    operations = [migrations.RunPython(seed, migrations.RunPython.noop)]
