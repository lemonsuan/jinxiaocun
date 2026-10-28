"""本店入库单的有界批量查图与整批商品汇总，不写业务数据。"""
import re
from typing import Annotated

from django.db import transaction
from django.db.models import Case, CharField, Count, F, Min, Prefetch, Q, Sum, Value, When
from django.db.models.functions import Cast, Concat
from ninja import Body, Router
from ninja.errors import HttpError
from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt, StrictStr, ValidationError

from shops.models import Shop, ShopMembership
from .models import InboundItem, InboundReceipt

router = Router()


class BatchQuery(BaseModel):
    model_config = ConfigDict(extra='forbid')

    tracking_numbers: Annotated[list[StrictStr], Field(min_length=1, max_length=2000)]
    page: Annotated[StrictInt, Field(ge=1)] = 1
    page_size: Annotated[StrictInt, Field(ge=1, le=20)] = 12
    product_page: Annotated[StrictInt, Field(ge=1)] = 1
    product_page_size: Annotated[StrictInt, Field(ge=1, le=100)] = 50
    include_archived: StrictBool = False


def parse_tracking_numbers(values):
    if sum(len(value) for value in values) > 60000:
        raise HttpError(400, '输入内容过长，每次最多查询200个快递单号。')
    tokens = []
    for value in values:
        tokens.extend(token for token in re.split(r'[\s,，;；]+', value.strip()) if token)
    ordered = list(dict.fromkeys(tokens))
    if not ordered:
        raise HttpError(400, '请至少输入一个快递单号。')
    if len(ordered) > 200:
        raise HttpError(400, '每次最多查询200个不同的快递单号。')
    if any(len(number) > 100 for number in ordered):
        raise HttpError(400, '单个快递单号不能超过100个字符。')
    return ordered, len(tokens) - len(ordered)


def inbound_record(receipt):
    data = {
        field: getattr(receipt, field)
        for field in (
            'tracking_number', 'seller_order_number', 'rebate_order_number',
            'scheme_number', 'ocr_status', 'is_settled', 'image_sha256',
        )
    }
    data['created_at'] = receipt.created_at.isoformat()
    data['items'] = [
        {
            'id': line.client_key or str(line.pk),
            'product_code': line.product_code,
            'product_name': line.product_name,
            'quantity': line.quantity,
            'purchase_price': float(line.purchase_price) if line.purchase_price is not None else None,
            'sale_price': float(line.sale_price) if line.sale_price is not None else None,
        }
        for line in receipt.batch_items
    ]
    return {
        'kind': 'inbound', 'id': receipt.client_key or str(receipt.pk),
        'revision': receipt.revision, 'data': data,
    }


def page_result(items, total, page, page_size):
    return {'items': items, 'total': total, 'page': page, 'page_size': page_size}


def build_batch(shop, query):
    numbers, duplicate_count = parse_tracking_numbers(query.tracking_numbers)
    receipts = InboundReceipt.objects.filter(shop=shop, tracking_number__in=numbers)
    if not query.include_archived:
        receipts = receipts.filter(is_deleted=False)
    matches = dict(receipts.values_list('tracking_number', 'id'))
    matched_numbers = [number for number in numbers if number in matches]
    receipt_ids = list(matches.values())
    tracking_by_receipt = {receipt_id: number for number, receipt_id in matches.items()}
    # 空白编码按原明细分组，不以相同商品名猜测它们是否同一件商品。
    items = InboundItem.objects.filter(
        shop=shop, receipt_id__in=receipt_ids, is_deleted=False,
    ).annotate(batch_key=Case(
        When(product_code__regex=r'^\s*$', then=Concat(Value('line:'), Cast('id', output_field=CharField()))),
        default=Concat(Value('code:'), F('product_code')),
        output_field=CharField(),
    ))
    totals = items.aggregate(product_count=Count('batch_key', distinct=True), total_quantity=Sum('quantity'))
    grouped = items.values('batch_key').annotate(
        product_code=Min('product_code'), product_name=Min('product_name'),
        quantity=Sum('quantity'), receipt_count=Count('receipt_id', distinct=True),
    ).order_by('batch_key')
    start = (query.product_page - 1) * query.product_page_size
    product_rows = grouped[start:start + query.product_page_size] if start < totals['product_count'] else []
    products = [dict(row, key=row['batch_key'], tracking_numbers=[], name_variants=[]) for row in product_rows]
    keys = [row['key'] for row in products]
    variants = {key: set() for key in keys}
    sources = {key: set() for key in keys}
    if keys:
        for key, name, receipt_id in items.filter(batch_key__in=keys).order_by().values_list('batch_key', 'product_name', 'receipt_id').distinct():
            variants[key].add(name)
            sources[key].add(tracking_by_receipt[receipt_id])
    for row in products:
        row.pop('batch_key')
        row['name_variants'] = sorted(variants[row['key']])
        row['tracking_numbers'] = [number for number in matched_numbers if number in sources[row['key']]]
    start = (query.page - 1) * query.page_size
    current_numbers = matched_numbers[start:start + query.page_size]
    current_ids = [matches[number] for number in current_numbers]
    current_receipts = InboundReceipt.objects.filter(shop=shop, pk__in=current_ids).prefetch_related(Prefetch(
        'items',
        queryset=InboundItem.objects.filter(shop=shop, is_deleted=False).order_by('client_key', 'id'),
        to_attr='batch_items',
    ))
    current = {receipt.pk: receipt for receipt in current_receipts}
    documents = [inbound_record(current[receipt_id]) for receipt_id in current_ids]
    return {
        'tracking_numbers': numbers,
        'duplicate_count': duplicate_count,
        'unmatched_numbers': [number for number in numbers if number not in matches],
        'matched_count': len(matches),
        'documents': page_result(documents, len(matches), query.page, query.page_size),
        'products': page_result(products, totals['product_count'], query.product_page, query.product_page_size),
        'totals': {
            'document_count': len(matches),
            'product_count': totals['product_count'],
            'total_quantity': totals['total_quantity'] or 0,
        },
    }


@router.post('/view/inbound/batch')
def batch_inbound(request, data: Body[dict]):
    shop = getattr(request, 'active_shop', None)
    if shop is None:
        raise HttpError(400, '请先选择店铺。')
    try:
        query = BatchQuery.model_validate(data)
    except ValidationError:
        raise HttpError(422, '批量查询参数无效，请检查单号列表和分页范围。')
    with transaction.atomic():
        # 与入库写入共用店铺锁，单据分页和整批汇总读取同一版本。
        shop = Shop.objects.select_for_update().get(pk=shop.pk)
        if not ShopMembership.objects.filter(
            shop=shop, user=request.user, status='APPROVED', role__in=['CREATOR', 'ADMIN'],
        ).exists():
            raise HttpError(403, '只有本店创建人或管理员可批量查看入库单。')
        return build_batch(shop, query)
