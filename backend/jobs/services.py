"""作业写入、身份边界及订单到货/结算的事务规则。"""
import hashlib
import json
from django.db import transaction
from django.db.models import Count, Exists, F, OuterRef, Prefetch, Q, Subquery
from django.db.models.functions import Coalesce
from django.utils import timezone
from ninja.errors import HttpError
from inventory.models import InboundItem, InboundReceipt, PrivateMedia
from shops.models import Shop, ShopMembership
from .models import (Job, JobAudit, JobOrder, JobOrderPhoto, JobParcel, JobPhoto,
                     OperationReceipt, Settlement, WorkerAccount, WorkerMediaUpload, WorkerPayoutProfile)


def require_admin(request):
    shop = getattr(request, 'active_shop', None)
    if not shop or not ShopMembership.objects.filter(shop=shop, user=request.user,
            status='APPROVED', role__in=['CREATOR', 'ADMIN']).exists():
        raise HttpError(403, '只有本店创建人或管理员可以管理作业和拍手。')
    return shop


def lock_shop(shop):
    # 与库存同步使用相同首锁，避免报单、结算和入库更新交叉死锁。
    return Shop.objects.select_for_update().get(pk=shop.pk)


def lock_admin_shop(request):
    shop = lock_shop(require_admin(request))
    # 等待店铺锁期间管理员资格可能被撤销，持有成员锁后再决定是否允许写入。
    membership = ShopMembership.objects.select_for_update().filter(
        shop=shop, user=request.user, status='APPROVED', role__in=['CREATOR', 'ADMIN'],
    ).first()
    if membership is None:
        raise HttpError(403, '只有本店创建人或管理员可以管理作业和拍手。')
    return shop


def live_worker(request):
    worker = WorkerAccount.objects.select_for_update().select_related('shop').get(pk=request.worker.pk)
    if not worker.is_active:
        raise HttpError(403, '该拍手账号已被本店禁用，请联系管理员。')
    if worker.auth_version != request.worker_auth_version:
        raise HttpError(401, '登录已失效，请重新登录本店拍手账号。')
    return worker


def valid_version(obj, expected):
    if obj.version != expected:
        raise HttpError(409, '内容已被更新，请刷新核对后重试；当前未保存输入请保留。')


def worker_data(worker, admin=False):
    result = {'id': str(worker.pk), 'username': worker.username, 'display_name': worker.display_name,
              'shop_number': str(worker.shop.shop_number), 'shop_name': worker.shop.name}
    if admin:
        result.update(phone=worker.phone, enabled=worker.is_active, version=worker.auth_version,
                      created_at=worker.created_at.isoformat(), updated_at=worker.updated_at.isoformat())
    return result


def job_query(shop):
    return Job.objects.filter(shop=shop).prefetch_related('photos__media')


def visible_jobs(worker):
    return job_query(worker.shop).filter(Q(status='open') | Q(orders__worker=worker)).distinct()


def job_data(job, worker=None):
    result = {'id': str(job.pk), 'shop_number': str(job.shop.shop_number), 'title': job.title,
              'description': job.description, 'status': job.status, 'cost_amount': format(job.cost_amount, '.2f'),
              'refund_amount': format(job.refund_amount, '.2f'),
              'photos': [{'sha256': photo.media.sha256} for photo in job.photos.all()],
              'version': job.version, 'created_at': job.created_at.isoformat(), 'updated_at': job.updated_at.isoformat()}
    if worker:
        result['own_order_count'] = getattr(job, '_own_order_count', None)
        if result['own_order_count'] is None:
            result['own_order_count'] = job.orders.filter(worker=worker).count()
        result['can_report'] = job.status == 'open'
    else:
        result['order_count'] = getattr(job, '_order_count', None)
        if result['order_count'] is None:
            result['order_count'] = job.orders.count()
    return result


