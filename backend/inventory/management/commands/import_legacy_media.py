"""Explicitly import accessible legacy evidence. Never follows arbitrary host paths."""
from pathlib import Path
from django.core.exceptions import ValidationError
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction
from shops.models import Shop
from inventory.models import InboundReceipt, OutboundOrder, ShopSyncState
from inventory.media import store_image, MAX_IMAGE_BYTES
from inventory.sync_service import publish


class Command(BaseCommand):
    help = 'Import legacy images from an explicit trusted root into private SHA storage (dry-run unless --apply).'

    def add_arguments(self, parser):
        parser.add_argument('--source-root', required=True)
        parser.add_argument('--shop', required=True)
        parser.add_argument('--apply', action='store_true')

    def handle(self, *args, **options):
        root = Path(options['source_root']).resolve()
        if not root.is_dir():
            raise CommandError('source-root must be an existing trusted directory.')
        try:
            shop = Shop.objects.get(pk=options['shop'])
        except (Shop.DoesNotExist, ValueError, ValidationError) as error:
            raise CommandError('Shop does not exist.') from error
        imported, skipped = 0, 0
        with transaction.atomic():
            Shop.objects.select_for_update().get(pk=shop.pk)
            state, _ = ShopSyncState.objects.get_or_create(shop=shop)
            for kind, model in [('inbound', InboundReceipt), ('outbound', OutboundOrder)]:
                for document in model.objects.filter(shop=shop):
                    changed = False
                    photos = [document] if kind == 'inbound' else document.attachments.all()
                    for photo in photos:
                        if photo.image_sha256 or not photo.image_path:
                            continue
                        source = Path(photo.image_path)
                        source = (source if source.is_absolute() else root / source).resolve()
                        if not source.is_relative_to(root) or not source.is_file() or source.stat().st_size > MAX_IMAGE_BYTES:
                            skipped += 1
                            continue
                        if options['apply']:
                            try:
                                with source.open('rb') as stream:
                                    media = store_image(shop, stream.read(MAX_IMAGE_BYTES + 1))
                            except ValueError:
                                skipped += 1
                                continue
                            photo.image_sha256 = media.sha256
                            photo.save(update_fields=['image_sha256'])
                            changed = True
                        imported += 1
                    if changed and not document.is_deleted:
                        publish(state, kind, document)
            state.save(update_fields=['revision'])
        self.stdout.write(f'{"Imported" if options["apply"] else "Candidates"}: {imported}; skipped: {skipped}. Original paths/files retained.')
