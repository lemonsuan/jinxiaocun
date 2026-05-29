import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/local_inventory_database.dart';
import '../domain/models.dart';

class BackupManagementPage extends StatefulWidget {
  final LocalInventoryDatabase database;
  final VoidCallback? onDatabaseRestored;

  const BackupManagementPage({
    super.key,
    required this.database,
    this.onDatabaseRestored,
  });

  @override
  State<BackupManagementPage> createState() => _BackupManagementPageState();
}

class _BackupManagementPageState extends State<BackupManagementPage> {
  bool _isLoading = false;
  List<FileSystemEntity> _backupFiles = [];

  @override
  void initState() {
    super.initState();
    _loadBackupList();
  }

  Future<Directory> _getBackupDir() async {
    final docDir = await getApplicationDocumentsDirectory();
    final backupDir = Directory(p.join(docDir.path, 'backups'));
    if (!await backupDir.exists()) {
      await backupDir.create(recursive: true);
    }
    return backupDir;
  }

  Future<void> _loadBackupList() async {
    setState(() => _isLoading = true);
    try {
      final dir = await _getBackupDir();
      final list = dir.listSync();
      // 只筛选 json 备份文件并按最后修改时间排序
      list.retainWhere((entity) => entity is File && entity.path.endsWith('.json'));
      list.sort((a, b) {
        return b.statSync().modified.compareTo(a.statSync().modified);
      });
      setState(() {
        _backupFiles = list;
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _exportBackup() async {
    setState(() => _isLoading = true);
    try {
      final bytes = await widget.database.exportBackupBytes();
      final dir = await _getBackupDir();
      
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '-');
      final fileName = 'inventory_backup_$timestamp.json';
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(bytes, flush: true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份导出成功！已保存为: $fileName')),
        );
      }
      _loadBackupList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份导出失败: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _importExternalBackup() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.single.path == null) {
        return;
      }
      final file = File(result.files.single.path!);
      final bytes = await file.readAsBytes();
      
      if (mounted) {
        _showRestoreConfirmationDialog(bytes, result.files.single.name);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择备份文件失败: $e')),
        );
      }
    }
  }

  Future<void> _restoreFromLocalFile(File file) async {
    try {
      final bytes = await file.readAsBytes();
      _showRestoreConfirmationDialog(bytes, p.basename(file.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取备份文件失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteBackupFile(File file) async {
    try {
      await file.delete();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('备份文件已删除')),
      );
      _loadBackupList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    }
  }

  // 3秒倒计时防误触弹窗锁
  void _showRestoreConfirmationDialog(Uint8List bytes, String fileName) {
    final colorScheme = Theme.of(context).colorScheme;
    
    showDialog(
      context: context,
      barrierDismissible: false, // 强制安全操作
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            int secondsLeft = 3;
            Timer? timer;

            void startCountdown() {
              timer = Timer.periodic(const Duration(seconds: 1), (t) {
                if (secondsLeft > 0) {
                  setStateDialog(() {
                    secondsLeft--;
                  });
                } else {
                  timer?.cancel();
                }
              });
            }

            // 在 initState 模拟
            startCountdown();

            return PopScope(
              canPop: false, // 禁用返回键退出
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: AlertDialog(
                  backgroundColor: colorScheme.surface.withOpacity(0.9),
                  title: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: colorScheme.error),
                      const SizedBox(width: 8),
                      const Text('安全警示', style: TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '您正在尝试恢复系统数据库！',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent),
                      ),
                      const SizedBox(height: 12),
                      Text('此操作将用备份数据覆盖当前手机中的所有库存、商品和单据数据。覆盖后，当前数据将不可恢复！',
                          style: TextStyle(color: colorScheme.outline, fontSize: 13, height: 1.4)),
                      const SizedBox(height: 12),
                      Text('目标备份文件: $fileName',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        timer?.cancel();
                        Navigator.pop(context);
                      },
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: secondsLeft > 0 ? Colors.grey.shade400 : colorScheme.error,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: secondsLeft > 0
                          ? null
                          : () async {
                              timer?.cancel();
                              Navigator.pop(context); // 关弹窗
                              
                              setState(() => _isLoading = true);
                              try {
                                await widget.database.importBackupBytes(bytes);
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('数据库覆盖恢复成功！数据已更新')),
                                  );
                                  widget.onDatabaseRestored?.call();
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('还原失败: $e')),
                                  );
                                }
                              } finally {
                                setState(() => _isLoading = false);
                              }
                            },
                      child: Text(
                        secondsLeft > 0 ? '请仔细阅读确认 (${secondsLeft}s)' : '确认覆盖还原',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('备份管理', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
        actions: [
          IconButton(
            tooltip: '浏览系统文件',
            onPressed: () async {
              try {
                await FilePicker.pickFiles(
                  dialogTitle: '系统文件浏览器',
                  type: FileType.any,
                );
              } catch (_) {}
            },
            icon: const Icon(Icons.folder_open_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 1. 顶部操作看板
                _actionCard(colorScheme),
                const SizedBox(height: 24),

                // 2. 备份历史标头
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '本地历史备份 (${_backupFiles.length})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 8),

                // 3. 备份历史列表
                if (_backupFiles.isEmpty)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
                      child: Column(
                        children: [
                          Icon(Icons.backup_table_outlined, size: 40, color: colorScheme.outline.withOpacity(0.5)),
                          const SizedBox(height: 12),
                          Text(
                            '暂无本地备份记录，点击上方“一键导出”创建您的第一个备份',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colorScheme.outline, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._backupFiles.map((entity) {
                    final file = File(entity.path);
                    final stat = file.statSync();
                    final sizeStr = _formatFileSize(stat.size);
                    final timeStr = _formatDateTime(stat.modified);
                    final name = p.basename(file.path);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      elevation: 0,
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F3ED),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.history, color: Color(0xff2d6a4f), size: 20),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '$timeStr  ·  $sizeStr',
                            style: const TextStyle(fontSize: 11, color: Colors.grey, height: 1.4, fontWeight: FontWeight.w500),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xff2d6a4f),
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () => _restoreFromLocalFile(file),
                              icon: const Icon(Icons.settings_backup_restore, size: 16),
                              label: const Text('还原', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                              onPressed: () => _deleteBackupFile(file),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
    );
  }

  // 1:1 像素级复原导出/导入操作卡片
  Widget _actionCard(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200.withOpacity(0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFFF3E0),
                  foregroundColor: const Color(0xFFE65100),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _exportBackup,
                icon: const Icon(Icons.unarchive_outlined, size: 18),
                label: const Text('导出备份', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE3F2FD),
                  foregroundColor: const Color(0xFF0D47A1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _importExternalBackup,
                icon: const Icon(Icons.publish_outlined, size: 18),
                label: const Text('导入备份', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}