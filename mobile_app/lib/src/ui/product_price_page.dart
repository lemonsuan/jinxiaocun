import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/local_inventory_database.dart';
import '../domain/models.dart';

class ProductPricePage extends StatefulWidget {
  final LocalInventoryDatabase database;
  final VoidCallback? onPricesUpdated;

  const ProductPricePage({
    super.key,
    required this.database,
    this.onPricesUpdated,
  });

  @override
  State<ProductPricePage> createState() => _ProductPricePageState();
}

class _ProductPricePageState extends State<ProductPricePage> {
  final TextEditingController _searchController = TextEditingController();
  List<ProductCatalogItem> _allProducts = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadProducts() async {
    setState(() => _isLoading = true);
    try {
      final products = await widget.database.loadProductCatalog();
      setState(() {
        _allProducts = products;
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  List<ProductCatalogItem> _filteredProducts() {
    if (_searchQuery.trim().isEmpty) {
      return _allProducts;
    }
    final query = _searchQuery.toLowerCase().trim();
    return _allProducts.where((p) {
      return p.productName.toLowerCase().contains(query) ||
          p.productCode.toLowerCase().contains(query);
    }).toList();
  }

  int _getTotalCount() => _allProducts.length;

  int _getSetPriceCount() {
    return _allProducts.where((p) => p.defaultPurchasePrice != null || p.defaultSalePrice != null).length;
  }

  int _getUnsetPriceCount() => _getTotalCount() - _getSetPriceCount();

  String _formatPrice(double? price) {
    if (price == null) return '未设置';
    return '¥${price.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final filtered = _filteredProducts();

    return Scaffold(
      appBar: AppBar(
        title: const Text('商品价格管理', style: TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onSurface,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 1. 磨砂统计看板
                _statisticsBoard(colorScheme),

                // 2. 检索输入框
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (val) {
                      setState(() {
                        _searchQuery = val;
                      });
                    },
                    decoration: InputDecoration(
                      hintText: '搜索商品名称或条码...',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colorScheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: colorScheme.primary, width: 2),
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.25),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  _searchController.clear();
                                  _searchQuery = '';
                                });
                              },
                            ),
                    ),
                  ),
                ),

                // 3. 商品价格列表
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Text(
                            _allProducts.isEmpty ? '暂无商品数据，请在扫码入库中添加' : '没有搜到符合条件的商品',
                            style: TextStyle(color: colorScheme.outline),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final product = filtered[index];
                            return _productPriceCard(product, colorScheme);
                          },
                        ),
                ),
              ],
            ),
    );
  }

  // 置顶轻奢磨砂统计看板
  Widget _statisticsBoard(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            colors: [
              colorScheme.primaryContainer.withOpacity(0.7),
              colorScheme.secondaryContainer.withOpacity(0.5),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withOpacity(0.06),
              blurRadius: 20,
              offset: const Offset(0, 8),
            )
          ],
          border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _statItem('品类总量', _getTotalCount().toString(), colorScheme.primary),
            _statItem('已配价格', _getSetPriceCount().toString(), Colors.teal),
            _statItem('未配价格', _getUnsetPriceCount().toString(), colorScheme.error),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String title, String val, Color color) {
    return Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.black54),
        ),
        const SizedBox(height: 6),
        Text(
          val,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  // 商品价格行卡片
  Widget _productPriceCard(ProductCatalogItem product, ColorScheme colorScheme) {
    final hasPurchase = product.defaultPurchasePrice != null;
    final hasSale = product.defaultSalePrice != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.4)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showEditPriceDialog(product),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      product.productName,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.edit_note_outlined, size: 20, color: colorScheme.outline),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '编码: ${product.productCode}',
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('采购指导价', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 4),
                        Text(
                          _formatPrice(product.defaultPurchasePrice),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: hasPurchase ? colorScheme.primary : colorScheme.error.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(width: 1, height: 28, color: colorScheme.outlineVariant.withOpacity(0.5)),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('销售指导价', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        const SizedBox(height: 4),
                        Text(
                          _formatPrice(product.defaultSalePrice),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: hasSale ? Colors.teal : colorScheme.error.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 弹窗修改价格（支持快捷 +/- 微调按钮）
  void _showEditPriceDialog(ProductCatalogItem product) {
    final colorScheme = Theme.of(context).colorScheme;
    final purchaseController = TextEditingController(
      text: product.defaultPurchasePrice?.toString() ?? '',
    );
    final saleController = TextEditingController(
      text: product.defaultSalePrice?.toString() ?? '',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void adjustPrice(TextEditingController controller, double delta) {
              final val = double.tryParse(controller.text) ?? 0.0;
              final res = val + delta;
              setModalState(() {
                controller.text = res < 0 ? '0' : res.toStringAsFixed(1);
              });
            }

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    color: colorScheme.surface.withOpacity(0.92),
                    padding: const EdgeInsets.all(24),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                '配置商品指导价',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            product.productName,
                            style: TextStyle(color: colorScheme.outline, fontSize: 14),
                          ),
                          const SizedBox(height: 20),

                          // 1. 采购指导价配置
                          _priceInputField(
                            label: '采购指导价 (元)',
                            controller: purchaseController,
                            colorScheme: colorScheme,
                            shortcuts: [
                              _shortcutBtn('+1', () => adjustPrice(purchaseController, 1.0)),
                              _shortcutBtn('+5', () => adjustPrice(purchaseController, 5.0)),
                              _shortcutBtn('+10', () => adjustPrice(purchaseController, 10.0)),
                              _shortcutBtn('-1', () => adjustPrice(purchaseController, -1.0)),
                              _shortcutBtn('-5', () => adjustPrice(purchaseController, -5.0)),
                            ],
                          ),
                          const SizedBox(height: 20),

                          // 2. 销售指导价配置
                          _priceInputField(
                            label: '销售指导价 (元)',
                            controller: saleController,
                            colorScheme: colorScheme,
                            shortcuts: [
                              _shortcutBtn('+5', () => adjustPrice(saleController, 5.0)),
                              _shortcutBtn('+10', () => adjustPrice(saleController, 10.0)),
                              _shortcutBtn('+50', () => adjustPrice(saleController, 50.0)),
                              _shortcutBtn('-5', () => adjustPrice(saleController, -5.0)),
                              _shortcutBtn('-10', () => adjustPrice(saleController, -10.0)),
                            ],
                          ),
                          const SizedBox(height: 28),

                          // 3. 确定按钮
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () async {
                                final pVal = double.tryParse(purchaseController.text.trim());
                                final sVal = double.tryParse(saleController.text.trim());
                                await widget.database.updateProductPrice(
                                  product.productCode,
                                  purchasePrice: pVal,
                                  salePrice: sVal,
                                );
                                Navigator.pop(context);
                                _loadProducts();
                                widget.onPricesUpdated?.call();
                              },
                              child: const Text('保存配置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _priceInputField({
    required String label,
    required TextEditingController controller,
    required ColorScheme colorScheme,
    required List<Widget> shortcuts,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
          ],
          decoration: InputDecoration(
            prefixText: '¥ ',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: shortcuts),
        ),
      ],
    );
  }

  Widget _shortcutBtn(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label),
        onPressed: onTap,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}