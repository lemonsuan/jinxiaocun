"""Immutable shop-scoped evidence storage, shared by upload and legacy import."""
import hashlib
import io
import os
import tempfile
import warnings
from pathlib import Path
from django.conf import settings
from PIL import Image
from .models import PrivateMedia

MAX_IMAGE_BYTES = 15 * 1024 * 1024


def store_image(shop, content, claimed_digest=None):
    if not content or len(content) > MAX_IMAGE_BYTES:
        raise ValueError('Image size must be between 1 byte and 15 MiB.')
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(content)) as image:
                if image.width * image.height > 40_000_000 or max(image.size) > 20000:
                    raise ValueError('Image dimensions exceed processing limits')
                image.verify()
                fmt = image.format
        with Image.open(io.BytesIO(content)) as decoded:
            decoded.load()
        mime = {'JPEG': 'image/jpeg', 'PNG': 'image/png', 'WEBP': 'image/webp'}.get(fmt)
        if not mime:
            raise ValueError('Unsupported format')
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
        raise ValueError('A valid JPEG, PNG or WebP image is required.') from error
    digest = hashlib.sha256(content).hexdigest()
    if claimed_digest is not None and claimed_digest != digest:
        raise ValueError('Image SHA256 mismatch.')
    target = Path(settings.PRIVATE_MEDIA_ROOT) / str(shop.pk) / digest
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix='.upload-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, target)
        except FileExistsError:
            pass
    finally:
        os.unlink(temporary)
    obj, _ = PrivateMedia.objects.get_or_create(shop=shop, sha256=digest, defaults={'size': len(content), 'content_type': mime})
    return obj