def order_query(shop):
    active = JobParcel.objects.filter(order_id=OuterRef('pk'), is_active=True)
    arrived = active.annotate(_arrived=Exists(InboundReceipt.objects.filter(
        shop_id=OuterRef('shop_id'), tracking_number=OuterRef('tracking_number'), is_deleted=False)))
    return JobOrder.objects.filter(shop=shop).select_related('job', 'job__shop', 'worker', 'worker__shop').annotate(
        _parcel_count=Coalesce(Subquery(active.values('order_id').annotate(n=Count('id')).values('n')[:1]), 0),
        _arrived_count=Coalesce(Subquery(arrived.filter(_arrived=True).values('order_id').annotate(n=Count('id')).values('n')[:1]), 0),
        _has_settlement=Exists(Settlement.objects.filter(order_id=OuterRef('pk'), is_active=True)),
    ).prefetch_related(
        Prefetch('parcels', queryset=JobParcel.objects.filter(is_active=True), to_attr='current_parcels'),
        Prefetch('photos', queryset=JobOrderPhoto.objects.select_related('media'), to_attr='supplemental_photos'))


def filter_order_status(rows, status):
    if not status:
        return rows
    if status == 'settled':
        return rows.filter(_has_settlement=True)
    if status == 'arrived':
        return rows.filter(_has_settlement=False, _parcel_count__gt=0, _arrived_count=F('_parcel_count'))
    if status == 'in_transit':
        return rows.filter(_has_settlement=False).filter(Q(_parcel_count=0) | ~Q(_arrived_count=F('_parcel_count')))
    raise HttpError(400, '订单状态无效。')


def receipt_map(shop, numbers, lock=False):
    rows = InboundReceipt.objects.filter(shop=shop, is_deleted=False, tracking_number__in=numbers)
    if lock:
        rows = rows.select_for_update()
    return {row.tracking_number: row for row in rows.prefetch_related(
        Prefetch('items', queryset=InboundItem.objects.filter(is_deleted=False).order_by('client_key', 'id'), to_attr='live_items'))}


def receipt_data(receipt):
    return {'receipt_id': str(receipt.pk), 'document_key': receipt.client_key or str(receipt.pk),
            'revision': receipt.revision, 'image_sha256': receipt.image_sha256,
            'created_at': receipt.created_at.isoformat(),
            'items': [{'product_code': item.product_code, 'product_name': item.product_name,
                       'quantity': item.quantity,
                       'purchase_price': format(item.purchase_price, '.2f') if item.purchase_price is not None else None,
                       'sale_price': format(item.sale_price, '.2f') if item.sale_price is not None else None}
                      for item in receipt.live_items]}


def product_summary(receipts):
    products = {}
    for receipt in receipts:
        for item in receipt.live_items:
            key = item.product_code or f'uncoded:{item.pk}'
            if key not in products:
                products[key] = {'key': key, 'product_code': item.product_code,
                                 'product_name': item.product_name, 'quantity': 0,
                                 'tracking_numbers': [], 'name_variants': []}
            product = products[key]
            product['quantity'] += item.quantity
            if receipt.tracking_number not in product['tracking_numbers']:
                product['tracking_numbers'].append(receipt.tracking_number)
            if item.product_name not in product['name_variants']:
                product['name_variants'].append(item.product_name)
    return list(products.values())


def settlement_data(settlement):
    return {'id': str(settlement.pk), 'cost_amount': format(settlement.cost_amount, '.2f'),
            'refund_amount': format(settlement.refund_amount, '.2f'), 'is_active': settlement.is_active,
            'created_at': settlement.created_at.isoformat(),
            'operator': settlement.operator.username if settlement.operator else None,
            'snapshot': settlement.snapshot,
            'reopened_at': settlement.reopened_at.isoformat() if settlement.reopened_at else None,
            'reopen_reason': settlement.reopen_reason}


