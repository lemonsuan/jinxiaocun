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
  bool _online = false;
  List<FileSystemEntity> _backupFiles = [];

  // 清理数据复选框状态
  bool _clearTextSelected = false;
  bool _clearImagesSelected = false;

  // 图片压缩状态
  bool _isCompressing = false;
  double _compressionProgress = 0.0;
  String _compressionMessage = '';

  @override
  void initState() {
    super.initState();
    _loadBackupList();
    widget.database.loadAuthMode().then((mode) {
      if (mounted) setState(() => _online = mode == 'online');
    });
  }

  Future<void> _startCompression({bool force = false}) async {
    setState(() {
      _isCompressing = true;
      _isLoading = true;
      _compressionProgress = 0.0;
      _compressionMessage = '正在检测7天前的历史大图...';
    });

    try {
      await widget.database.compressOldInboundImages(
        force: force,
        onProgress: (current, total) {
          if (!mounted) return;
          setState(() {
            if (total == 0) {
              _compressionProgress = 1.0;
              _compressionMessage = '没有检测到任何符合条件的可压缩图片';
            } else {
              _compressionProgress = current / total;
              _compressionMessage =
                  '正在压缩: $current / $total 张图片 (${(_compressionProgress * 100).toStringAsFixed(0)}%)';
            }
          });
        },
      );

      await Future.delayed(const Duration(milliseconds: 1000));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('历史图片压缩处理完成！')),
        );
        setState(() {
          _isCompressing = false;
          _isLoading = false;
        });
        widget.onDatabaseRestored?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('图片压缩失败: $e')),
        );
        setState(() {
          _isCompressing = false;
          _isLoading = false;
        });
      }
    }
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
      list.retainWhere((entity) =>
          entity is File &&
          (entity.path.endsWith('.json') || entity.path.endsWith('.zip')));
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

  void _showExportOptionsDialog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '选择导出备份方式',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1E293B),
                        letterSpacing: 0.5,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 20, color: Color(0xFF94A3B8)),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '选择适合当前场景的导出模式，导出的文件均可在本页随时一键导入覆盖恢复：',
                  style: TextStyle(
                      fontSize: 11, color: Color(0xFF64748B), height: 1.4),
                ),
                const SizedBox(height: 14),

                // 选项 1: 纯业务数据备份 (推荐 · 极速稳妥)
                _buildExportOptionTile(
                  icon: Icons.bolt_outlined,
                  iconColor: const Color(0xFF0F766E),
                  iconBg: const Color(0xFFCCFBF1),
                  title: '⚡ 纯业务数据备份 (推荐 · 极速稳妥)',
                  subtitle:
                      '备份所有商品、库存、入库单、出库单及流水台账。\n不打包几百兆大体积照片，体积仅几百KB，0.1秒秒速完成，绝不卡死！本机还原自动关联已有照片。',
                  isRecommended: true,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _exportLightDataBackup();
                  },
                ),
                const SizedBox(height: 10),

                // 选项 2: 全量归档包 (ZIP 流式压缩 · 换机无忧)
                _buildExportOptionTile(
                  icon: Icons.folder_zip_outlined,
                  iconColor: const Color(0xFF2563EB),
                  iconBg: const Color(0xFFDBEAFE),
                  title: '📦 全量归档备份包 (含全部单据照片 · ZIP压缩)',
                  subtitle:
                      '将全部数据库记录与单据照片以流式方式打包为标准 ZIP 包。\n逐张安全写入，带实时进度条，不爆内存，最适合换新手机迁移。',
                  isRecommended: false,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _exportFullZipBackup();
                  },
                ),
                const SizedBox(height: 10),

                // 选项 3: 传统全量 JSON 备份 (旧版兼容模式)
                _buildExportOptionTile(
                  icon: Icons.history_outlined,
                  iconColor: const Color(0xFF64748B),
                  iconBg: const Color(0xFFF1F5F9),
                  title: '📄 传统全量 JSON 备份 (旧版兼容模式)',
                  subtitle: '采用旧版格式将数据与照片内嵌在单个 JSON 文件中。若照片积累过多可能会占用较大内存。',
                  isRecommended: false,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _exportLegacyBackup();
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildExportOptionTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required String title,
    required String subtitle,
    required bool isRecommended,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isRecommended ? const Color(0xFFF0FDF4) : Colors.white,
          border: Border.all(
            color: isRecommended
                ? const Color(0xFF86EFAC)
                : const Color(0xFFE2E8F0),
            width: isRecommended ? 1.2 : 0.8,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconBg,
                shape: BoxShape.rectangle,
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isRecommended
                                ? FontWeight.bold
                                : FontWeight.w600,
                            color: const Color(0xFF1E293B),
                          ),
                        ),
                      ),
                      if (isRecommended)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: const BoxDecoration(
                            color: Color(0xFF0F766E),
                          ),
                          child: const Text(
                            '推荐',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF64748B),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 1. 纯业务数据极速备份（轻量稳妥版，秒级完成，绝不卡死）
  Future<void> _exportLightDataBackup() async {
    setState(() => _isLoading = true);
    try {
      final bytes =
          await widget.database.exportBackupBytes(includeImages: false);
      final dir = await _getBackupDir();

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final fileName = 'inventory_data_$timestamp.json';
      final file = File(p.join(dir.path, fileName));
      await file.writeAsBytes(bytes, flush: true);

      bool exportedToDownloads = false;
      if (Platform.isAndroid) {
        try {
          final bool? success =
              await const MethodChannel('inventory_app/system_utils')
                  .invokeMethod<bool>('saveToDownloads', {
            'fileName': fileName,
            'sourcePath': file.path,
            'bytes': bytes,
          });
          exportedToDownloads = success ?? false;
        } catch (e) {
          debugPrint('写入公共 Downloads 失败: $e');
        }
      }

      if (mounted) {
        String msg = exportedToDownloads
            ? '⚡ 纯数据备份成功！已保存到系统 Download/ 目录并生成本地还原点'
            : '⚡ 纯数据备份成功！已生成本地还原点: $fileName';
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
          SnackBar(content: Text('纯数据备份导出失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // 2. 全量归档备份包（ZIP 流式压缩 · 含照片 · 绝不爆内存）
  Future<void> _exportFullZipBackup() async {
    final dir = await _getBackupDir();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final fileName = 'inventory_full_$timestamp.zip';
    final targetFile = File(p.join(dir.path, fileName));

    String progressStatus = '正在导出数据库核心数据...';
    double progressValue = 0.0;
    void Function(void Function())? dialogSetState;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            dialogSetState = setDialogState;
            return PopScope(
              canPop: false,
              child: AlertDialog(
                shape: const RoundedRectangleBorder(),
                title: const Row(
                  children: [
                    Icon(Icons.folder_zip_outlined,
                        color: Color(0xFF2563EB), size: 22),
                    SizedBox(width: 8),
                    Text('全量归档压缩备份',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(progressStatus,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF475569))),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: progressValue > 0 ? progressValue : null,
                      backgroundColor: const Color(0xFFE2E8F0),
                      color: const Color(0xFF2563EB),
                      minHeight: 6,
                    ),
                    const SizedBox(height: 8),
                    const Text('采用流式安全打包，逐张封装单据照片，杜绝内存溢出。请保持应用在前台...',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    try {
      await widget.database.exportBackupZipFile(
        targetFile,
        onProgress: (current, total, status) {
          progressStatus = status;
          progressValue = total > 0 ? (current / total) : 0.0;
          if (dialogSetState != null) {
            dialogSetState!(() {});
          }
        },
      );

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }

      bool exportedToDownloads = false;
      if (Platform.isAndroid) {
        try {
          final bool? success =
              await const MethodChannel('inventory_app/system_utils')
                  .invokeMethod<bool>('saveToDownloads', {
            'fileName': fileName,
            'sourcePath': targetFile.path,
          });
          exportedToDownloads = success ?? false;
        } catch (e) {
          debugPrint('写入公共 Downloads 失败: $e');
        }
      }

      if (mounted) {
        String msg = exportedToDownloads
            ? '📦 全量 ZIP 备份成功！已保存至 Download/ 目录并生成本地还原点'
            : '📦 全量 ZIP 备份成功！已保存为本地还原点: $fileName';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      _loadBackupList();
    } catch (e) {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('全量压缩备份失败: $e')),
        );
      }
    }
  }

  // 3. 传统全量 JSON 备份（旧版兼容模式）
  Future<void> _exportLegacyBackup() async {
    setState(() => _isLoading = true);
    try {
      final bytes =
          await widget.database.exportBackupBytes(includeImages: true);
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
            'sourcePath': file.path,
            'bytes': bytes,
          });
          exportedToDownloads = success ?? false;
        } catch (e) {
          debugPrint('写入公共 Downloads 失败: $e');
        }
      }

      if (mounted) {
        String msg = exportedToDownloads
            ? '传统全量备份成功！已保存到系统 Download/ 目录并生成本地还原点'
            : '传统全量备份成功！已保存为本地还原点: $fileName';
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
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _importExternalBackup() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'zip'],
      );
      if (result == null || result.files.single.path == null) {
        return;
      }
      final file = File(result.files.single.path!);
      if (mounted) {
        _showRestoreConfirmationDialog(
          file: file,
          fileName: result.files.single.name,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择备份文件失败: $e')),
        );
      }
    }
  }

  void _restoreFromLocalFile(File file) {
    _showRestoreConfirmationDialog(
      file: file,
      fileName: p.basename(file.path),
    );
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

  void _showRestoreConfirmationDialog({
    File? file,
    Uint8List? bytes,
    required String fileName,
  }) {
    if (_online) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请切换到独立离线店铺还原备份，避免覆盖共享店铺或待同步数据。')));
      return;
    }
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
                      if (file != null) {
                        await widget.database.importBackupFromFile(file);
                      } else if (bytes != null) {
                        await widget.database.importBackupBytes(bytes);
                      }
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
      targetDescriptions.add(_online
          ? '本机已结算单据显示（保留云端及其他手机数据和店铺库存）'
          : '已结算的文本数据 (包含入库单、商品明细、库存和流水记录)');
    }
    if (_clearImagesSelected) {
      targetDescriptions
          .add(_online ? '本机已结算单据图片显示（原图片保留用于同步）' : '已结算单据关联的物理图片文件');
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
                  Text(
                    _online ? '仅清理本机显示，可在店铺同步中恢复' : '⚠️ 警告：此操作不可逆！',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.redAccent),
                  ),
                  const SizedBox(height: 12),
                  Text(_online ? '将在本机隐藏以下内容：' : '您将要永久清空以下勾选的数据：',
                      style: const TextStyle(fontSize: 13)),
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
                  child:
                      const Text('取消', style: TextStyle(color: Colors.black)),
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
      body: (_isLoading && !_isCompressing)
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

                // 2. 压缩历史大图卡片
                _imageCompressionCard(),
                const SizedBox(height: 24),

                // 3. 清理已结算数据卡片
                _clearSettledCard(),
                const SizedBox(height: 24),

                // 4. 备份历史标头
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

                // 5. 备份历史列表
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
                    final isZip = name.toLowerCase().endsWith('.zip');
                    final isLightData = name.contains('_data_');
                    final icon = isZip
                        ? Icons.folder_zip_outlined
                        : (isLightData
                            ? Icons.bolt_outlined
                            : Icons.insert_drive_file_outlined);
                    final iconColor = isZip
                        ? const Color(0xFF2563EB)
                        : (isLightData
                            ? const Color(0xFF0F766E)
                            : const Color(0xFF64748B));
                    final typeTag = isZip
                        ? '全量ZIP (含照片)'
                        : (isLightData ? '⚡ 极速纯数据' : '传统JSON');

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
                        onLongPress: _isLoading
                            ? null
                            : () async {
                                if (await file.exists()) {
                                  await Share.shareXFiles(
                                    [XFile(file.path)],
                                    text: '分享商品管理系统数据备份：$name',
                                  );
                                }
                              },
                        leading: Icon(
                          icon,
                          color: iconColor,
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
                            '$timeStr  ·  $sizeStr  ·  $typeTag',
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
                              onPressed: _isLoading
                                  ? null
                                  : () => _restoreFromLocalFile(file),
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
                              onPressed: _isLoading
                                  ? null
                                  : () => _deleteBackupFile(file),
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
              onPressed: _isLoading ? null : _showExportOptionsDialog,
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
              onPressed: _isLoading ? null : _importExternalBackup,
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
            subtitle: Text(
                _online ? '仅隐藏本机单据，其他手机、云端和库存保留' : '物理清除已勾选结算的入库明细及流水，释放数据库',
                style: const TextStyle(fontSize: 10)),
            value: _clearTextSelected,
            onChanged: _isLoading
                ? null
                : (val) {
                    setState(() {
                      _clearTextSelected = val ?? false;
                    });
                  },
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            activeColor: Colors.black,
          ),
          CheckboxListTile(
            title: Text(_online ? '已结算图片显示' : '已结算物理图片',
                style: const TextStyle(fontSize: 12)),
            subtitle: Text(
                _online ? '仅隐藏本机图片显示，保留图片供后续同步' : '物理删除已结算单据对应的拍照文件，释放手机存储',
                style: const TextStyle(fontSize: 10)),
            value: _clearImagesSelected,
            onChanged: _isLoading
                ? null
                : (val) {
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
                side: BorderSide(
                    color: _isLoading ? Colors.grey : Colors.red, width: 0.8),
                shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _isLoading ? null : _showClearConfirmationDialog,
              icon: const Icon(Icons.delete_forever, size: 16),
              label: const Text('一键清空所选数据',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageCompressionCard() {
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
            '💾 历史图片压缩 (释放空间)',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '将创建时间超过 7 天的历史入库单拍照进行尺寸缩小（宽/高最大 1000 像素），能腾出 90% 以上的图片占用存储，且不影响字迹阅读。已经压缩过的图片不会重复处理。',
            style:
                TextStyle(fontSize: 10, color: Color(0xFF64748B), height: 1.4),
          ),
          const SizedBox(height: 12),
          if (_isCompressing) ...[
            LinearProgressIndicator(
              value: _compressionProgress,
              backgroundColor: const Color(0xFFE2E8F0),
              color: Colors.black,
              minHeight: 4,
            ),
            const SizedBox(height: 8),
            Text(
              _compressionMessage,
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF1E293B),
                  fontFamily: 'monospace'),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1E293B),
                      side: const BorderSide(
                          color: Color(0xFFE2E8F0), width: 0.8),
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _isLoading
                        ? null
                        : () => _startCompression(force: false),
                    icon: const Icon(Icons.compress, size: 16),
                    label: const Text('开始增量压缩',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red, width: 0.8),
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _isLoading
                        ? null
                        : () => _startCompression(force: true),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('强制全部重压',
                        style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
