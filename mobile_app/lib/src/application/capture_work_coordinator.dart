import 'package:flutter/foundation.dart';

/// 拍摄作业协调器（租约调度管理器）。
///
/// 核心职责：解决连续拍照录单与后台重度图像处理（如 EXIF 方向校正、大图裁剪、本地 OCR 深度推理）
/// 之间的 CPU/内存资源争抢问题。
/// - 当用户处于拍摄取景界面时，持有该协调器的租约；
/// - 租约生效期间（[isActive] 为 true），全局队列暂停派发新的后台耗时处理任务，确保相机帧率稳定且快门零卡顿；
/// - 退出拍摄页后释放租约，后台队列自动唤醒并继续消化积压的图像解析任务。
class CaptureWorkCoordinator extends ChangeNotifier {
  CaptureWorkCoordinator();

  /// 全局共享的单例实例。
  static final instance = CaptureWorkCoordinator();

  /// 当前活跃的租约持有计数（支持嵌套页面与多个拍摄组件重叠）。
  int _leases = 0;

  /// 标识本协调器是否已被销毁。
  bool _disposed = false;

  /// 是否有处于活跃状态的拍摄租约。
  bool get isActive => _leases > 0;

  /// 申请持有一份拍摄租约。
  ///
  /// 返回用于释放租约的回调函数 [VoidCallback]，支持安全重复调用（幂等）。
  VoidCallback acquire() {
    if (_disposed) throw StateError('拍摄协调器已关闭');
    final wasActive = isActive;
    _leases++;
    if (!wasActive) notifyListeners();
    var released = false;
    return () {
      if (released || _disposed) return;
      released = true;
      _leases--;
      if (!isActive) notifyListeners();
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _leases = 0;
    super.dispose();
  }
}
