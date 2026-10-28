import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/application/capture_work_coordinator.dart';

void main() {
  test('嵌套拍摄页全部退出才恢复后台任务，重复释放不提前解锁', () {
    final coordinator = CaptureWorkCoordinator();
    final changes = <bool>[];
    coordinator.addListener(() => changes.add(coordinator.isActive));
    final releaseFirst = coordinator.acquire();
    final releaseSecond = coordinator.acquire();
    expect(changes, [true]);
    releaseFirst();
    releaseFirst();
    expect(coordinator.isActive, true);
    releaseSecond();
    expect(coordinator.isActive, false);
    expect(changes, [true, false]);
    releaseSecond();
    expect(changes, [true, false]);
    coordinator.dispose();
  });

  test('恢复后可再次进入相机，移除的监听不再收到通知', () {
    final coordinator = CaptureWorkCoordinator();
    var calls = 0;
    void listener() => calls++;
    coordinator.addListener(listener);
    coordinator.acquire()();
    coordinator.removeListener(listener);
    final release = coordinator.acquire();
    expect(coordinator.isActive, true);
    release();
    expect(calls, 2);
    coordinator.dispose();
  });

  test('测试协调器释放后迟到租约清理安全，不允许重新获取', () {
    final coordinator = CaptureWorkCoordinator();
    final release = coordinator.acquire();
    coordinator.dispose();
    expect(release, returnsNormally);
    expect(coordinator.acquire, throwsStateError);
  });
}
