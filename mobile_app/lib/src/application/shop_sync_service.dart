import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/local_inventory_database.dart';

/// 为已打开且固定的店铺数据库执行有界、可重试的增量同步。
class ShopSyncService extends ChangeNotifier {
  ShopSyncService(this.database, {http.Client? client, this.mediaDirectory})
      : _client = client ?? http.Client();
  final LocalInventoryDatabase database;
  final http.Client _client;
  final Future<Directory> Function()? mediaDirectory;
  Timer? _timer;
  Future<void>? _running;
  Future<void>? _queuedManual;
  bool _runningAutomatically = false;
  bool _disposed = false;
  int _pauseDepth = 0;
  bool get _paused => _pauseDepth > 0;
  bool _foreground = true;
  Map<String, Object?>? _authenticationBlockedContext;
  bool syncing = false;
  String message = '等待同步';
  DateTime? lastSuccess;
  int pending = 0;
  int conflicts = 0;
  int dataVersion = 0;
  static const _maxImage = 15 * 1024 * 1024;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      if (_foreground) unawaited(sync(automatic: true));
    });
    unawaited(sync(automatic: true));
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value) unawaited(sync(automatic: true));
  }

  /// 手动同步允许重新验证原凭据，自动触发则遵守认证暂停状态。
  Future<void> sync({bool automatic = false}) {
    final running = _running;
    if (running != null) {
      if (!automatic &&
          _runningAutomatically &&
          _authenticationBlockedContext != null) {
        // 自动检查可能直接跳过失效凭据，不能吞掉此时到来的手动重试。
        return _queuedManual ??= _retryManuallyAfter(running)
            .whenComplete(() => _queuedManual = null);
      }
      return running;
    }
    _runningAutomatically = automatic;
    return _running = _cycle(automatic: automatic).whenComplete(() {
      _running = null;
      _runningAutomatically = false;
    });
  }

  Future<void> _retryManuallyAfter(Future<void> running) async {
    await running;
    if (!_disposed) await sync();
  }

  /// 暂停新请求并等待当前请求结束；迟到响应会被作用域检查拒绝。
  Future<void> pauseAndDrain() async {
    _pauseDepth++;
    await _running;
  }

  /// 每次暂停对应一次恢复，嵌套的本机操作不会解除设置页的暂停。
  void resume() {
    if (_pauseDepth == 0) return;
    _pauseDepth--;
    if (!_paused && !_disposed && _foreground) {
      unawaited(sync(automatic: true));
    }
  }

  Future<void> localChange(Future<void> Function() action) async {
    await pauseAndDrain();
    try {
      if (_disposed) return;
      await action();
      dataVersion++;
    } finally {
      resume();
    }
    await sync();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _guard(Map<String, Object?> context) async {
    if (_disposed || !_foreground || _paused) throw const _ScopeChanged();
    final current = await database.loadSyncContext();
    if (_disposed ||
        !_foreground ||
        _paused ||
        current == null ||
        ['server_url', 'shop_id', 'device_id', 'token']
            .any((key) => current[key] != context[key])) {
      throw const _ScopeChanged();
    }
  }

  Uri _uri(Map context, String endpoint) =>
      Uri.parse('${context['server_url']}$endpoint');
  Map<String, String> _headers(Map context) => {
        'Authorization': 'Bearer ${context['token']}',
        'X-Active-Shop-ID': '${context['shop_id']}',
      };

  Future<Map<String, dynamic>> _json(
      Map<String, Object?> context, String endpoint,
      {Map<String, Object?>? body, bool allow404 = false}) async {
    await _guard(context);
    final request =
        http.Request(body == null ? 'GET' : 'POST', _uri(context, endpoint))
          ..followRedirects = false
          ..headers.addAll(_headers(context));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response =
        await _client.send(request).timeout(const Duration(seconds: 30));
    final bytes = <int>[];
    await for (final chunk
        in response.stream.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > 8 * 1024 * 1024) throw const FormatException('同步响应过大');
    }
    await _guard(context);
    if (allow404 && response.statusCode == 404) return {'exists': false};
    _checkStatus(response.statusCode);
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('同步响应格式错误');
    }
    return decoded;
  }

  void _checkStatus(int status) {
    if (status == 401) {
      throw const _AuthenticationRequired('登录已过期，请在设置中重新认证；本机数据已保留');
    }
    if (status == 403) {
      throw const _AuthenticationRequired('没有店铺访问权限，请在设置中检查审批或重新认证；本机数据已保留');
    }
    if (status < 200 || status >= 300) {
      throw HttpException('服务器返回 $status，请稍后重试');
    }
    // 成功鉴权已证明凭据恢复，后续非认证错误仍应允许自动重试。
    _authenticationBlockedContext = null;
  }

  Future<String?> _upload(Map<String, Object?> context, Object? value) async {
    if (value == null || '$value'.isEmpty) return null;
    final path = '$value';
    if (path.startsWith('sync://')) return path.substring(7);
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size > _maxImage) {
      throw const FileSystemException('同步图片不存在或超过15MB');
    }
    var digest = await database.syncMediaDigest(
        path, stat.size, stat.modified.microsecondsSinceEpoch);
    digest ??= (await sha256.bind(file.openRead()).first).toString();
    final exists = await _json(context, '/api/sync/v2/media/$digest/exists',
        allow404: true);
    if (exists['exists'] != true) {
      await _guard(context);
      final request =
          http.MultipartRequest('POST', _uri(context, '/api/sync/v2/media'))
            ..followRedirects = false
            ..headers.addAll(_headers(context))
            ..fields['sha256'] = digest
            ..files.add(await http.MultipartFile.fromPath('file', path));
      final response =
          await _client.send(request).timeout(const Duration(seconds: 60));
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 60))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const FormatException('图片上传响应过大');
        }
      }
      await _guard(context);
      if ([400, 413, 422].contains(response.statusCode)) {
        throw const FormatException('图片格式或大小不符合服务器要求');
      }
      _checkStatus(response.statusCode);
      final result = jsonDecode(utf8.decode(bytes));
      if (result is! Map || result['sha256'] != digest) {
        throw const FormatException('图片校验失败');
      }
    }
    await database.rememberSyncMedia(
        path, stat.size, stat.modified.microsecondsSinceEpoch, digest);
    return digest;
  }

  Future<void> _push(Map<String, Object?> context,
      List<Map<String, Object?>> operations) async {
    if (operations.isEmpty) return;
    final response = await _json(context, '/api/sync/v2/push', body: {
      'device_id': context['device_id'],
      'operations': operations,
    });
    final results = response['results'];
    final expected = operations.map((op) => op['operation_id']).toSet();
    if (results is! List ||
        results.length != operations.length ||
        results.any((r) =>
            r is! Map ||
            !expected.remove(r['operation_id']) ||
            !['applied', 'duplicate', 'conflict'].contains(r['status'])) ||
        expected.isNotEmpty) {
      throw const FormatException('服务器确认不完整，已保留待重试数据');
    }
    await _guard(context);
    await database.applySyncPushResults(results.cast<Map>());
  }

  Future<void> _cycle({required bool automatic}) async {
    if (_disposed || !_foreground || _paused) return;
    final context = await database.loadSyncContext();
    if (context == null) return;
    final blocked = _authenticationBlockedContext;
    final sameRejectedCredentials = blocked != null &&
        ['server_url', 'shop_id', 'device_id', 'token']
            .every((key) => context[key] == blocked[key]);
    if (automatic && sameRejectedCredentials) {
      // 暂停的是服务器请求，本机新增和冲突数量仍需及时显示。
      pending = await database.pendingSyncCount();
      conflicts = await database.syncConflictCount();
      _notify();
      return;
    }
    if (!sameRejectedCredentials) _authenticationBlockedContext = null;
    syncing = true;
    message = '正在增量同步';
    _notify();
    try {
      await _push(context, await database.pendingSyncOperations(limit: 30));
      final candidates = await database.pendingSyncRecords(limit: 100);
      final operations = <Map<String, Object?>>[];
      final mediaProblems = <String>[];
      for (final candidate in candidates) {
        if (operations.length >= 30) break;
        final data = Map<String, Object?>.from(candidate['data'] as Map);
        try {
          if (candidate['kind'] == 'inbound') {
            data['image_sha256'] =
                await _upload(context, data.remove('image_path'));
          } else if (candidate['kind'] == 'outbound') {
            final images = data.remove('image_paths') as List? ?? [];
            data['image_sha256s'] = [
              for (final image in images) await _upload(context, image)
            ];
          }
        } on FileSystemException {
          mediaProblems.add(
              '${data['tracking_number'] ?? data['logistics_number'] ?? '单据'}：本机图片缺失或无法读取');
          continue;
        } on FormatException {
          mediaProblems.add(
              '${data['tracking_number'] ?? data['logistics_number'] ?? '单据'}：图片校验失败，已保留待处理');
          continue;
        }
        await _guard(context);
        operations.add(await database.freezeSyncOperation(candidate, data));
      }
      await _push(context, operations);
      var cursor = await database.loadSyncCursor();
      for (var page = 0; page < 10; page++) {
        final result =
            await _json(context, '/api/sync/v2/pull?cursor=$cursor&limit=100');
        final changes = result['changes'];
        final next = result['cursor'];
        final more = result['has_more'];
        if (changes is! List ||
            next is! int ||
            next < cursor ||
            more is! bool ||
            (more && next == cursor)) {
          throw const FormatException('增量游标无效');
        }
        await _guard(context);
        await database.applySyncPull(changes.cast<Map>(), next);
        if (changes.isNotEmpty) dataVersion++;
        cursor = next;
        if (!more) break;
      }
      await _downloadMedia(context);
      _authenticationBlockedContext = null;
      if (mediaProblems.isEmpty) {
        message = '本轮增量已处理；删除仅影响本机';
      } else {
        message =
            '仍有 ${mediaProblems.length} 笔图片待处理；其他正常记录已同步。${mediaProblems.take(3).join('；')}';
      }
    } on _AuthenticationRequired catch (error) {
      // 只暂停本轮捕获的凭据；新登录或新工作区下次自动触发即可恢复。
      _authenticationBlockedContext = Map<String, Object?>.from(context);
      message = '同步已暂停：${error.message}';
    } on _ScopeChanged {
      message = '同步已暂停';
    } catch (error) {
      message = _failureMessage(error);
    } finally {
      if (!_disposed) {
        pending = await database.pendingSyncCount();
        conflicts = await database.syncConflictCount();
        if (pending == 0 && conflicts == 0 && message.startsWith('本轮增量')) {
          lastSuccess = DateTime.now();
        }
        if (conflicts > 0 && message.startsWith('本轮增量')) {
          message = '有 $conflicts 笔同步冲突待确认，原内容已保留';
        } else if (pending > 0 && message.startsWith('本轮增量')) {
          message = '本轮增量已处理，仍有 $pending 笔待同步';
        }
        syncing = false;
        _notify();
      }
    }
  }

  String _failureMessage(Object error) {
    if (error is SocketException || error is http.ClientException) {
      return '当前离线，可继续使用本机数据；恢复网络后自动同步';
    }
    if (error is TimeoutException) {
      return '连接超时，可继续使用本机数据；稍后自动重试';
    }
    if (error is FormatException) {
      return '同步数据或图片校验失败，本机内容已保留，请稍后重试';
    }
    if (error is FileSystemException) {
      return '本机图片暂时无法读取，原单据已保留，请检查图片后重试';
    }
    if (error is HttpException) {
      return '服务器暂时无法完成同步，本机数据已保留，请稍后重试';
    }
    return '同步暂未完成，本机数据已保留，请稍后重试';
  }

  Future<void> _downloadMedia(Map<String, Object?> context) async {
    final references = await database.pendingSyncMediaDownloads(limit: 10);
    if (references.isEmpty) return;
    final root = mediaDirectory == null
        ? Directory(
            '${(await getApplicationDocumentsDirectory()).path}/cloud_media')
        : await mediaDirectory!();
    await root.create(recursive: true);
    for (final reference in references) {
      final digest = '${reference['sha256']}';
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('图片摘要无效');
      }
      // 文件名包含工作区摘要，避免不同店铺或服务器复用图片路径。
      final scope = sha256.convert(
          utf8.encode('${context['server_url']}|${context['shop_id']}'));
      final file = File('${root.path}/$scope-$digest');
      if (await file.exists() &&
          (await sha256.bind(file.openRead()).first).toString() != digest) {
        await file.delete();
      }
      if (!await file.exists()) {
        await _guard(context);
        final request =
            http.Request('GET', _uri(context, '/api/sync/v2/media/$digest'))
              ..followRedirects = false
              ..headers.addAll(_headers(context));
        final response =
            await _client.send(request).timeout(const Duration(seconds: 30));
        _checkStatus(response.statusCode);
        final temp = File('${file.path}.part');
        final sink = temp.openWrite();
        try {
          var size = 0;
          await for (final chunk
              in response.stream.timeout(const Duration(seconds: 30))) {
            size += chunk.length;
            if (size > _maxImage) throw const FormatException('图片超过15MB');
            sink.add(chunk);
          }
          await sink.flush();
          await sink.close();
          if ((await sha256.bind(temp.openRead()).first).toString() != digest) {
            throw const FormatException('下载图片校验失败');
          }
          await _guard(context);
          await temp.rename(file.path);
        } catch (_) {
          await sink.close();
          if (await temp.exists()) await temp.delete();
          rethrow;
        }
      }
      await _guard(context);
      await database.attachSyncMedia(reference, file.path);
      dataVersion++;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client.close();
    super.dispose();
  }
}

class _ScopeChanged implements Exception {
  const _ScopeChanged();
}

/// 服务器明确拒绝认证后暂停自动重试，避免定时器反复使用失效凭据。
class _AuthenticationRequired implements Exception {
  const _AuthenticationRequired(this.message);
  final String message;
}