def serialize_orders(orders, admin=False, detail=False):
    orders = list(orders)
    if not orders:
        return []
    shop = orders[0].shop
    numbers = {parcel.tracking_number for order in orders for parcel in order.current_parcels}
    receipts = receipt_map(shop, numbers)
    settlements = {row.order_id: row for row in Settlement.objects.filter(order_id__in=[o.pk for o in orders], is_active=True).select_related('operator')}
    claims = {}
    if admin:
        claims = dict(JobParcel.objects.filter(shop=shop, is_active=True, tracking_number__in=numbers)
                      .values('tracking_number').annotate(n=Count('order_id', distinct=True)).values_list('tracking_number', 'n'))
    results = []
    for order in orders:
        parcels = []
        for parcel in order.current_parcels:
            receipt = receipts.get(parcel.tracking_number)
            entry = {'id': str(parcel.pk), 'tracking_number': parcel.tracking_number,
                     'arrived': receipt is not None, 'arrived_at': receipt.created_at.isoformat() if receipt else None}
            if admin:
                entry['duplicate_claim'] = claims.get(parcel.tracking_number, 0) > 1
                if detail:
                    entry['receipt'] = receipt_data(receipt) if receipt else None
            parcels.append(entry)
        settled = settlements.get(order.pk)
        arrived_count = sum(p['arrived'] for p in parcels)
        status = 'settled' if settled else 'arrived' if parcels and arrived_count == len(parcels) else 'in_transit'
        result = {'id': str(order.pk), 'job': {'id': str(order.job_id), 'title': order.job.title,
                  'status': order.job.status, 'version': order.job.version,
                  'cost_amount': format(order.job.cost_amount, '.2f'), 'refund_amount': format(order.job.refund_amount, '.2f')},
                  'order_number': order.order_number, 'note': order.note,
                  'photos': order_photo_data(order), 'version': order.version, 'status': status,
                  'parcel_count': len(parcels), 'arrived_count': arrived_count, 'parcels': parcels,
                  'settled_at': settled.created_at.isoformat() if settled else None,
                  'created_at': order.created_at.isoformat(), 'updated_at': order.updated_at.isoformat()}
        if not admin:
            result['settlement'] = {'cost_amount': format(settled.cost_amount, '.2f'), 'refund_amount': format(settled.refund_amount, '.2f'), 'settled_at': settled.created_at.isoformat()} if settled else None
        if admin:
            result['worker'] = {'id': str(order.worker_id), 'username': order.worker.username, 'display_name': order.worker.display_name}
            if detail:
                result['products'] = product_summary([receipts[p.tracking_number] for p in order.current_parcels if p.tracking_number in receipts])
                history = list(order.settlements.select_related('operator').order_by('-created_at'))
                result['settlement'] = settlement_data(settled) if settled else None
                result['settlement_history'] = [settlement_data(row) for row in history]
                result['payout'] = settled.snapshot.get('payout') if settled else payout_data(order.worker)
                result['payout_is_snapshot'] = settled is not None
                result['evidence_changed'] = bool(settled and settled.snapshot.get('evidence') != evidence_for(order.current_parcels, receipts))
        results.append(result)
    return results


def one_order(shop, pk, worker=None, admin=False):
    rows = order_query(shop).filter(pk=pk)
    if worker:
        rows = rows.filter(worker=worker)
    order = rows.first()
    if not order:
        raise HttpError(404, '找不到该订单。')
    return serialize_orders([order], admin=admin, detail=admin)[0]


def audit(shop, action, *, job=None, order=None, worker=None, operator=None, detail=None):
    JobAudit.objects.create(shop=shop, action=action, job=job, order=order, worker=worker,
                            operator=operator, detail=detail or {})


def _job_fields(data):
    return {field: getattr(data, field) for field in ['title', 'description', 'cost_amount', 'refund_amount', 'status']}


def _replace_photos(job, digests):
    media = {m.sha256: m for m in PrivateMedia.objects.filter(shop=job.shop, sha256__in=digests)}
    if len(media) != len(digests):
        raise HttpError(400, '请先上传全部作业照片到当前店铺。')
    job.photos.all().delete()
    JobPhoto.objects.bulk_create([JobPhoto(job=job, media=media[digest], position=i) for i, digest in enumerate(digests)])


@transaction.atomic
def save_job(request, data, pk=None):
    shop = lock_admin_shop(request)
    if pk:
        job = Job.objects.select_for_update().filter(pk=pk, shop=shop).first()
        if not job:
            raise HttpError(404, '找不到该作业。')
        valid_version(job, data.expected_version)
        before = {**_job_fields(job), 'photos': list(job.photos.values_list('media__sha256', flat=True))}
        before = json.loads(json.dumps(before, default=str))
        for field, value in _job_fields(data).items():
            setattr(job, field, value)
        job.version += 1
        job.save()
    else:
        before = None
        job = Job.objects.create(shop=shop, created_by=request.user, **_job_fields(data))
    _replace_photos(job, data.photo_sha256s)
    audit(shop, 'JOB_UPDATED' if pk else 'JOB_CREATED', job=job, operator=request.user, detail={'before': before, 'version': job.version})
    return job_data(job_query(shop).select_related('shop').get(pk=job.pk))


