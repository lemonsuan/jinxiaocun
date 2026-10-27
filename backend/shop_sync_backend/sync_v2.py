"""Authenticated incremental sync and read-only shop archive endpoints."""
import re
from datetime import date
from pathlib import Path
from django.conf import settings
from django.db.models import Q
from django.http import FileResponse
from ninja import Router, File, Form, Body
from ninja.files import UploadedFile
from ninja.errors import HttpError
from pydantic import ValidationError
from inventory.models import (ShopSyncState, SyncChange, PrivateMedia, InboundActionLog, StockLedger)
from inventory.media import store_image, MAX_IMAGE_BYTES
from inventory.sync_schema import Push
from inventory.sync_service import MODELS, apply_operation, record_for, Rejected

router = Router()


def shop_for(request):
    if not request.active_shop:
        raise HttpError(400, 'X-Active-Shop-ID is required')
    return request.active_shop


def revision(shop):
    return ShopSyncState.objects.filter(shop=shop).values_list('revision', flat=True).first() or 0


@router.post('/sync/v2/push')
def push(request, data: Body[dict]):
    shop = shop_for(request)
    try:
        payload = Push.model_validate(data)
    except ValidationError as error:
        raise HttpError(422, str(error))
    results = []
    for operation in payload.operations:
        try:
            results.append(apply_operation(shop, request.user, payload.device_id, operation))
        except Rejected as error:
            raise HttpError(403, error.message)
    return {'results': results, 'server_revision': revision(shop)}


@router.get('/sync/v2/pull')
def pull(request, cursor: int = 0, limit: int = 100):
    shop = shop_for(request)
    if cursor < 0 or not 1 <= limit <= 200:
        raise HttpError(400, 'Invalid cursor or limit (1..200).')
    upper = revision(shop)
    if cursor > upper:
        raise HttpError(409, 'Cursor exceeds shop revision; reset this scope cursor.')
    rows = list(SyncChange.objects.filter(shop=shop, revision__gt=cursor, revision__lte=upper).order_by('revision')[:limit + 1])
    page = rows[:limit]
    return {'changes': [row.record for row in page], 'cursor': page[-1].revision if page else cursor, 'has_more': len(rows) > limit, 'server_revision': upper}


def media_path(shop, digest):
    if not re.fullmatch(r'[a-f0-9]{64}', digest):
        raise HttpError(404, 'Image not found.')
    return Path(settings.PRIVATE_MEDIA_ROOT) / str(shop.id) / digest


def media_metadata(shop, digest):
    media_path(shop, digest)
    obj = PrivateMedia.objects.filter(shop=shop, sha256=digest).first()
    if not obj:
        raise HttpError(404, 'Image not found.')
    return obj


@router.post('/sync/v2/media')
def upload_media(request, file: File[UploadedFile], sha256: Form[str | None] = None):
    shop = shop_for(request)
    if file.size > MAX_IMAGE_BYTES:
        raise HttpError(413, 'Image exceeds 15 MiB.')
    content = file.read(MAX_IMAGE_BYTES + 1)
    if len(content) > MAX_IMAGE_BYTES or not content:
        raise HttpError(413, 'Image size is invalid.')
    try:
        obj = store_image(shop, content, sha256)
    except ValueError as error:
        raise HttpError(400, str(error))
    return {'sha256': obj.sha256, 'size': obj.size, 'content_type': obj.content_type}


@router.get('/sync/v2/media/{sha256}/exists')
def media_exists(request, sha256: str):
    shop = shop_for(request)
    obj = media_metadata(shop, sha256)
    if not media_path(shop, sha256).is_file():
        raise HttpError(404, 'Archived image bytes are unavailable.')
    return {'exists': True, 'sha256': sha256, 'size': obj.size, 'content_type': obj.content_type}


@router.get('/sync/v2/media/{sha256}')
def download_media(request, sha256: str):
    shop = shop_for(request)
    obj = media_metadata(shop, sha256)
    try:
        stream = media_path(shop, sha256).open('rb')
    except FileNotFoundError:
        raise HttpError(404, 'Archived image bytes are unavailable.')
    response = FileResponse(stream, content_type=obj.content_type)
    response['Cache-Control'] = 'private, no-store'
    response['X-Content-Type-Options'] = 'nosniff'
    return response


@router.get('/view/inbound/{id}')
def inbound_detail(request, id: str):
    return detail(request, 'inbound', id)


@router.get('/view/outbound/{id}')
def outbound_detail(request, id: str):
    return detail(request, 'outbound', id)


def detail(request, kind, key):
    shop = shop_for(request)
    if len(key) > 200:
        raise HttpError(404, 'Document not found.')
    obj = MODELS[kind].objects.filter(shop=shop, client_key=key).first()
    if not obj:
        raise HttpError(404, 'Document not found.')
    return record_for(kind, obj)


@router.get('/view/{collection}')
def view_list(request, collection: str, page: int = 1, page_size: int = 50,
              q: str | None = None, date_from: date | None = None,
              date_to: date | None = None, is_settled: bool | None = None,
              include_archived: bool = False):
    shop = shop_for(request)
    if page < 1 or not 1 <= page_size <= 100 or (q and len(q) > 200):
        raise HttpError(400, 'Invalid pagination or search query.')
    kinds = {'products': 'product', 'inbound': 'inbound', 'outbound': 'outbound', 'stocks': 'stock'}
    if collection in kinds:
        kind = kinds[collection]
        rows = MODELS[kind].objects.filter(shop=shop)
        if not include_archived:
            rows = rows.filter(is_deleted=False)
        search = {'product': ['code', 'name'], 'inbound': ['tracking_number', 'seller_order_number', 'rebate_order_number', 'scheme_number', 'items__product_code', 'items__product_name'], 'outbound': ['logistics_number', 'note', 'items__product_code', 'items__product_name'], 'stock': ['product_code', 'product_name']}[kind]
    elif collection in ('ledger', 'logs'):
        rows = (StockLedger if collection == 'ledger' else InboundActionLog).objects.filter(shop=shop)
        search = ['product_code', 'product_name', 'source_id'] if collection == 'ledger' else ['tracking_number', 'detail', 'user__username']
        kind = None
    else:
        raise HttpError(404, 'Unknown collection.')
    if q:
        condition = Q()
        for field in search:
            condition |= Q(**{field + '__icontains': q})
        rows = rows.filter(condition).distinct()
    date_field = 'created_at' if collection in ('inbound', 'outbound', 'ledger', 'logs') else 'updated_at'
    if date_from:
        rows = rows.filter(**{date_field + '__date__gte': date_from})
    if date_to:
        rows = rows.filter(**{date_field + '__date__lte': date_to})
    if is_settled is not None and collection == 'inbound':
        rows = rows.filter(is_settled=is_settled)
    total = rows.count()
    rows = rows.order_by('-' + date_field, 'id')[(page - 1) * page_size:page * page_size]
    if kind:
        items = [record_for(kind, row) if kind != 'stock' else record_for(kind, row)['data'] for row in rows]
    elif collection == 'ledger':
        items = [dict(id=str(row.id), product_code=row.product_code, product_name=row.product_name, delta=row.delta, reason=row.reason, source_id=row.source_id, created_at=row.created_at.isoformat()) for row in rows]
    else:
        items = [dict(id=str(row.id), username=row.user.username if row.user else None, action_type=row.action_type, tracking_number=row.tracking_number, detail=row.detail, created_at=row.created_at.isoformat()) for row in rows.select_related('user')]
    return dict(items=items, total=total, page=page, page_size=page_size)
