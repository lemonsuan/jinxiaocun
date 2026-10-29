"""只向明确标记的演示店追加验收数据，所有业务写入均走正常接口。"""
import argparse
import io
import json
import os

import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'shop_sync_backend.settings')
django.setup()

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client
from PIL import Image, ImageDraw
from jobs.models import Job, JobOrder, WorkerAccount
from shops.models import CustomUser, Shop, ShopMembership
from shop_sync_backend.api import generate_token

PREFIX = 'UX20261029'
DEMO_SHOP_NAME = '作业报单功能验收店（演示）'
PASSWORD = 'DemoWorker2026!'


def seed(shop_number, admin_username):
    shop = Shop.objects.get(shop_number=shop_number)
    if shop.name != DEMO_SHOP_NAME:
        raise ValueError('目标不是专用演示店，停止写入。')
    admin = CustomUser.objects.get(username=admin_username, is_active=True)
    if not ShopMembership.objects.filter(shop=shop, user=admin, status='APPROVED',
                                         role__in=['CREATOR', 'ADMIN']).exists():
        raise ValueError('指定管理员没有本演示店管理资格。')
    client = Client(HTTP_HOST='localhost')
    management = {'HTTP_AUTHORIZATION': 'Bearer ' + generate_token(admin),
                  'HTTP_X_ACTIVE_SHOP_ID': str(shop.pk)}

    def call(method, path, body=None, headers=None):
        response = getattr(client, method)('/api' + path, data=json.dumps(body or {}),
            content_type='application/json', **(headers or management))
        if response.status_code != 200:
            raise RuntimeError(f'{method} {path}: {response.status_code} {response.content.decode()[:500]}')
        return response.json()

    def get(path, headers=None):
        response = client.get('/api' + path, **(headers or management))
        if response.status_code != 200:
            raise RuntimeError(f'读取失败：{path} {response.status_code}')
        return response.json()

    def upload(label, headers, purpose=None):
        image = Image.new('RGB', (760, 420), '#e8f1ed')
        draw = ImageDraw.Draw(image)
        draw.rectangle((24, 24, 736, 396), outline='#267568', width=4)
        draw.text((48, 70), 'DEMO ONLY - NO PAYMENT', fill='#154c41')
        draw.text((48, 125), label, fill='#154c41')
        draw.text((48, 190), 'SKU-DEMO-A  x2 / SKU-DEMO-B  x1', fill='#154c41')
        output = io.BytesIO()
        image.save(output, 'PNG')
        body = {'file': SimpleUploadedFile(label + '.png', output.getvalue(), content_type='image/png')}
        if purpose:
            body['purpose'] = purpose
        response = client.post('/api/worker/media' if purpose else '/api/sync/v2/media', body, **headers)
        if response.status_code != 200:
            raise RuntimeError(f'演示图片上传失败：{response.status_code}')
        return response.json()['sha256']

    workers = []
    for suffix, name in [('a', '演示拍手甲'), ('b', '演示拍手乙')]:
        username = 'ux20261029_' + suffix
        if not WorkerAccount.objects.filter(shop=shop, username=username).exists():
            call('post', '/worker/register', {'shop_number': str(shop_number), 'username': username,
                'password': PASSWORD, 'display_name': name, 'phone': ''})
        # 已有账号只登录，不能重置密码或启用被管理员禁用的账号。
        login = call('post', '/worker/login', {'shop_number': str(shop_number),
                                               'username': username, 'password': PASSWORD})
        headers = {'HTTP_AUTHORIZATION': 'Bearer ' + login['token']}
        payout = get('/worker/payout', headers)
        if payout['version'] == 0:
            qr = upload(PREFIX + '-payout-' + suffix, headers, 'payout')
            call('patch', '/worker/payout', {'wechat': 'demo_wechat_' + suffix,
                'alipay_phone': '', 'alipay_name': name + '（演示）', 'qr_sha256': qr,
                'expected_version': 0, 'operation_id': PREFIX + '-payout-' + suffix}, headers)
        workers.append(headers)

    jobs = []
    for index, title in enumerate(['生活用品多快递演示', '手机快速填单演示', '关闭作业历史演示']):
        title = PREFIX + ' ' + title
        existing = Job.objects.filter(shop=shop, title=title).first()
        if existing:
            jobs.append(get('/jobs/' + str(existing.pk)))
        else:
            photo = upload(PREFIX + '-job-' + str(index), management)
            jobs.append(call('post', '/jobs', {'title': title,
                'description': '仅用于界面验收，不是真实作业。\n核对商品后填写订单号，可一次填写多个快递号。\n同一作业可以反复填写不同订单。',
                'cost_amount': '29.90' if index == 0 else '10.00',
                'refund_amount': '35.00' if index == 0 else '12.50',
                'status': 'open', 'photo_sha256s': [photo]}))

    # 拍手、作业、订单尾号、快递尾号、已入库尾号、是否结算。
    matrix = [(0, 0, 'A001', [1, 2], [], False),
              (0, 0, 'A002', [3, 4, 5], [3], False),
              (1, 0, 'B001', [6, 7], [6, 7], False),
              (0, 0, 'A003', [8, 9], [8, 9], True),
              (0, 1, 'A004', [10], [], False),
              (1, 1, 'B002', [11, 12], [11], False),
              (0, 2, 'A005', [13], [], False),
              (0, 0, 'A006', [14], [14], False)]
    orders = []
    for worker_index, job_index, suffix, parcels, arrived, settled in matrix:
        headers = workers[worker_index]
        number = PREFIX + '-' + suffix
        existing = JobOrder.objects.filter(shop=shop, worker__username='ux20261029_' + ('a' if worker_index == 0 else 'b'),
                                           job_id=jobs[job_index]['id'], order_number=number).first()
        if existing:
            # 重跑不覆盖用户验收时对已有订单的编辑，也不重复触发结算。
            orders.append(get('/jobs/orders/' + str(existing.pk)))
            continue
        photo = upload(number + '-supplement', headers, 'order')
        order = call('post', '/worker/orders', {'job_id': jobs[job_index]['id'],
            'order_number': number, 'tracking_numbers': [f'{PREFIX}-T{i:03}' for i in parcels],
            'note': '演示补充说明：此单用于核对多快递与返款进度。',
            'photo_sha256s': [photo], 'operation_id': number + '-create'}, headers)
        for tail in arrived:
            tracking = f'{PREFIX}-T{tail:03}'
            receipt_photo = upload(tracking, management)
            result = call('post', '/sync/v2/push', {'device_id': PREFIX + '-demo-device', 'operations': [{
                'kind': 'inbound', 'id': tracking, 'operation_id': tracking + '-inbound', 'base_revision': 0,
                'data': {'tracking_number': tracking, 'created_at': '2026-10-29T12:00:00+08:00',
                    'ocr_status': 'confirmed', 'is_settled': False, 'image_sha256': receipt_photo,
                    'items': [{'id': tracking + '-line-A', 'product_code': PREFIX + '-SKU-A',
                               'product_name': '演示洗衣液', 'quantity': 2},
                              {'id': tracking + '-line-B', 'product_code': PREFIX + '-SKU-B',
                               'product_name': '演示收纳盒', 'quantity': 1}]}}]})
            if result['results'][0]['status'] != 'applied':
                raise RuntimeError('演示入库未成功，停止后续结算。')
        detail = get('/jobs/orders/' + order['id'])
        if settled:
            call('post', '/jobs/orders/' + order['id'] + '/settle', {
                'expected_version': detail['version'], 'expected_job_version': detail['job']['version'],
                'expected_payout_version': detail['payout']['version'], 'operation_id': number + '-settle',
                'evidence': [{'tracking_number': p['tracking_number'], 'receipt_id': p['receipt']['receipt_id'],
                              'revision': p['receipt']['revision']} for p in detail['parcels']]})
        orders.append(get('/jobs/orders/' + order['id']))

    closed = get('/jobs/' + jobs[2]['id'])
    if closed['status'] == 'open':
        call('patch', '/jobs/' + closed['id'], {
            'title': closed['title'], 'description': closed['description'],
            'cost_amount': closed['cost_amount'], 'refund_amount': closed['refund_amount'],
            'photo_sha256s': [photo['sha256'] for photo in closed['photos']],
            'expected_version': closed['version'], 'status': 'closed'})
    # 已结算保留初始资料，未结算读取新资料；重跑不覆盖用户后续修改。
    payout = get('/worker/payout', workers[0])
    if payout['version'] == 1 and payout['wechat'] == 'demo_wechat_a':
        call('patch', '/worker/payout', {key: payout[key] for key in
             ['wechat', 'alipay_phone', 'alipay_name', 'qr_sha256']} | {
            'wechat': 'demo_wechat_a_new', 'alipay_name': '演示拍手甲（新资料）',
            'expected_version': 1, 'operation_id': PREFIX + '-payout-a-new'}, workers[0])
    return {'shop_number': str(shop_number), 'prefix': PREFIX,
            'jobs': [job['id'] for job in jobs],
            'orders': [{'id': order['id'], 'order_number': order['order_number'], 'status': order['status']} for order in orders],
            'summaries': [get('/worker/orders/summary', headers) for headers in workers]}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='只追加专用演示店数据，不覆盖业务数据')
    parser.add_argument('--shop', type=int, default=10003)
    parser.add_argument('--admin', default='admin')
    parser.add_argument('--apply', action='store_true', help='明确执行追加；默认仅核对目标')
    args = parser.parse_args()
    if args.apply:
        print(json.dumps(seed(args.shop, args.admin), ensure_ascii=False, indent=2))
    else:
        shop = Shop.objects.get(shop_number=args.shop)
        print(json.dumps({'shop_number': args.shop, 'name': shop.name,
            'can_seed': shop.name == DEMO_SHOP_NAME, 'applied': False}, ensure_ascii=False))
