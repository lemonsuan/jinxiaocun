"""将原普通成员降为独立拍手身份，不扩大其管理权限。"""
from django.db import migrations, models


def migrate_workers(apps, schema_editor):
    Membership = apps.get_model('shops', 'ShopMembership')
    Worker = apps.get_model('jobs', 'WorkerAccount')
    alias = schema_editor.connection.alias
    for membership in Membership.objects.using(alias).filter(role='MEMBER').select_related('user').iterator():
        user = membership.user
        name = ' '.join(value for value in [user.first_name, user.last_name] if value).strip() or user.username
        worker, created = Worker.objects.using(alias).get_or_create(
            shop_id=membership.shop_id,
            username=user.username,
            defaults={
                'password': user.password,
                'display_name': name[:100],
                'phone': user.phone,
                'is_active': membership.status == 'APPROVED' and user.is_active,
                'auth_version': 1,
                'legacy_user_id': user.pk,
            },
        )
        if not created and worker.legacy_user_id != user.pk:
            # 不以旧成员密码覆盖另一个已注册的拍手账号。
            raise RuntimeError('旧普通成员与拍手账号重名，请先核对并处理后再迁移。')
        Membership.objects.using(alias).filter(pk=membership.pk).update(role='WORKER')


def restore_legacy_roles(apps, schema_editor):
    Membership = apps.get_model('shops', 'ShopMembership')
    Worker = apps.get_model('jobs', 'WorkerAccount')
    alias = schema_editor.connection.alias
    # 回退只恢复原关系标签，不删除拍手资料、密码或管理操作后的启停状态。
    for worker in Worker.objects.using(alias).exclude(legacy_user_id=None).iterator():
        Membership.objects.using(alias).filter(
            user_id=worker.legacy_user_id, shop_id=worker.shop_id, role='WORKER',
        ).update(role='MEMBER')


class Migration(migrations.Migration):
    dependencies = [
        ('shops', '0003_shop_number'),
        ('jobs', '0001_initial'),
    ]

    operations = [
        migrations.RunPython(migrate_workers, restore_legacy_roles),
        migrations.AlterField(
            model_name='shopmembership', name='role',
            field=models.CharField(
                choices=[('CREATOR', '创建人'), ('ADMIN', '管理员'), ('WORKER', '拍手')],
                default='WORKER', max_length=20, verbose_name='角色',
            ),
        ),
    ]
