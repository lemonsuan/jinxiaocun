"""作业管理与店铺拍手使用分离的认证路由。"""
from pathlib import Path
from uuid import UUID
from django.conf import settings
from django.core.cache import cache
import hashlib
from django.contrib.auth.hashers import make_password
from django.db import transaction
from django.db.models import Count, Q
from django.http import FileResponse
from ninja import Body, File, Router
from ninja.errors import HttpError
from ninja.files import UploadedFile
from pydantic import ValidationError
from inventory.media import MAX_IMAGE_BYTES, store_image
from shops.models import Shop
from .auth import WorkerBearer, worker_token
from .models import Job, JobOrder, JobPhoto, WorkerAccount
from .schemas import (JobData, JobUpdate, OrderCreate, OrderUpdate, Reopen, Settle, ShopNumber,
                      WorkerEnabled, WorkerLogin, WorkerPassword, WorkerRegister)
from .services import (audit, change_worker, filter_order_status, job_data, job_query,
                       lock_shop, one_order, order_query, reopen_order, require_admin,
                       save_job, save_order, serialize_orders, settle_order, visible_jobs, worker_data)

admin_router = Router()
public_router = Router(auth=None)
worker_router = Router(auth=WorkerBearer())


def validate(schema, data):
    try:
        return schema.model_validate(data)
    except ValidationError as error:
        messages = []
        labels = {'shop_number': '店铺ID', 'username': '账号', 'password': '密码', 'new_password': '新密码',
                  'display_name': '姓名', 'phone': '手机号', 'title': '作业名称', 'cost_amount': '作业成本',
                  'refund_amount': '返款金额', 'tracking_numbers': '快递单号', 'order_number': '订单号',
                  'expected_version': '内容版本', 'expected_job_version': '作业版本', 'operation_id': '操作标识'}
        for item in error.errors()[:5]:
            name = labels.get(str(item['loc'][0]) if item['loc'] else '', '提交内容')
            kind = item['type']
            if kind == 'missing':
                text = '请填写此项'
            elif kind == 'extra_forbidden':
                text = '包含不允许提交的字段'
            elif kind.startswith('decimal'):
                text = '金额须为非负且最多两位小数，整数部分最多10位'
            elif kind == 'value_error':
                text = str(item.get('ctx', {}).get('error', '格式不正确'))
            elif kind in ('string_too_long', 'too_long'):
                text = '内容或条目数量超过上限'
            elif kind in ('string_too_short', 'too_short'):
                text = '内容或条目数量不足'
            else:
                text = '格式或范围不正确'
            messages.append(f'{name}：{text}')
        raise HttpError(422, '；'.join(messages))


def key(value):
    try:
        return UUID(str(value))
    except (TypeError, ValueError):
        raise HttpError(404, '找不到该记录。')


def paginate(rows, page=1, page_size=20):
    if page < 1 or not 1 <= page_size <= 100:
        raise HttpError(400, '分页范围无效，每页最多100条。')
    total = rows.count()
    return list(rows[(page - 1) * page_size:page * page_size]), total


def page_result(items, total, page, page_size):
    return {'items': items, 'total': total, 'page': page, 'page_size': page_size}


def attempt_key(request, purpose, shop, username=''):
    # 使用服务端连接地址，不信任可伪造的代理头；部署多实例时应使用共享缓存。
    raw = f"{purpose}|{request.META.get('REMOTE_ADDR', '')}|{shop.pk}|{username}"
    return 'job-login:' + hashlib.sha256(raw.encode()).hexdigest()


def limit_attempt(key, maximum):
    cache.add(key, 0, timeout=300)
    try:
        count = cache.incr(key)
    except ValueError:
        cache.set(key, 1, timeout=300)
        count = 1
    if count > maximum:
        raise HttpError(429, '操作过于频繁，请5分钟后重试。')


def shop_by_number(number):
    value = validate(ShopNumber, {'shop_number': number}).shop_number
    shop = Shop.objects.filter(shop_number=int(value)).first()
    if not shop:
        raise HttpError(404, '找不到此店铺，请核对管理员提供的数字店铺ID。')
    return shop


@public_router.get('/worker/shop')
def public_shop(request, shop_number: str):
    shop = shop_by_number(shop_number)
    return {'shop_number': str(shop.shop_number), 'name': shop.name}


@public_router.post('/worker/register')
@transaction.atomic
def worker_register(request, data: Body[dict]):
    values = validate(WorkerRegister, data)
    shop = lock_shop(shop_by_number(values.shop_number))
    limit_attempt(attempt_key(request, 'register', shop), 30)
    if WorkerAccount.objects.filter(shop=shop, username=values.username).exists():
        raise HttpError(400, '此账号已在本店注册，请登录；忘记密码或账号禁用请联系管理员。')
    worker = WorkerAccount(shop=shop, username=values.username, display_name=values.display_name,
                           phone=values.phone)
    worker.set_password(values.password)
    worker.save()
    audit(shop, 'WORKER_REGISTERED', worker=worker)
    return {'token': worker_token(worker), 'worker': worker_data(worker)}


