"""Opt-in disposable PostgreSQL test DB. No production settings are inherited for DB."""
import os
from .test_settings import *  # noqa: F403
DATABASES = {'default': {'ENGINE': 'django.db.backends.postgresql', 'NAME': 'shop_sync_isolated', 'USER': 'sync_test', 'PASSWORD': os.environ.get('SHOP_SYNC_PG_PASSWORD', 'isolated-tests-only'), 'HOST': '127.0.0.1', 'PORT': os.environ.get('SHOP_SYNC_PG_PORT', '25439')}}
