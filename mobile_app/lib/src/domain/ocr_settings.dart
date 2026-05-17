class OcrSettings {
  static const double defaultRowMergeTolerance = 0.30;
  static const double minRowMergeTolerance = 0.20;
  static const double maxRowMergeTolerance = 0.60;

  static double normalizeRowMergeTolerance(num? value) {
    final parsed = value?.toDouble();
    if (parsed == null || parsed.isNaN || parsed.isInfinite) {
      return defaultRowMergeTolerance;
    }
    return parsed.clamp(minRowMergeTolerance, maxRowMergeTolerance).toDouble();
  }
}
