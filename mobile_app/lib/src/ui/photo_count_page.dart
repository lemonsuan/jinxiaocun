import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../data/local_inventory_database.dart';
import '../domain/models.dart';
import 'scanner_page.dart';

class PhotoCountPage extends StatefulWidget {
  final LocalInventoryDatabase database;
  final VoidCallback? onInventoryUpdated;

  const PhotoCountPage({
    super.key,
    required this.database,
    this.onInventoryUpdated,
  });

  @override
  State<PhotoCountPage> createState() => _PhotoCountPageState();
}

class _PhotoCountPageState extends State<PhotoCountPage> {
  final ImagePicker _imagePicker = ImagePicker();
  String? _imagePath;
  final List<InboundDraftItem> _items = [];
  bool _isSubmitting = false;

  Future<void> _captureImage() async {
    try {
      final file = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );
      if (file != null) {
        setState(() {
          _imagePath = file.path;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickImage() async {
    try {
      final file = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (file != null) {
        setState(() {
          _imagePath = file.path;
        });
      }
    } catch (_) {}
  }

  void _addEmptyItem() {
    setState(() {
      _items.add(const InboundDraftItem(
        productName: '',
        quantity: 1,
        sourceText: '盘点手动录入',
      ));
    });
  }

  Future<void> _scanItem(int index) async {
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (context) => const ScannerPage()),
    );
    if (barcode == null || barcode.isEmpty) return;

    String? matchedName;
    try {
      final catalog = await widget.database.loadProductCatalog();
      final match = catalog.firstWhere((p) => p.productCode == barcode);
      matchedName = match.productName;
    } catch (_) {}

    setState(() {
      final old = _items[index];
      _items[index] = old.copyWith(
        productCode: barcode,
        productName: matchedName ?? old.productName,
        sourceText: '盘点扫码录入',
      );
    });
  }

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index);
    });
  }

  Future<void> _submitInventory() async {
    if (_imagePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先拍摄或选择一张盘点照片以作凭证')),
      );
      return;
    }
    if (_items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少添加一件盘点商品')),
      );
      return;
    }

    for (final item in _items) {
      if (item.productName.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('商品名称不能为空')),
        );
        return;
      }
      if (item.quantity <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('商品盘点数量必须大于0')),
        );
        return;
      }
    }

    setState(() => _isSubmitting = true);
    try {
      final trackingNumber = 'PD-${DateTime.now().millisecondsSinceEpoch}';
      await widget.database.confirmInbound(
        trackingNumber: trackingNumber,
        items: _items,
        imagePath: _imagePath,
        sellerOrderNumber: '盘点单',
        rebateOrderNumber: '盘点单',
        isSettled: true,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('盘点库存更新成功！')),
        );
        widget.onInventoryUpdated?.call();
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('提交失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('拍照盘点与计数', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. 拍照/相册上传区域 (带虚线和磨砂阴影)
                  _photoUploadArea(colorScheme),
                  const SizedBox(height: 24),

                  // 2. 盘点草稿工具栏
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '盘点实物列表 (${_items.length})',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Row(
                        children: [
                          TextButton.icon(
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('手动添加'),
                            onPressed: _addEmptyItem,
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            icon: const Icon(Icons.qr_code_scanner, size: 16),
                            label: const Text('扫码添加', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              _addEmptyItem();
                              _scanItem(_items.length - 1);
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 3. 盘点草稿列表
                  if (_items.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Text(
                          '点击右上角“扫码”或“手动”录入盘点货品',
                          style: TextStyle(color: colorScheme.outline, fontSize: 13),
                        ),
                      ),
                    )
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        return _draftItemCard(index, _items[index], colorScheme);
                      },
                    ),
                ],
              ),
            ),
          ),

          // 4. 底栏确认
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, -4),
                )
              ],
            ),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _isSubmitting ? null : _submitInventory,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                      )
                    : const Text(
                        '确认盘点入库',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 拍照控制卡片
  Widget _photoUploadArea(ColorScheme colorScheme) {
    if (_imagePath != null) {
      return Stack(
        children: [
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              image: DecorationImage(
                image: FileImage(File(_imagePath!)),
                fit: BoxFit.cover,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  color: Colors.black.withOpacity(0.4),
                  child: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white),
                    onPressed: () {
                      setState(() {
                        _imagePath = null;
                      });
                    },
                  ),
                ),
              ),
            ),
          ),
          // 悬浮已拍计数泡泡
          Positioned(
            bottom: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.teal.shade400,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text(
                    '盘点照片已拍照',
                    style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return InkWell(
      onTap: () {
        showModalBottomSheet(
          context: context,
          builder: (context) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera),
                    title: const Text('拍照'),
                    onTap: () {
                      Navigator.pop(context);
                      _captureImage();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.photo_library),
                    title: const Text('从相册选择'),
                    onTap: () {
                      Navigator.pop(context);
                      _pickImage();
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        height: 180,
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: colorScheme.primary.withOpacity(0.4),
            width: 2.0,
            style: BorderStyle.solid,
          ),
          color: colorScheme.primaryContainer.withOpacity(0.1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt_outlined, size: 40, color: colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              '拍照或选择盘点货品照片',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: colorScheme.primary),
            ),
            const SizedBox(height: 4),
            Text(
              '需要拍照作为库存审计凭证',
              style: TextStyle(fontSize: 11, color: colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  // 盘点行草稿
  Widget _draftItemCard(int index, InboundDraftItem item, ColorScheme colorScheme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('pd-name-$index'),
                    initialValue: item.productName,
                    onChanged: (val) {
                      _items[index] = item.copyWith(productName: val);
                    },
                    decoration: const InputDecoration(
                      hintText: '输入货品名称 (必填)',
                      labelText: '货品名称',
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                  onPressed: () => _removeItem(index),
                ),
              ],
            ),
            const Divider(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    key: ValueKey('pd-code-$index-${item.productCode}'),
                    initialValue: item.productCode ?? '',
                    onChanged: (val) {
                      _items[index] = item.copyWith(productCode: val);
                    },
                    decoration: const InputDecoration(
                      hintText: '手动录入或点击右侧扫码',
                      labelText: '条码编码',
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner, size: 20),
                  onPressed: () => _scanItem(index),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 80,
                  alignment: Alignment.centerRight,
                  child: TextFormField(
                    key: ValueKey('pd-qty-$index-${item.quantity}'),
                    initialValue: item.quantity.toString(),
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.end,
                    onChanged: (val) {
                      final parsed = int.tryParse(val.trim()) ?? 1;
                      _items[index] = item.copyWith(quantity: parsed);
                    },
                    decoration: const InputDecoration(
                      hintText: '数量',
                      labelText: '盘点数量',
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                    ),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
