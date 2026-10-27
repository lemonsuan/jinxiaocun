import 'package:flutter/material.dart';

import '../data/local_inventory_database.dart';
import 'app_home.dart';
import 'workspace_settings_page.dart';

/// 启动只读取本机默认项，不把登录或网络连通检查放在进入主页之前。
class WorkspaceBootstrapPage extends StatefulWidget {
  const WorkspaceBootstrapPage({super.key, this.database, this.homeBuilder});

  final LocalInventoryDatabase? database;
  final WidgetBuilder? homeBuilder;

  @override
  State<WorkspaceBootstrapPage> createState() => _WorkspaceBootstrapPageState();
}

class _WorkspaceBootstrapPageState extends State<WorkspaceBootstrapPage> {
  late final LocalInventoryDatabase _database =
      widget.database ?? LocalInventoryDatabase();
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => _error = null);
    try {
      await _database.open();
      await _database.ensureDefaultWorkspace();
      // 启动连接用完即释放；主页按已提交的默认项打开自己的不可变工作区。
      if (widget.database == null) await _database.close();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _error = '无法打开上次工作区：$error');
    }
  }

  Future<void> _recover() async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => WorkspaceSettingsPage(database: _database)));
    if (changed == true && mounted) await _initialize();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.homeBuilder?.call(context) ?? const AppHome();
    return Scaffold(
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _initialize, child: const Text('重试')),
                  TextButton(
                      onPressed: _recover, child: const Text('从设置恢复工作区')),
                ]),
              ),
      ),
    );
  }
}
