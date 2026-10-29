/// 按预览冻结的本机清理计划，不能扩大到预览之后新增的单据。
class LocalPurgePlan {
  LocalPurgePlan(
      {required this.from,
      required this.to,
      required this.scope,
      required Map<String, String> fingerprints,
      required this.imageCount,
      required this.sharedImageCount,
      required Map<String, int> skippedReasons})
      : fingerprints = Map.unmodifiable(fingerprints),
        skippedReasons = Map.unmodifiable(skippedReasons);
  final DateTime from, to;
  final Object scope;
  final Map<String, String> fingerprints;
  final int imageCount, sharedImageCount;
  final Map<String, int> skippedReasons;
  int get receiptCount => fingerprints.length;
  List<String> get receiptIds => List.unmodifiable(fingerprints.keys);
}

class LocalPurgeResult {
  const LocalPurgeResult(
      {required this.receiptCount,
      required this.deletedImageCount,
      required this.sharedImageCount,
      required this.pendingImageCount});
  final int receiptCount,
      deletedImageCount,
      sharedImageCount,
      pendingImageCount;
}

class LocalPurgePlanChanged implements Exception {
  const LocalPurgePlanChanged([this.message = '单据或工作区已变化，请重新预览后再清理']);
  final String message;
  @override
  String toString() => message;
}
