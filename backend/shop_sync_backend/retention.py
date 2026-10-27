from django.http import JsonResponse


class RetentionMiddleware:
    """Retire old mutators before schema parsing or any legacy handler executes."""
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = request.path.rstrip('/')
        if path in ('/api/sync/push', '/api/sync/pull'):
            return JsonResponse({'message': 'Legacy sync retired; use /api/sync/v2.', 'code': 'protocol_retired'}, status=410)
        if path.startswith('/api/inventory') and request.method not in ('GET', 'HEAD', 'OPTIONS'):
            return JsonResponse({'message': 'Inventory is read-only; retained documents are written through sync v2. Local deletion never deletes server data.', 'code': 'retention_read_only'}, status=405)
        return self.get_response(request)
