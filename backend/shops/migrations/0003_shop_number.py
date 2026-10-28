"""为已有店铺稳定补号，保留原UUID及全部业务关联。"""
from django.db import migrations, models


def allocate_existing_numbers(apps, schema_editor):
    Shop = apps.get_model('shops', 'Shop')
    Sequence = apps.get_model('shops', 'ShopNumberSequence')
    alias = schema_editor.connection.alias
    number = 10000
    for shop in Shop.objects.using(alias).order_by('created_at', 'id').iterator():
        if shop.shop_number is None:
            Shop.objects.using(alias).filter(pk=shop.pk).update(shop_number=number)
            number += 1
        else:
            number = max(number, shop.shop_number + 1)
    Sequence.objects.using(alias).update_or_create(pk=1, defaults={'next_number': number})


class Migration(migrations.Migration):
    dependencies = [
        ('shops', '0002_customuser_phone'),
        ('inventory', '0006_alter_inboundreceipt_ocr_status'),
    ]

    operations = [
        migrations.CreateModel(
            name='ShopNumberSequence',
            fields=[
                ('id', models.PositiveSmallIntegerField(default=1, editable=False, primary_key=True, serialize=False)),
                ('next_number', models.PositiveBigIntegerField(default=10000, editable=False)),
            ],
            options={'verbose_name': '店铺编号计数器', 'verbose_name_plural': '店铺编号计数器'},
        ),
        migrations.AddConstraint(
            model_name='shopnumbersequence',
            constraint=models.CheckConstraint(condition=models.Q(id=1), name='shop_number_single_counter'),
        ),
        migrations.AddConstraint(
            model_name='shopnumbersequence',
            constraint=models.CheckConstraint(condition=models.Q(next_number__gte=10000), name='shop_number_counter_floor'),
        ),
        migrations.AddField(
            model_name='shop', name='shop_number',
            field=models.PositiveBigIntegerField(editable=False, null=True, unique=True, verbose_name='店铺ID'),
        ),
        migrations.RunPython(allocate_existing_numbers, migrations.RunPython.noop),
        migrations.AlterField(
            model_name='shop', name='shop_number',
            field=models.PositiveBigIntegerField(editable=False, unique=True, verbose_name='店铺ID'),
        ),
        migrations.AddConstraint(
            model_name='shop',
            constraint=models.CheckConstraint(condition=models.Q(shop_number__gte=10000), name='shop_number_minimum'),
        ),
    ]