@public_router.post('/worker/login')
def worker_login(request, data: Body[dict]):
    values = validate(WorkerLogin, data)
    shop = shop_by_number(values.shop_number)
    limiter = attempt_key(request, 'login', shop, values.username)
    limit_attempt(limiter, 10)
    worker = WorkerAccount.objects.select_related('shop').filter(shop=shop, username=values.username).first()
    if not worker:
        # 未注册账号也执行密码哈希，减少通过耗时判断账号存在的差异。
        make_password(values.password)
        raise HttpError(400, '店铺ID、账号或密码不正确。')
    if not worker.check_password(values.password):
        raise HttpError(400, '店铺ID、账号或密码不正确。')
    if not worker.is_active:
        raise HttpError(403, '该拍手账号已被本店禁用，请联系管理员。')
    cache.delete(limiter)
    return {'token': worker_token(worker), 'worker': worker_data(worker)}


@worker_router.get('/worker/me')
def worker_me(request):
    return worker_data(request.worker)


@worker_router.get('/worker/orders')
def worker_orders(request, page: int = 1, page_size: int = 20, job_id: str | None = None,
                  status: str | None = None, q: str | None = None):
    rows = order_query(request.worker.shop).filter(worker=request.worker)
    if job_id:
        rows = rows.filter(job_id=key(job_id))
    if q:
        if len(q) > 100:
            raise HttpError(400, '搜索内容最长100位。')
        rows = rows.filter(Q(order_number__icontains=q) | Q(parcels__is_active=True, parcels__tracking_number__icontains=q)).distinct()
    rows = filter_order_status(rows, status).order_by('-updated_at', 'id')
    selected, total = paginate(rows, page, page_size)
    return page_result(serialize_orders(selected), total, page, page_size)


@worker_router.post('/worker/orders')
def worker_order_create(request, data: Body[dict]):
    return save_order(request, validate(OrderCreate, data))


@worker_router.get('/worker/orders/{order_id}')
def worker_order_detail(request, order_id: str):
    return one_order(request.worker.shop, key(order_id), worker=request.worker)


@worker_router.patch('/worker/orders/{order_id}')
def worker_order_update(request, order_id: str, data: Body[dict]):
    return save_order(request, validate(OrderUpdate, data), key(order_id))


@worker_router.get('/worker/jobs')
def worker_jobs(request, page: int = 1, page_size: int = 20, q: str | None = None):
    rows = visible_jobs(request.worker).select_related('shop').annotate(
        _own_order_count=Count('orders', filter=Q(orders__worker=request.worker), distinct=True))
    if q:
        if len(q) > 150:
            raise HttpError(400, '搜索内容过长。')
        rows = rows.filter(title__icontains=q)
    selected, total = paginate(rows.order_by('-created_at', 'id'), page, page_size)
    return page_result([job_data(job, request.worker) for job in selected], total, page, page_size)


def visible_job(request, job_id):
    job = visible_jobs(request.worker).select_related('shop').filter(pk=key(job_id)).first()
    if not job:
        raise HttpError(404, '作业不存在或暂不可查看。')
    return job


@worker_router.get('/worker/jobs/{job_id}/photos/{sha256}')
def worker_photo(request, job_id: str, sha256: str):
    return photo_response(visible_job(request, job_id), sha256)


@worker_router.get('/worker/jobs/{job_id}')
def worker_job_detail(request, job_id: str):
    return job_data(visible_job(request, job_id), request.worker)


@admin_router.get('/jobs')
def admin_jobs(request, page: int = 1, page_size: int = 20, q: str | None = None, status: str | None = None):
    rows = job_query(require_admin(request)).select_related('shop').annotate(_order_count=Count('orders', distinct=True))
    if status:
        if status not in ('open', 'closed'):
            raise HttpError(400, '作业状态无效。')
        rows = rows.filter(status=status)
    if q:
        if len(q) > 150:
            raise HttpError(400, '搜索内容过长。')
        rows = rows.filter(title__icontains=q)
    selected, total = paginate(rows.order_by('-created_at', 'id'), page, page_size)
    return page_result([job_data(job) for job in selected], total, page, page_size)


@admin_router.post('/jobs')
def admin_job_create(request, data: Body[dict]):
    return save_job(request, validate(JobData, data))


