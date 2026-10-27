import 'package:flutter/material.dart';

import '../data/local_inventory_database.dart';
import '../domain/workspace_profile.dart';
import 'login_page.dart';

/// 工作区列表只读取本机记录，只有主动登录时才访问服务器。
class WorkspaceSettingsPage extends StatefulWidget {
  const WorkspaceSettingsPage({super.key, required this.database});

  final LocalInventoryDatabase database;

  @override
  State<WorkspaceSettingsPage> createState() => _WorkspaceSettingsPageState();
}

class _WorkspaceSettingsPageState extends State<WorkspaceSettingsPage> {
  List<SavedWorkspace> _workspaces = [];
  SavedWorkspace? _current;
  bool _loading = true;
  bool _switching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await widget.database.loadSavedWorkspaces();
      SavedWorkspace? current;
      try {
        current = await widget.database.loadDefaultWorkspace();
      } catch (_) {
        // 默认项损坏时仍允许从已保存列表恢复，不能擅自切入别的店铺。
      }
      if (!mounted) return;
      setState(() {
        _workspaces = entries;
        _current = current;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '无法读取已保存工作区：$error';
        _loading = false;
      });
    }
  }

  Future<void> _select(SavedWorkspace entry) async {
    if (_switching || entry.id == _current?.id) return;
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      await widget.database.activateSavedWorkspace(entry.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = '未切换工作区，原选择已保留：$error');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _authenticate({SavedWorkspace? entry}) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => LoginPage(
                database: widget.database,
                selectionOnly: true,
                initialServerUrl: entry?.serverUrl,
                initialUsername: entry?.accountName,
              )));
      if (changed == true && mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开登录，原工作区已保留：$error');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_switching,
        child: Scaffold(
          appBar: AppBar(title: const Text('工作区与账户')),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(padding: const EdgeInsets.all(20), children: [
                  const Text('下次启动将直接进入当前默认工作区，无需重新选择。'),
                  const SizedBox(height: 8),
                  const Text('已登录店铺可离线使用本机已有数据，联网后继续增量同步。切换不会清除原工作区的记录和图片。'),
                  const SizedBox(height: 20),
                  for (final entry in _workspaces)
                    Card(
                      child: ListTile(
                        leading: Icon(entry.isLocal
                            ? Icons.phone_android
                            : Icons.storefront_outlined),
                        title: Text(entry.shopName,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            entry.isLocal
                                ? '完全本地 · 不连接服务器'
                                : '${entry.accountName.isEmpty ? '已保存账户' : entry.accountName}\n${entry.serverUrl}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        isThreeLine: !entry.isLocal,
                        selected: entry.id == _current?.id,
                        trailing: entry.id == _current?.id
                            ? const Text('当前默认')
                            : const Icon(Icons.chevron_right),
                        onTap: _switching ? null : () => _select(entry),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.red))),
                  if (_switching) const LinearProgressIndicator(),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _switching ? null : () => _authenticate(),
                    icon: const Icon(Icons.add),
                    label: const Text('在线登录或添加店铺'),
                  ),
                  if (_current != null && !_current!.isLocal)
                    OutlinedButton.icon(
                      onPressed: _switching
                          ? null
                          : () => _authenticate(entry: _current),
                      icon: const Icon(Icons.login),
                      label: const Text('重新认证当前店铺账户'),
                    ),
                ]),
        ),
      );
}
