bool allowsEmptyInboundItemsForTracking(String trackingNumber) {
  final normalized =
      trackingNumber.trim().replaceAll(RegExp(r'[\s-]+'), '').toUpperCase();
  if (normalized.isEmpty) {
    return false;
  }
  return normalized.startsWith('SF') ||
      RegExp(r'^\d{12,15}$').hasMatch(normalized);
}