@admin_router.post('/jobs/media')
def admin_media(request, file: File[UploadedFile]):
    shop = require_admin(request)
    if file.size > MAX_IMAGE_BYTES:
        raise HttpError(413, '图片超过15MB，请压缩后上传。')
    content = file.read(MAX_IMAGE_BYTES + 1)
    try:
        obj = store_image(shop, content)
    except ValueError:
        raise HttpError(400, '请上传15MB以内的有效JPEG、PNG或WebP图片。')
    return {'sha256': obj.sha256, 'size': obj.size, 'content_type': obj.content_type}


@admin_router.get('/jobs/orders')
def admin_orders(request, page: int = 1, page_size: int = 20, q: str | None = None,
                 job_id: str | None = None, status: str | None = None, worker_id: str | None = None):
    rows = order_query(require_admin(request))
    if job_id:
        rows = rows.filter(job_id=key(job_id))
    if worker_id:
        rows = rows.filter(worker_id=key(worker_id))
    if q:
        if len(q) > 100:
            raise HttpError(400, '搜索内容最长100位。')
        rows = rows.filter(Q(order_number__icontains=q) | Q(parcels__is_active=True, parcels__tracking_number__icontains=q)
                           | Q(worker__username__icontains=q) | Q(worker__display_name__icontains=q)).distinct()
    rows = filter_order_status(rows, status).order_by('-updated_at', 'id')
    selected, total = paginate(rows, page, page_size)
    return page_result(serialize_orders(selected, admin=True), total, page, page_size)


@admin_router.get('/jobs/orders/{order_id}')
def admin_order_detail(request, order_id: str):
    return one_order(require_admin(request), key(order_id), admin=True)


@admin_router.post('/jobs/orders/{order_id}/settle')
def admin_order_settle(request, order_id: str, data: Body[dict]):
    return settle_order(request, key(order_id), validate(Settle, data))


@admin_router.post('/jobs/orders/{order_id}/reopen')
def admin_order_reopen(request, order_id: str, data: Body[dict]):
    return reopen_order(request, key(order_id), validate(Reopen, data))


@admin_router.get('/jobs/workers')
def admin_workers(request, page: int = 1, page_size: int = 20, q: str | None = None, enabled: bool | None = None):
    rows = WorkerAccount.objects.filter(shop=require_admin(request)).select_related('shop')
    if enabled is not None:
        rows = rows.filter(is_active=enabled)
    if q:
        if len(q) > 100:
            raise HttpError(400, '搜索内容最长100位。')
        rows = rows.filter(Q(username__icontains=q) | Q(display_name__icontains=q) | Q(phone__icontains=q))
    selected, total = paginate(rows.order_by('-created_at', 'id'), page, page_size)
    return page_result([worker_data(worker, admin=True) for worker in selected], total, page, page_size)


@admin_router.post('/jobs/workers/{worker_id}/enabled')
def admin_worker_enabled(request, worker_id: str, data: Body[dict]):
    return change_worker(request, key(worker_id), validate(WorkerEnabled, data))


@admin_router.post('/jobs/workers/{worker_id}/password')
def admin_worker_password(request, worker_id: str, data: Body[dict]):
    return change_worker(request, key(worker_id), validate(WorkerPassword, data), password=True)


def photo_response(job, digest):
    photo = JobPhoto.objects.select_related('media').filter(job=job, media__shop=job.shop, media__sha256=digest).first()
    if not photo:
        raise HttpError(404, '找不到此作业照片。')
    target = Path(settings.PRIVATE_MEDIA_ROOT) / str(job.shop_id) / photo.media.sha256
    try:
        stream = target.open('rb')
    except FileNotFoundError:
        raise HttpError(404, '作业照片暂不可用，请联系管理员。')
    response = FileResponse(stream, content_type=photo.media.content_type)
    response['Cache-Control'] = 'private, no-store'
    response['X-Content-Type-Options'] = 'nosniff'
    return response


# 必须置于orders/workers/media静态路径之后，避免被当作作业编号。
@admin_router.get('/jobs/{job_id}/photos/{sha256}')
def admin_photo(request, job_id: str, sha256: str):
    shop = require_admin(request)
    job = Job.objects.filter(shop=shop, pk=key(job_id)).first()
    if not job:
        raise HttpError(404, '找不到本店作业。')
    return photo_response(job, sha256)


@admin_router.get('/jobs/{job_id}')
def admin_job_detail(request, job_id: str):
    shop = require_admin(request)
    job = job_query(shop).select_related('shop').filter(pk=key(job_id)).first()
    if not job:
        raise HttpError(404, '找不到本店作业。')
    return job_data(job)


@admin_router.patch('/jobs/{job_id}')
def admin_job_update(request, job_id: str, data: Body[dict]):
    return save_job(request, validate(JobUpdate, data), key(job_id))


def register_jobs(api, admin_auth):
    api.add_router('', public_router, auth=None)
    api.add_router('', worker_router)
    api.add_router('', admin_router, auth=admin_auth)
