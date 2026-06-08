import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/local_inventory_database.dart';

class DataManagementPage extends StatefulWidget {
  final LocalInventoryDatabase database;
  final VoidCallback? onDatabaseRestored;

  const DataManagementPage({
    super.key,
    required this.database,
    this.onDatabaseRestored,
  });

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  bool _isLoading = false;
  List<FileSystemEntity> _backupFiles = [];

  // 清理数据复选框状态
  bool _clearTextSelected = false;
  bool _clearImagesSelected = false;

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
      list.retainWhere(
          (entity) => entity is File && entity.path.endsWith('.json'));
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

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final fileName = 'inventory_backup_$timestamp.json';
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(bytes, flush: true);

      bool exportedToDownloads = false;
      if (Platform.isAndroid) {
        try {
          final bool? success =
              await const MethodChannel('inventory_app/system_utils')
                  .invokeMethod<bool>('saveToDownloads', {
            'fileName': fileName,
            'bytes': bytes,
          });
          exportedToDownloads = success ?? false;
        } catch (e) {
          debugPrint('写入公共 Downloads 失败: $e');
        }
      }

      if (mounted) {
        String msg = '备份导出成功！已保存为本地还原点';
        if (exportedToDownloads) {
          msg = '备份成功！已导出到系统「Download/」目录并生成本地还原点';
        } else {
          msg = '备份成功！已保存为本地还原点: $fileName';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 3),
          ),
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

