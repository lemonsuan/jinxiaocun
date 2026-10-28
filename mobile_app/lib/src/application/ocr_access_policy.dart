import 'dart:async';
import 'package:flutter/foundation.dart';

/// 设备级 OCR 图像识别权限与访问控制策略。
///
/// 具备代际状态追踪（Generation Token）特性：
/// 1. 控制本机是否允许执行离线 PaddleOCR 推理以及云端大模型图文解析；
/// 2. 状态切换持久化存储至本地设备配置（不随云端备份或店铺切换而丢失）；
/// 3. 任何状态的翻转（开启->关闭->再开启）都会使当前正在进行或排队中的旧请求许可证立即失效（抛出 [OcrCancelled] 异常），
///    严格防止迟到的旧 OCR 识别结果错误覆写用户手工录入的数据或篡改已有库存。
class OcrAccessPolicy extends ChangeNotifier {
  OcrAccessPolicy(
      {required Future<bool> Function() read,
      required Future<void> Function(bool) write})
      : _read = read,
        _write = write;

  /// 按设备唯一键缓存的策略实例映射表。
  static final Map<Object, OcrAccessPolicy> _devices = {};

  /// 获取或创建指定设备的 OCR 访问控制策略单例。
  static OcrAccessPolicy forDevice(
    Object key, {
    required Future<bool> Function() read,
    required Future<void> Function(bool) write,
  }) {
    final policy = _devices.putIfAbsent(
        key, () => OcrAccessPolicy(read: read, write: write));
    policy._read = read;
    policy._write = write;
    return policy;
  }

  /// 底层读取持久化开关状态的回调。
  Future<bool> Function() _read;

  /// 底层写入持久化开关状态的回调。
  Future<void> Function(bool) _write;

  /// 正在执行的异步加载任务 Future。
  Future<void>? _loading;

  /// 是否已完成初次从本地读取。
  bool _loaded = false;

  /// 当前内存中的开关状态（默认开启）。
  bool _enabled = true;

  /// 是否正在向磁盘写盘保存。
  bool _saving = false;

  /// 当前策略代际编号，每次开关切换均自增以废除之前派发的许可证。
  int _generation = 0;

  /// 当前 OCR 开关是否处于启用状态。
  bool get enabled => _loaded && _enabled;

  /// 异步预加载持久化配置。
  Future<void> load() => _loaded ? Future.value() : _loading ??= _load();

  Future<void> _load() async {
    try {
      _enabled = await _read();
      _loaded = true;
    } finally {
      _loading = null;
    }
  }

  /// 申请一张当前代际的 OCR 执行许可证。
  ///
  /// 若当前开关处于关闭状态，将立即抛出 [OcrCancelled] 异常终止流程。
  Future<OcrPermit> permit() async {
    await load();
    final value = OcrPermit._(this, _generation);
    value.validate();
    return value;
  }

  /// 切换 OCR 启用/关闭状态并持久化写盘。
  Future<void> setEnabled(bool value) async {
    await load();
    if (_saving) throw StateError('正在保存OCR设置，请稍候');
    if (_enabled == value) return;
    _saving = true;
    final previous = _enabled;
    _enabled = value;
    _generation++;
    notifyListeners();
    try {
      await _write(value);
    } catch (_) {
      _enabled = previous;
      _generation++;
      notifyListeners();
      rethrow;
    } finally {
      _saving = false;
    }
  }
}

/// OCR 执行许可证。
///
/// 绑定了派发时的策略实例及其代际版本 [_generation]。
/// 在执行具体 OCR 推理前、推理后、以及写入数据库前多次校验，保证操作合法性。
class OcrPermit {
  OcrPermit._(this._policy, this._generation);
  final OcrAccessPolicy _policy;
  final int _generation;

  /// 校验本许可证是否与当前活跃策略匹配。
  void validateFor(OcrAccessPolicy policy) {
    if (!identical(policy, _policy)) throw const OcrCancelled();
    validate();
  }

  /// 校验本许可证是否仍有效。
  /// 若策略已被关闭或代际已变更，抛出 [OcrCancelled] 异常。
  void validate() {
    if (!_policy.enabled || _policy._generation != _generation) {
      throw const OcrCancelled();
    }
  }
}

/// OCR 识别被取消或废弃异常。
class OcrCancelled implements Exception {
  const OcrCancelled();
  @override
  String toString() => 'OCR已关闭或设置已变化，请在设置中开启后重新操作；原照片和商品已保留。';
}
