"""拍手使用独立用途令牌，不复用库存账号身份。"""
from datetime import timedelta
import jwt
from django.conf import settings
from django.core.exceptions import ValidationError
from django.utils import timezone
from ninja.errors import HttpError
from ninja.security import HttpBearer
from .models import WorkerAccount

AUDIENCE = 'shop-job-worker'


def worker_token(worker):
    now = timezone.now()
    return jwt.encode({'sub': str(worker.pk), 'shop': str(worker.shop_id), 'version': worker.auth_version,
                       'purpose': 'worker', 'aud': AUDIENCE, 'iat': now, 'exp': now + timedelta(days=14)},
                      settings.SECRET_KEY, algorithm='HS256')


class WorkerBearer(HttpBearer):
    def authenticate(self, request, token):
        try:
            payload = jwt.decode(token, settings.SECRET_KEY, algorithms=['HS256'], audience=AUDIENCE)
            if payload.get('purpose') != 'worker':
                raise ValueError('用途不符')
            worker = WorkerAccount.objects.select_related('shop').get(pk=payload['sub'], shop_id=payload['shop'])
            if not worker.is_active:
                raise HttpError(403, '该拍手账号已被本店禁用，请联系管理员。')
            if worker.auth_version != payload['version']:
                raise HttpError(401, '登录已失效，请重新登录本店拍手账号。')
        except HttpError:
            raise
        except (jwt.InvalidTokenError, KeyError, TypeError, ValueError, ValidationError, WorkerAccount.DoesNotExist):
            raise HttpError(401, '拍手登录已过期或无效，请重新登录。')
        request.worker = worker
        request.worker_auth_version = payload['version']
        return worker