  void _showRestoreConfirmationDialog(Uint8List bytes, String fileName) {
    final colorScheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: AlertDialog(
              shape: const RoundedRectangleBorder(),
              backgroundColor: colorScheme.surface.withOpacity(0.9),
              title: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: colorScheme.error),
                  const SizedBox(width: 8),
                  const Text('安全警示',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '您正在尝试恢复系统数据库！',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.redAccent),
                  ),
                  const SizedBox(height: 12),
                  Text('此操作将用备份数据覆盖当前手机中的所有库存、商品和单据数据。覆盖后，当前数据将不可恢复！',
                      style: TextStyle(
                          color: colorScheme.outline,
                          fontSize: 13,
                          height: 1.4)),
                  const SizedBox(height: 12),
                  Text('目标备份文件: $fileName',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 12)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(),
                  ),
                  onPressed: () async {
                    Navigator.pop(dialogContext);

                    setState(() => _isLoading = true);
                    try {
                      await widget.database.importBackupBytes(bytes);
                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('数据库覆盖恢复成功！数据已更新')),
                        );
                        widget.onDatabaseRestored?.call();
                      }
                    } catch (e) {
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('还原失败: $e')),
                        );
                      }
                    } finally {
                      setState(() => _isLoading = false);
                    }
                  },
                  child: const Text(
                    '确认覆盖还原',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showClearConfirmationDialog() {
    if (!_clearTextSelected && !_clearImagesSelected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少勾选一项要清理的数据类型')),
      );
      return;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);

    final List<String> targetDescriptions = [];
    if (_clearTextSelected) {
      targetDescriptions.add('已结算的文本数据 (包含入库单、商品明细、库存和流水记录)');
    }
    if (_clearImagesSelected) {
      targetDescriptions.add('已结算单据关联的物理图片文件');
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: AlertDialog(
              shape: const RoundedRectangleBorder(),
              backgroundColor: colorScheme.surface.withOpacity(0.9),
              title: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: colorScheme.error),
                  const SizedBox(width: 8),
                  const Text('清除确认',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '⚠️ 警告：此操作不可逆！',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.redAccent),
                  ),
                  const SizedBox(height: 12),
                  const Text('您将要永久清空以下勾选的数据：', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  ...targetDescriptions.map((desc) => Padding(
                        padding: const EdgeInsets.only(bottom: 6, left: 4),
                        child: Text('• $desc',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.black87)),
                      )),
                  const SizedBox(height: 12),
                  Text('确定要继续清除这些数据吗？',
                      style: TextStyle(
                          color: colorScheme.outline,
                          fontSize: 13,
                          height: 1.4)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('取消', style: TextStyle(color: Colors.black)),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(),
                  ),
                  onPressed: () async {
                    Navigator.pop(dialogContext);

                    setState(() => _isLoading = true);
                    try {
                      if (_clearTextSelected) {
                        await widget.database.clearSettledTextData();
                      }
                      if (_clearImagesSelected && !_clearTextSelected) {
                        // 如果同时勾选了文本，文本清理函数里已经自动物理删除图片了。
                        // 如果仅勾选了图片清理，则调用独立的图片清理
                        await widget.database.clearSettledImagesData();
                      }

                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('所选的已结算数据清除成功！')),
                        );
                        setState(() {
                          _clearTextSelected = false;
                          _clearImagesSelected = false;
                        });
                        widget.onDatabaseRestored?.call(); // 触发上层刷新
                      }
                    } catch (e) {
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('清除失败: $e')),
                        );
                      }
                    } finally {
                      setState(() => _isLoading = false);
                    }
                  },
                  child: const Text(
                    '确认一键清除',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
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
      backgroundColor: const Color(0xFFFCFCFC),
      appBar: AppBar(
        title: const Text(
          '数据管理',
          style: TextStyle(
            fontWeight: FontWeight.w400,
            fontSize: 16,
            letterSpacing: 1.5,
            color: Color(0xFF1E293B),
          ),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: const Color(0xFF1E293B),
        centerTitle: true,
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
            icon: const Icon(Icons.folder_open_outlined,
                size: 20, color: Color(0xFF64748B)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF1E293B),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              children: [
                // 1. 导出/导入操作卡片
                _actionCard(colorScheme),
                const SizedBox(height: 24),

                // 2. 清理已结算数据卡片
                _clearSettledCard(),
                const SizedBox(height: 24),

                // 3. 备份历史标头
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '本地历史备份 (${_backupFiles.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                const SizedBox(height: 12),

                // 4. 备份历史列表
                if (_backupFiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 32,
                          color: Color(0xFFCBD5E1),
                        ),
                        SizedBox(height: 16),
                        Text(
                          '暂无本地备份记录\n点击上方“导出备份”创建还原点',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 12,
                            height: 1.6,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  ..._backupFiles.map((entity) {
                    final file = File(entity.path);
                    final stat = file.statSync();
                    final sizeStr = _formatFileSize(stat.size);
                    final timeStr = _formatDateTime(stat.modified);
                    final name = p.basename(file.path);

                    return Container(
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Color(0xFFF1F5F9),
                            width: 0.8,
                          ),
                        ),
                      ),
                      child: ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                        onLongPress: () async {
                          if (await file.exists()) {
                            await Share.shareXFiles(
                              [XFile(file.path)],
                              text: '分享商品管理系统数据备份：$name',
                            );
                          }
                        },
                        leading: const Icon(
                          Icons.insert_drive_file_outlined,
                          color: Color(0xFF94A3B8),
                          size: 22,
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1E293B),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '$timeStr  ·  $sizeStr',
                            style: const TextStyle(
                              fontSize: 10,
                              fontFamily: 'monospace',
                              color: Color(0xFF94A3B8),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: const Color(0xFF1E293B),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () => _restoreFromLocalFile(file),
                              child: const Text(
                                '还原',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Color(0xFF94A3B8),
                                size: 18,
                              ),
                              onPressed: () => _deleteBackupFile(file),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              splashRadius: 16,
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

  Widget _actionCard(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: const Color(0xFFE2E8F0),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1E293B),
                side: const BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                  letterSpacing: 1.5,
                ),
              ),
              onPressed: _exportBackup,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.unarchive_outlined, size: 14),
                  SizedBox(width: 8),
                  Text('导出备份'),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: const Color(0xFF1E293B),
                side: const BorderSide(color: Color(0xFF1E293B), width: 0.8),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero),
                padding: const EdgeInsets.symmetric(vertical: 14),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 12,
                  letterSpacing: 1.5,
                ),
              ),
              onPressed: _importExternalBackup,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.publish_outlined, size: 14),
                  SizedBox(width: 8),
                  Text('导入备份'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _clearSettledCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: const Color(0xFFE2E8F0),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🧹 清理已结算数据 (可多选)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            title: const Text('已结算文本数据', style: TextStyle(fontSize: 12)),
            subtitle: const Text('物理清除已勾选结算的入库明细及流水，释放数据库', style: TextStyle(fontSize: 10)),
            value: _clearTextSelected,
            onChanged: (val) {
              setState(() {
                _clearTextSelected = val ?? false;
              });
            },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: Colors.black,
          ),
          CheckboxListTile(
            title: const Text('已结算物理图片', style: TextStyle(fontSize: 12)),
            subtitle: const Text('物理删除已结算单据对应的拍照文件，释放手机存储', style: TextStyle(fontSize: 10)),
            value: _clearImagesSelected,
            onChanged: (val) {
              setState(() {
                _clearImagesSelected = val ?? false;
              });
            },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: Colors.black,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red, width: 0.8),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _showClearConfirmationDialog,
              icon: const Icon(Icons.delete_forever, size: 16),
              label: const Text('一键清空所选数据', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}
