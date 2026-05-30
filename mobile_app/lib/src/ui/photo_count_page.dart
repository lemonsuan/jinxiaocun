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
      backgroundColor: const Color(0xFFFCFCFC), // 极简纯净微偏灰色背景
      appBar: AppBar(
        title: const Text(
          '拍照盘点',
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
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. 拍照/相册上传区域 (直角极简框线)
                  _photoUploadArea(colorScheme),
                  const SizedBox(height: 36),

                  // 2. 盘点草稿工具栏
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '实物列表 (${_items.length})',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.0,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      Row(
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF64748B),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: _addEmptyItem,
                            child: const Row(
                              children: [
                                Icon(Icons.add, size: 14),
                                SizedBox(width: 4),
                                Text('手动添加', style: TextStyle(fontSize: 11)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1E293B),
                              side: const BorderSide(color: Color(0xFFE2E8F0), width: 0.8),
                              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 11,
                                letterSpacing: 0.5,
                              ),
                            ),
                            onPressed: () {
                              _addEmptyItem();
                              _scanItem(_items.length - 1);
                            },
                            child: const Row(
                              children: [
                                Icon(Icons.qr_code_scanner, size: 12),
                                SizedBox(width: 6),
                                Text('扫码'),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
                  const SizedBox(height: 12),

                  // 3. 盘点草稿列表
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          '点击右上角录入实物信息',
                          style: TextStyle(color: const Color(0xFF94A3B8), fontSize: 12, letterSpacing: 0.5),
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(
                  color: Color(0xFFF1F5F9),
                  width: 0.8,
                ),
              ),
            ),
            child: SafeArea(
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                    elevation: 0,
                  ),
                  onPressed: _isSubmitting ? null : _submitInventory,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.0, color: Colors.white),
                        )
                      : const Text(
                          '提交盘点入库',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2.0,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 极简主义拍照控制区
  Widget _photoUploadArea(ColorScheme colorScheme) {
    if (_imagePath != null) {
      return Stack(
        children: [
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE2E8F0), width: 0.8),
              image: DecorationImage(
                image: FileImage(File(_imagePath!)),
                fit: BoxFit.cover,
              ),
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
                    icon: const Icon(Icons.delete_outline, color: Colors.white, size: 18),
                    onPressed: () {
                      setState(() {
                        _imagePath = null;
                      });
                    },
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(),
                  ),
                ),
              ),
            ),
          ),
          // 悬浮已拍计数泡泡 (极简灰底框线风格)
          Positioned(
            bottom: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              color: const Color(0xFF1E293B),
              child: const Row(
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.white, size: 12),
                  SizedBox(width: 6),
                  Text(
                    '凭证照片已就绪',
                    style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 0.5),
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
          backgroundColor: Colors.white,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          builder: (context) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined, size: 20, color: Color(0xFF1E293B)),
                    title: const Text('使用相机拍摄', style: TextStyle(fontSize: 13, color: Color(0xFF1E293B))),
                    onTap: () {
                      Navigator.pop(context);
                      _captureImage();
                    },
                  ),
                  const Divider(height: 1, color: Color(0xFFF1F5F9)),
                  ListTile(
                    leading: const Icon(Icons.photo_library_outlined, size: 20, color: Color(0xFF1E293B)),
                    title: const Text('从系统相册选取', style: TextStyle(fontSize: 13, color: Color(0xFF1E293B))),
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
      child: Container(
        height: 180,
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xFFCBD5E1),
            width: 0.8,
          ),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.camera_alt_outlined, size: 28, color: Color(0xFF64748B)),
            SizedBox(height: 12),
            Text(
              '上传盘点凭证照片',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B), letterSpacing: 0.5),
            ),
            SizedBox(height: 6),
            Text(
              '需要拍摄实物作为库存审计依据',
              style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
            ),
          ],
        ),
      ),
    );
  }

  // 极简主义盘点行草稿
  Widget _draftItemCard(int index, InboundDraftItem item, ColorScheme colorScheme) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Color(0xFFF1F5F9),
            width: 0.8,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
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
                    hintStyle: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
                    labelText: '货品名称',
                    labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                  ),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF1E293B)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Color(0xFF94A3B8), size: 18),
                onPressed: () => _removeItem(index),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
                    hintText: '输入条码或扫码录入',
                    hintStyle: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                    labelText: '条码编码',
                    labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                  ),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Color(0xFF64748B)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner_outlined, size: 16, color: Color(0xFF64748B)),
                onPressed: () => _scanItem(index),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 16),
              Container(
                width: 70,
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
                    hintStyle: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                    labelText: '数量',
                    labelStyle: TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                  ),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
