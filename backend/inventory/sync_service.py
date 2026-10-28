"""Retained document writer. All accepted writes serialize on the shop row.

Immutable revision snapshots avoid timestamp clocks and unseen-page cursor races.
Existing stock is an opening balance; only subsequent document differences move it.
"""
import hashlib
import json
from collections import defaultdict
from pydantic import ValidationError
from django.db import transaction
from django.utils import timezone
from .models import (Product, InboundReceipt, InboundItem, OutboundOrder, OutboundItem,
                     OutboundAttachment, WarehouseStock, StockLedger, InboundActionLog,
                     ShopSyncState, SyncChange, SyncOperation, PrivateMedia)
from shops.models import Shop, ShopMembership
from .sync_schema import ProductData, InboundData, OutboundData, Operation

MODELS = {'product': Product, 'inbound': InboundReceipt, 'outbound': OutboundOrder, 'stock': WarehouseStock}
SCHEMAS = {'product': ProductData, 'inbound': InboundData, 'outbound': OutboundData}


class Rejected(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message


def money(value):
    return float(value) if value is not None else None


def record_for(kind, obj):
    if kind == 'product':
        data = dict(code=obj.code, name=obj.name, default_purchase_price=money(obj.default_purchase_price), default_sale_price=money(obj.default_sale_price))
    elif kind == 'stock':
        data = dict(product_code=obj.product_code, product_name=obj.product_name, quantity=obj.quantity)
    else:
        data = {'created_at': obj.created_at.isoformat()}
        data['items'] = []
        for line in obj.items.filter(is_deleted=False).order_by('client_key', 'id'):
            item = dict(id=line.client_key or str(line.id), product_code=line.product_code, product_name=line.product_name, quantity=line.quantity)
            if kind == 'inbound':
                item.update(purchase_price=money(line.purchase_price), sale_price=money(line.sale_price))
            data['items'].append(item)
        if kind == 'inbound':
            for field in ('tracking_number', 'seller_order_number', 'rebate_order_number', 'scheme_number', 'ocr_status', 'is_settled', 'image_sha256'):
                data[field] = getattr(obj, field)
        else:
            data.update(logistics_number=obj.logistics_number, note=obj.note, image_sha256s=list(obj.attachments.filter(is_deleted=False, image_sha256__isnull=False).order_by('client_key', 'id').values_list('image_sha256', flat=True)))
    key = obj.code if kind == 'product' else obj.product_code if kind == 'stock' else obj.client_key or str(obj.id)
    return {'kind': kind, 'id': key, 'revision': obj.revision, 'data': data}


def publish(state, kind, obj):
    state.revision += 1
    obj.revision = state.revision
    obj.save()
    record = record_for(kind, obj)
    SyncChange.objects.create(shop_id=state.shop_id, revision=state.revision, record=record)
    return record


def canonical(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(',', ':'), default=str)


def find_document(shop, kind, key):
    model = MODELS[kind]
    field = 'code' if kind == 'product' else 'client_key'
    return model.objects.filter(shop=shop, **{field: key}).first()


def quantities(lines):
    totals, names = defaultdict(int), {}
    for line in lines:
        totals[line['product_code']] += line['quantity']
        names[line['product_code']] = line['product_name']
    return totals, names


def write_document(state, user, operation, data, obj):
    shop, kind, key = state.shop, operation.kind, operation.id
    if obj and obj.is_deleted:
        raise Rejected('archived_record', 'This legacy archived record is retained and cannot be overwritten.')
    if kind == 'product':
        if data['code'] != key:
            raise Rejected('identity_mismatch', 'Product id must equal code.')
        obj = obj or Product(shop=shop, client_key=key)
        for field in ('code', 'name', 'default_purchase_price', 'default_sale_price'):
            setattr(obj, field, data[field])
        return publish(state, kind, obj)
    digests = [data['image_sha256']] if kind == 'inbound' and data['image_sha256'] else data.get('image_sha256s', [])
    if len(set(digests)) != len(digests):
        raise Rejected('duplicate_media', 'Duplicate attachment.')
    if PrivateMedia.objects.filter(shop=shop, sha256__in=digests).count() != len(digests):
        raise Rejected('media_missing', 'Upload all evidence images to this shop first.')
    if len({line['id'] for line in data['items']}) != len(data['items']):
        raise Rejected('duplicate_line', 'Line IDs must be unique within the document.')
    if kind == 'inbound' and InboundReceipt.objects.filter(shop=shop, tracking_number=data['tracking_number']).exclude(pk=obj.pk if obj else None).exists():
        raise Rejected('duplicate_tracking', 'Tracking number is already retained by this shop.')
    old_lines = list(obj.items.filter(is_deleted=False).values('product_code', 'product_name', 'quantity')) if obj else []
    old, old_names = quantities(old_lines)
    new, names = quantities(data['items'])
    names = {**old_names, **names}
    factor = 1 if kind == 'inbound' else -1
    deltas = {code: factor * (new[code] - old[code]) for code in old.keys() | new.keys()}
    stocks = {}
    for code in sorted(deltas):
        stock, _ = WarehouseStock.objects.get_or_create(shop=shop, product_code=code, defaults={'client_key': code, 'product_name': names[code]})
        if stock.quantity + deltas[code] < 0:
            raise Rejected('insufficient_stock', f'Insufficient stock for {code}.')
        stocks[code] = stock
    created = obj is None
    obj = obj or MODELS[kind](shop=shop, client_key=key)
    fields = ('tracking_number', 'seller_order_number', 'rebate_order_number', 'scheme_number', 'created_at', 'ocr_status', 'is_settled', 'image_sha256') if kind == 'inbound' else ('logistics_number', 'note', 'created_at')
    for field in fields:
        setattr(obj, field, data[field])
    obj.save()
    line_model, parent_field = (InboundItem, 'receipt') if kind == 'inbound' else (OutboundItem, 'order')
    obj.items.update(is_deleted=True)
    for line in data['items']:
        existing = line_model.objects.filter(shop=shop, client_key=line['id']).first()
        if existing and getattr(existing, parent_field + '_id') != obj.id:
            raise Rejected('line_parent_mismatch', 'A line ID already belongs to another document.')
        existing = existing or line_model(shop=shop, client_key=line['id'], **{parent_field: obj})
        existing.is_deleted = False
        for field, value in line.items():
            if field != 'id':
                setattr(existing, field, value)
        existing.save()
    if kind == 'outbound':
        obj.attachments.update(is_deleted=True)
        for index, digest in enumerate(digests):
            OutboundAttachment.objects.update_or_create(shop=shop, order=obj, image_sha256=digest, defaults={'is_deleted': False, 'client_key': f'{index:03d}', 'image_path': f'sync://{digest}', 'created_at': obj.created_at})
    for code, delta in deltas.items():
        if not delta:
            continue
        stock = stocks[code]
        stock.quantity += delta
        stock.product_name = names[code]
        StockLedger.objects.create(shop=shop, product_code=code, product_name=names[code], delta=delta, reason=kind, source_id=key, created_at=timezone.now())
        publish(state, 'stock', stock)
    if kind == 'inbound':
        InboundActionLog.objects.create(shop=shop, user=user, action_type='CREATE' if created else 'UPDATE', tracking_number=obj.tracking_number, detail='Sync v2 retained whole-document operation')
    return publish(state, kind, obj)


def invalid_data_message(error):
    errors = error.errors(include_input=False, include_url=False)
    return 'Invalid data: ' + '; '.join('.'.join(str(part) for part in issue['loc']) + ': ' + issue['msg'] for issue in errors[:5])


def apply_operation(shop, user, device_id, operation):
    """Each operation has its own durable outcome; rejects roll back its document only."""
    raw = operation.model_dump(mode='json') if isinstance(operation, Operation) else operation
    request_hash = hashlib.sha256(canonical(raw).encode()).hexdigest()
    supplied_id = raw.get('operation_id')
    valid_id = isinstance(supplied_id, str) and 1 <= len(supplied_id) <= 200
    # Malformed identity still receives a durable audit receipt keyed by its exact bytes.
    operation_id = supplied_id if valid_id else 'invalid-envelope:' + request_hash
    result_id = supplied_id if valid_id else ''
    try:
        operation = Operation.model_validate(raw)
        metadata_error = None
    except ValidationError as error:
        operation = None
        metadata_error = invalid_data_message(error)
    with transaction.atomic():
        # Lock an existing Shop, not get_or_create(state), to serialize first writes too.
        locked_shop = Shop.objects.select_for_update().get(pk=shop.pk)
        # 鉴权后仍可能被撤销管理身份，写入锁内再次核对角色。
        if not ShopMembership.objects.filter(
            shop=locked_shop, user=user, status='APPROVED', role__in=['CREATOR', 'ADMIN'],
        ).exists():
            raise Rejected('membership_revoked', '当前账号已不具备本店库存管理权限。')
        state, _ = ShopSyncState.objects.get_or_create(shop=locked_shop)
        previous = SyncOperation.objects.filter(shop=shop, operation_id=operation_id).first()
        if previous:
            if previous.request_hash != request_hash:
                current = find_document(shop, operation.kind, operation.id) if operation else None
                result = {'operation_id': result_id, 'status': 'conflict', 'revision': current.revision if current else 0, 'code': 'operation_id_reused', 'message': 'Operation ID reused with different payload.'}
                if current:
                    result['record'] = record_for(operation.kind, current)
                return result
            result = dict(previous.result)
            if result['status'] == 'applied':
                result['status'] = 'duplicate'
            return result
        if metadata_error:
            result = {'operation_id': result_id, 'status': 'conflict', 'revision': 0, 'code': 'invalid_data', 'message': metadata_error}
            SyncOperation.objects.create(shop=shop, device_id=device_id, operation_id=operation_id, request_hash=request_hash, result=result)
            return result
        obj = find_document(shop, operation.kind, operation.id)
        result = {'operation_id': result_id, 'status': 'conflict', 'revision': obj.revision if obj else 0}
        try:
            data = SCHEMAS[operation.kind].model_validate(operation.data).model_dump()
            if obj and operation.base_revision == 0 and not obj.is_deleted:
                current_data = SCHEMAS[operation.kind].model_validate(record_for(operation.kind, obj)['data']).model_dump()
                if operation.kind != 'product':
                    current_data['items'].sort(key=lambda item: item['id'])
                    data['items'].sort(key=lambda item: item['id'])
                else:
                    # Client clocks are metadata, never identity or concurrency tokens.
                    for field in ('created_at', 'updated_at'):
                        current_data.pop(field, None)
                        data.pop(field, None)
                if current_data == data:
                    result.update(status='duplicate', revision=obj.revision, record=record_for(operation.kind, obj))
                    SyncOperation.objects.create(shop=shop, device_id=device_id, operation_id=operation_id, request_hash=request_hash, result=result)
                    return result
            if obj and operation.base_revision != obj.revision:
                # Never trust a stale or zero-base update; identical retry op IDs are handled above.
                raise Rejected('revision_conflict', 'Record has changed; review the retained current version.')
            if not obj and operation.base_revision != 0:
                raise Rejected('record_missing', 'Cannot update a missing record.')
            with transaction.atomic():
                record = write_document(state, user, operation, data, obj)
                state.save(update_fields=['revision'])
            result.update(status='applied', revision=record['revision'], record=record)
        except (Rejected, ValidationError) as error:
            if isinstance(error, ValidationError):
                result.update(code='invalid_data', message=invalid_data_message(error))
            else:
                result.update(code=error.code, message=error.message)
            if obj:
                obj.refresh_from_db()
                result['record'] = record_for(operation.kind, obj)
        SyncOperation.objects.create(shop=shop, device_id=device_id, operation_id=operation_id, request_hash=request_hash, result=result)
        return result
