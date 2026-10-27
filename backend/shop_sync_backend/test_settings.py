"""Isolated SQLite development/test configuration. Never connects to production DB."""
import os
from .settings import *  # noqa: F403
DATABASES = {'default': {'ENGINE': 'django.db.backends.sqlite3', 'NAME': os.environ.get('SHOP_SYNC_TEST_DB', ':memory:'), 'OPTIONS': {'timeout': 30}}}
ALLOWED_HOSTS = ['localhost', '127.0.0.1', 'testserver']
PRIVATE_MEDIA_ROOT = os.environ.get('SHOP_SYNC_TEST_MEDIA', '/tmp/shop-sync-test-media')
PASSWORD_HASHERS = ['django.contrib.auth.hashers.MD5PasswordHasher']
