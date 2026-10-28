# 作业、店铺拍手、结算快照及操作留痕的初始结构。

import django.db.models.deletion
import uuid
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):

    initial = True

    dependencies = [
        ('inventory', '0006_alter_inboundreceipt_ocr_status'),
        ('shops', '0003_shop_number'),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name='Job',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('title', models.CharField(max_length=150)),
                ('description', models.TextField(blank=True, default='')),
                ('cost_amount', models.DecimalField(decimal_places=2, max_digits=12)),
                ('refund_amount', models.DecimalField(decimal_places=2, max_digits=12)),
                ('status', models.CharField(choices=[('open', '开放'), ('closed', '已关闭')], default='open', max_length=10)),
                ('version', models.PositiveIntegerField(default=1)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('created_by', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, to=settings.AUTH_USER_MODEL)),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='jobs', to='shops.shop')),
            ],
            options={
                'verbose_name': '作业',
                'verbose_name_plural': '作业',
            },
        ),
        migrations.CreateModel(
            name='JobOrder',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('order_number', models.CharField(max_length=100)),
                ('version', models.PositiveIntegerField(default=1)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('job', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='orders', to='jobs.job')),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='shops.shop')),
            ],
        ),
        migrations.CreateModel(
            name='JobParcel',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('tracking_number', models.CharField(max_length=100)),
                ('position', models.PositiveIntegerField()),
                ('is_active', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('retired_at', models.DateTimeField(blank=True, null=True)),
                ('order', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='parcels', to='jobs.joborder')),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='shops.shop')),
            ],
            options={
                'ordering': ['position', 'id'],
            },
        ),
        migrations.CreateModel(
            name='JobPhoto',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('position', models.PositiveIntegerField()),
                ('job', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='photos', to='jobs.job')),
                ('media', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='inventory.privatemedia')),
            ],
            options={
                'ordering': ['position', 'id'],
            },
        ),
        migrations.CreateModel(
            name='OperationReceipt',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('actor_key', models.CharField(max_length=80)),
                ('operation_id', models.CharField(max_length=100)),
                ('request_hash', models.CharField(max_length=64)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('order', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='jobs.joborder')),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='shops.shop')),
            ],
        ),
        migrations.CreateModel(
            name='Settlement',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('cost_amount', models.DecimalField(decimal_places=2, max_digits=12)),
                ('refund_amount', models.DecimalField(decimal_places=2, max_digits=12)),
                ('snapshot', models.JSONField()),
                ('is_active', models.BooleanField(default=True)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('reopened_at', models.DateTimeField(blank=True, null=True)),
                ('reopen_reason', models.CharField(blank=True, default='', max_length=1000)),
                ('operator', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='job_settlements', to=settings.AUTH_USER_MODEL)),
                ('order', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='settlements', to='jobs.joborder')),
                ('reopened_by', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name='reopened_job_settlements', to=settings.AUTH_USER_MODEL)),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='shops.shop')),
            ],
        ),
        migrations.CreateModel(
            name='WorkerAccount',
            fields=[
                ('id', models.UUIDField(default=uuid.uuid4, editable=False, primary_key=True, serialize=False)),
                ('username', models.CharField(max_length=150)),
                ('password', models.CharField(max_length=128)),
                ('display_name', models.CharField(max_length=100)),
                ('phone', models.CharField(blank=True, default='', max_length=20)),
                ('is_active', models.BooleanField(default=True)),
                ('auth_version', models.PositiveIntegerField(default=1)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('updated_at', models.DateTimeField(auto_now=True)),
                ('legacy_user', models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, to=settings.AUTH_USER_MODEL)),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='worker_accounts', to='shops.shop')),
            ],
            options={
                'verbose_name': '店铺拍手',
                'verbose_name_plural': '店铺拍手',
            },
        ),
        migrations.AddField(
            model_name='joborder',
            name='worker',
            field=models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name='orders', to='jobs.workeraccount'),
        ),
        migrations.CreateModel(
            name='JobAudit',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('action', models.CharField(max_length=40)),
                ('detail', models.JSONField(default=dict)),
                ('created_at', models.DateTimeField(auto_now_add=True)),
                ('job', models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, to='jobs.job')),
                ('operator', models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, to=settings.AUTH_USER_MODEL)),
                ('shop', models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, to='shops.shop')),
                ('order', models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, to='jobs.joborder')),
                ('worker', models.ForeignKey(null=True, on_delete=django.db.models.deletion.PROTECT, to='jobs.workeraccount')),
            ],
        ),
        migrations.AddIndex(
            model_name='job',
            index=models.Index(fields=['shop', 'status', '-created_at'], name='jobs_job_shop_id_2c8207_idx'),
        ),
        migrations.AddConstraint(
            model_name='job',
            constraint=models.CheckConstraint(condition=models.Q(('cost_amount__gte', 0), ('refund_amount__gte', 0)), name='job_amounts_nonnegative'),
        ),
        migrations.AddIndex(
            model_name='jobparcel',
            index=models.Index(fields=['shop', 'tracking_number', 'is_active'], name='jobs_jobpar_shop_id_579467_idx'),
        ),
        migrations.AddConstraint(
            model_name='jobparcel',
            constraint=models.UniqueConstraint(condition=models.Q(('is_active', True)), fields=('order', 'tracking_number'), name='active_order_tracking'),
        ),
        migrations.AddConstraint(
            model_name='jobphoto',
            constraint=models.UniqueConstraint(fields=('job', 'position'), name='job_photo_position'),
        ),
        migrations.AddConstraint(
            model_name='jobphoto',
            constraint=models.UniqueConstraint(fields=('job', 'media'), name='job_photo_media'),
        ),
        migrations.AddConstraint(
            model_name='operationreceipt',
            constraint=models.UniqueConstraint(fields=('shop', 'actor_key', 'operation_id'), name='job_actor_operation'),
        ),
        migrations.AddConstraint(
            model_name='settlement',
            constraint=models.UniqueConstraint(condition=models.Q(('is_active', True)), fields=('order',), name='one_active_order_settlement'),
        ),
        migrations.AddConstraint(
            model_name='workeraccount',
            constraint=models.UniqueConstraint(fields=('shop', 'username'), name='worker_shop_username'),
        ),
        migrations.AddIndex(
            model_name='joborder',
            index=models.Index(fields=['shop', '-updated_at'], name='jobs_jobord_shop_id_f31796_idx'),
        ),
        migrations.AddIndex(
            model_name='joborder',
            index=models.Index(fields=['worker', '-updated_at'], name='jobs_jobord_worker__1805ad_idx'),
        ),
        migrations.AddConstraint(
            model_name='joborder',
            constraint=models.UniqueConstraint(fields=('job', 'worker', 'order_number'), name='worker_job_order_number'),
        ),
    ]