def operation_hash(action, data):
    raw = data.model_dump(mode='json')
    # 新增可选字段省略时沿用旧哈希，升级前已发出的请求仍可安全重试。
    for field in ('note', 'photo_sha256s', 'expected_payout_version'):
        if field not in data.model_fields_set:
            raw.pop(field, None)
    return hashlib.sha256(json.dumps({'action': action, 'data': raw}, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()


def cached_order(shop, actor, operation_id, fingerprint):
    receipt = OperationReceipt.objects.filter(shop=shop, actor_key=actor, operation_id=operation_id).first()
    if receipt:
        if receipt.request_hash != fingerprint:
            raise HttpError(409, '操作标识已用于其他内容，请刷新后重试。')
        return receipt.order_id
    return None


def remember_operation(shop, actor, operation_id, fingerprint, order):
    OperationReceipt.objects.create(shop=shop, actor_key=actor, operation_id=operation_id, request_hash=fingerprint, order=order)


def _tracking_snapshot(order):
    return list(order.parcels.filter(is_active=True).order_by('position', 'id').values_list('tracking_number', flat=True))


@transaction.atomic
def save_order(request, data, pk=None):
    shop = lock_shop(request.worker.shop)
    worker = live_worker(request)
    actor = f'worker:{worker.pk}'
    fingerprint = operation_hash('edit_order:' + str(pk) if pk else 'create_order', data)
    cached = cached_order(shop, actor, data.operation_id, fingerprint)
    if cached:
        return one_order(shop, cached, worker=worker)
    if pk:
        order = JobOrder.objects.select_for_update().select_related('job').filter(pk=pk, shop=shop, worker=worker).first()
        if not order:
            raise HttpError(404, '找不到该订单。')
        valid_version(order, data.expected_version)
        if order.settlements.filter(is_active=True).exists():
            raise HttpError(409, '订单已经结算，需由管理员撤销结算后才能修改。')
        before = {'order_number': order.order_number, 'tracking_numbers': _tracking_snapshot(order),
                  'note': order.note, 'photos': order_photo_data(order)}
    else:
        job = Job.objects.filter(pk=data.job_id, shop=shop, status='open').first()
        if not job:
            raise HttpError(404, '作业不存在或已关闭，无法新增报单。')
        order = JobOrder(shop=shop, job=job, worker=worker, order_number=data.order_number)
        before = None
    if JobOrder.objects.filter(job=order.job, worker=worker, order_number=data.order_number).exclude(pk=order.pk).exists():
        raise HttpError(409, '你已在此作业提交该订单，请直接编辑已有报单。')
    order.order_number = data.order_number
    if data.note is not None:
        order.note = data.note
    if data.photo_sha256s is not None:
        uploads = owned_uploads(worker, data.photo_sha256s, 'order')
    else:
        uploads = None
    if pk:
        order.version += 1
    order.save()
    if uploads is not None:
        order.photos.all().delete()
        JobOrderPhoto.objects.bulk_create([JobOrderPhoto(order=order, media=uploads[digest].media,
            name=uploads[digest].name, position=i) for i, digest in enumerate(data.photo_sha256s)])
    now = timezone.now()
    # 已移除的快递行留档，当前列表产生新版本快递行，不删除历史证据。
    order.parcels.filter(is_active=True).update(is_active=False, retired_at=now)
    JobParcel.objects.bulk_create([JobParcel(shop=shop, order=order, tracking_number=value, position=i)
                                  for i, value in enumerate(data.tracking_numbers)])
    remember_operation(shop, actor, data.operation_id, fingerprint, order)
    audit(shop, 'ORDER_UPDATED' if pk else 'ORDER_CREATED', job=order.job, order=order, worker=worker,
          detail={'before': before, 'order_number': order.order_number, 'tracking_numbers': data.tracking_numbers, 'version': order.version})
    return one_order(shop, order.pk, worker=worker)


def evidence_for(parcels, receipts):
    return [{'tracking_number': parcel.tracking_number, 'receipt_id': str(receipts[parcel.tracking_number].pk),
             'revision': receipts[parcel.tracking_number].revision}
            for parcel in parcels if parcel.tracking_number in receipts]


@transaction.atomic
def settle_order(request, order_id, data):
    shop = lock_admin_shop(request)
    actor = f'admin:{request.user.pk}'
    fingerprint = operation_hash('settle:' + str(order_id), data)
    cached = cached_order(shop, actor, data.operation_id, fingerprint)
    if cached:
        return one_order(shop, cached, admin=True)
    order = JobOrder.objects.select_for_update().select_related('job', 'worker').filter(pk=order_id, shop=shop).first()
    if not order:
        raise HttpError(404, '找不到该订单。')
    valid_version(order, data.expected_version)
    valid_version(order.job, data.expected_job_version)
    payout = payout_data(order.worker, lock=True)
    if (data.expected_payout_version is None and payout['version'] > 0) or (
            data.expected_payout_version is not None and data.expected_payout_version != payout['version']):
        raise HttpError(409, '收款信息已变化，请刷新订单并重新核对收款信息。')
    if order.settlements.filter(is_active=True).exists():
        raise HttpError(409, '此订单已经结算，请勿重复确认。')
    parcels = list(order.parcels.filter(is_active=True))
    receipts = receipt_map(shop, [p.tracking_number for p in parcels], lock=True)
    if not parcels or len(receipts) != len(parcels):
        raise HttpError(409, '尚有快递未入库，请先同步入库并核对全部快递。')
    expected = [item.model_dump(mode='json') for item in data.evidence]
    current = evidence_for(parcels, receipts)
    normalize = lambda values: sorted(values, key=lambda value: value['tracking_number'])
    if normalize(expected) != normalize(current):
        raise HttpError(409, '入库证据已变化，请刷新图片和商品后重新核对。')
    snapshot = {'order_number': order.order_number, 'tracking_numbers': [p.tracking_number for p in parcels],
                'job_title': order.job.title, 'job_version': order.job.version, 'evidence': current,
                'worker_id': str(order.worker_id), 'worker_name': order.worker.display_name,
                'payout': payout, 'note': order.note, 'photos': order_photo_data(order),
                'photo_sha256s': list(order.photos.order_by('position', 'id').values_list('media__sha256', flat=True)),
                'receipt_snapshots': [{'tracking_number': parcel.tracking_number, **receipt_data(receipts[parcel.tracking_number])} for parcel in parcels],
                'job': {'title': order.job.title, 'version': order.job.version,
                        'cost_amount': format(order.job.cost_amount, '.2f'), 'refund_amount': format(order.job.refund_amount, '.2f'),
                        'photo_sha256s': list(order.job.photos.values_list('media__sha256', flat=True))}}
    settlement = Settlement.objects.create(shop=shop, order=order, cost_amount=order.job.cost_amount,
        refund_amount=order.job.refund_amount, snapshot=snapshot, operator=request.user)
    order.version += 1
    order.save(update_fields=['version', 'updated_at'])
    remember_operation(shop, actor, data.operation_id, fingerprint, order)
    audit(shop, 'ORDER_SETTLED', job=order.job, order=order, worker=order.worker, operator=request.user,
          detail={'settlement_id': str(settlement.pk), 'snapshot': snapshot,
                  'cost_amount': format(settlement.cost_amount, '.2f'), 'refund_amount': format(settlement.refund_amount, '.2f')})
    return one_order(shop, order.pk, admin=True)


@transaction.atomic
def reopen_order(request, order_id, data):
    shop = lock_admin_shop(request)
    actor = f'admin:{request.user.pk}'
    fingerprint = operation_hash('reopen:' + str(order_id), data)
    cached = cached_order(shop, actor, data.operation_id, fingerprint)
    if cached:
        return one_order(shop, cached, admin=True)
    order = JobOrder.objects.select_for_update().select_related('job', 'worker').filter(pk=order_id, shop=shop).first()
    if not order:
        raise HttpError(404, '找不到该订单。')
    valid_version(order, data.expected_version)
    settlement = order.settlements.select_for_update().filter(is_active=True).first()
    if not settlement:
        raise HttpError(409, '此订单没有有效结算记录。')
    settlement.is_active = False
    settlement.reopened_at = timezone.now()
    settlement.reopened_by = request.user
    settlement.reopen_reason = data.reason
    settlement.save(update_fields=['is_active', 'reopened_at', 'reopened_by', 'reopen_reason'])
    order.version += 1
    order.save(update_fields=['version', 'updated_at'])
    remember_operation(shop, actor, data.operation_id, fingerprint, order)
    audit(shop, 'SETTLEMENT_REOPENED', job=order.job, order=order, worker=order.worker, operator=request.user,
          detail={'settlement_id': str(settlement.pk), 'reason': data.reason})
    return one_order(shop, order.pk, admin=True)


@transaction.atomic
def change_worker(request, worker_id, data, password=False):
    shop = lock_admin_shop(request)
    worker = WorkerAccount.objects.select_for_update().select_related('shop').filter(pk=worker_id, shop=shop).first()
    if not worker:
        raise HttpError(404, '找不到本店拍手账号。')
    if worker.auth_version != data.expected_version:
        raise HttpError(409, '拍手账号已被更新，请刷新后重试。')
    before = worker.is_active
    if password:
        worker.set_password(data.new_password)
    else:
        worker.is_active = data.enabled
    worker.auth_version += 1
    worker.save()
    audit(shop, 'WORKER_PASSWORD_RESET' if password else 'WORKER_ENABLED' if worker.is_active else 'WORKER_DISABLED',
          worker=worker, operator=request.user, detail={'was_enabled': before, 'enabled': worker.is_active, 'version': worker.auth_version})
    return worker_data(worker, admin=True)


def order_photo_data(order):
    photos = getattr(order, 'supplemental_photos', None)
    if photos is None:
        photos = order.photos.select_related('media').all()
    return [{'sha256': photo.media.sha256, 'name': photo.name} for photo in photos]


def owned_uploads(worker, digests, purpose):
    rows = WorkerMediaUpload.objects.select_related('media').filter(
        worker=worker, purpose=purpose, media__shop_id=worker.shop_id, media__sha256__in=digests)
    found = {row.media.sha256: row for row in rows}
    if len(found) != len(digests):
        raise HttpError(400, '请先由本人上传全部照片，不能使用其他拍手或其他用途的图片。')
    return found


def payout_data(worker, lock=False):
    rows = WorkerPayoutProfile.objects.select_related('qr_media').filter(worker=worker)
    if lock:
        rows = rows.select_for_update(of=('self',))
    profile = rows.first()
    if profile is None:
        return {'wechat': '', 'alipay_phone': '', 'alipay_name': '', 'qr_sha256': None,
                'version': 0, 'updated_at': None}
    return {'wechat': profile.wechat, 'alipay_phone': profile.alipay_phone,
            'alipay_name': profile.alipay_name, 'qr_sha256': profile.qr_media.sha256 if profile.qr_media else None,
            'version': profile.version, 'updated_at': profile.updated_at.isoformat()}


@transaction.atomic
def save_payout(request, data):
    shop = lock_shop(request.worker.shop)
    worker = live_worker(request)
    profile, _ = WorkerPayoutProfile.objects.get_or_create(worker=worker)
    fingerprint = operation_hash('payout', data)
    if profile.last_operation_id == data.operation_id:
        if profile.last_request_hash != fingerprint:
            raise HttpError(409, '操作标识已用于其他收款信息，请核对后重试。')
        return payout_data(worker)
    valid_version(profile, data.expected_version)
    uploads = owned_uploads(worker, [data.qr_sha256], 'payout') if data.qr_sha256 else {}
    profile.wechat = data.wechat
    profile.alipay_phone = data.alipay_phone
    profile.alipay_name = data.alipay_name
    profile.qr_media = uploads[data.qr_sha256].media if data.qr_sha256 else None
    profile.version += 1
    profile.last_operation_id = data.operation_id
    profile.last_request_hash = fingerprint
    profile.save()
    # 审计只记录资料版本，不把手机号、姓名和收款码复制到一般操作日志。
    audit(shop, 'WORKER_PAYOUT_UPDATED', worker=worker, detail={'version': profile.version})
    return payout_data(worker)


def worker_order_summary(worker):
    rows = order_query(worker.shop).filter(worker=worker)
    return {'total': rows.count(), 'in_transit': filter_order_status(rows, 'in_transit').count(),
            'arrived': filter_order_status(rows, 'arrived').count()}
