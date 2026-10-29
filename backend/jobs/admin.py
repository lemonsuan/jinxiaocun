"""业务表只读，避免后台编辑绕过版本、所有权和结算留痕。"""
from django.contrib import admin
from .models import Job, JobAudit, JobOrder, JobParcel, JobPhoto, OperationReceipt, Settlement, WorkerAccount, WorkerMediaUpload, WorkerPayoutProfile, JobOrderPhoto


class ReadOnlyJobAdmin(admin.ModelAdmin):
    def has_module_permission(self, request):
        return request.user.is_superuser

    def has_view_permission(self, request, obj=None):
        return request.user.is_superuser

    def get_queryset(self, request):
        rows = super().get_queryset(request)
        return rows if request.user.is_superuser else rows.none()

    def get_exclude(self, request, obj=None):
        return ('password',) if self.model is WorkerAccount else None

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def get_readonly_fields(self, request, obj=None):
        return [field.name for field in self.model._meta.fields if field.name != 'password']


for model in [Job, JobAudit, JobOrder, JobParcel, JobPhoto, OperationReceipt, Settlement, WorkerAccount, WorkerMediaUpload, WorkerPayoutProfile, JobOrderPhoto]:
    admin.site.register(model, ReadOnlyJobAdmin)
