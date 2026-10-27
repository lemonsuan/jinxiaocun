"""Repeatable API tests against a disposable DB; never registers against a live host."""
import subprocess
import sys
from pathlib import Path

if __name__ == '__main__':
    raise SystemExit(subprocess.call([sys.executable, 'manage.py', 'test', 'inventory', 'shops', '--settings=shop_sync_backend.test_settings'], cwd=Path(__file__).resolve().parent))
