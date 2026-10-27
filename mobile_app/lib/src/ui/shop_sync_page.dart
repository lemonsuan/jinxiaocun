import 'package:flutter/material.dart';
import '../application/shop_sync_service.dart';
import '../data/local_inventory_database.dart';

class ShopSyncPage extends StatefulWidget {
  const ShopSyncPage({super.key, required this.service});
  final ShopSyncService service;
  @override
  State<ShopSyncPage> createState() => _ShopSyncPageState();
}

class _ShopSyncPageState extends State<ShopSyncPage> {
  List<Map<String, Object?>> _conflicts = [];
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
    _load();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
      if (!widget.service.syncing) _load();
    }
  }

  Future<void> _load() async {
    final entries = await widget.service.database.loadSyncConflicts();
    if (mounted) setState(() => _conflicts = entries);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _summary(Object? value) {
    if (value is! Map) return '无可用记录';
    final data = value['data'] is Map ? value['data'] as Map : value;
    final items = data['items'];
    return [
      data['tracking_number'] ??
          data['name'] ??
          data['logistics_number'] ??
          '单据',
      if (items is List)
        ...items.take(12).map((item) =>
            item is Map ? '${item['product_name']} × ${item['quantity']}' : '')
    ].join('\n');
  }

  Future<void> _accept(Map entry) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('采用云端记录？'),
              content: const Text('本机当前内容将采用云端版本。原本机冲突内容会留档。请先核对两边的商品和数量。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('采用云端'))
              ],
            ));
    if (ok == true) {
      await _run(() => widget.service.localChange(() => widget.service.database
          .acceptServerSyncConflict('${entry['operation_id']}')));
    }
  }

  Future<void> _abandon(Map entry) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('放弃未被接受的本机单据？'),
              content: const Text(
                  '这笔新单据已被服务器明确拒绝。放弃后撤销它在本机的待同步库存变化，并保留原内容与图片留档。云端和其他手机数据不变。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('放弃并留档'))
              ],
            ));
    if (ok == true && mounted) {
      await _run(() => widget.service.localChange(() => widget.service.database
          .abandonUnacceptedSyncConflict('${entry['operation_id']}')));
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('店铺同步')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text(widget.service.message),
          const SizedBox(height: 8),
          Text(
              '待同步 ${widget.service.pending} · 待确认 ${widget.service.conflicts}'),
          if (widget.service.lastSuccess != null)
            Text(
                '上次完成：${widget.service.lastSuccess!.toLocal().toString().split('.').first}'),
          const SizedBox(height: 12),
          const Text('新增和修改会同步到同店铺的手机。删除、清理仅在本机隐藏，其他手机和云端保留，店铺库存不变。'),
          FilledButton(
              onPressed: _busy || widget.service.syncing
                  ? null
                  : () => _run(widget.service.sync),
              child: const Text('立即同步')),
          OutlinedButton(
              onPressed: _busy || widget.service.syncing
                  ? null
                  : () => _run(() => widget.service.localChange(
                      widget.service.database.restoreLocallyHiddenRecords)),
              child: const Text('恢复本机隐藏记录')),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
          for (final entry in _conflicts)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${entry['message'] ?? '同一记录被多台手机修改，请核对'}'),
                          const SizedBox(height: 8),
                          const Text('本机内容'),
                          Text(_summary(entry['local_data'])),
                          const SizedBox(height: 8),
                          const Text('云端内容'),
                          Text(_summary(entry['remote_record'])),
                          TextButton(
                              onPressed: _busy ||
                                      widget.service.syncing ||
                                      entry['remote_record'] == null
                                  ? null
                                  : () => _accept(entry),
                              child: const Text('采用云端记录')),
                          if (entry['can_abandon'] == true)
                            TextButton(
                              onPressed: _busy || widget.service.syncing
                                  ? null
                                  : () => _abandon(entry),
                              child: const Text('放弃未被接受的本机单据'),
                            ),
                          if (entry['remote_record'] == null &&
                              entry['can_abandon'] != true)
                            const Text('请核对本机单据内容，修改后重新同步；历史记录和图片已保留。'),
                        ]))),
        ]),
      );
}
