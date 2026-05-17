import '../domain/models.dart';

class PpStructurePostProcessor {
  static final RegExp _quantityPattern = RegExp(r'^\d+$');
  static final RegExp _codePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{2,}$');
  static final RegExp _orderNumberPattern =
      RegExp(r'订单(?:号|编号)?[:：]?\s*([A-Za-z0-9_-]{6,})');

  List<InboundDraftItem> processRows(List<List<String>> rows) {
    final items = <InboundDraftItem>[];

    for (final row in rows) {
      for (final cells in _normalizeRow(row)) {
        if (cells.isEmpty || _isHeaderOrFooter(cells.join(' '))) {
          continue;
        }

        final startsWithProductCode = _looksLikeProductCode(cells.first);
        final quantityIndex = _lastQuantityIndex(cells);
        if (quantityIndex < 0) {
          if (startsWithProductCode) {
            _addProduct(items, cells, 1);
            continue;
          }
          if (items.isNotEmpty) {
            final previous = items.removeLast();
            items.add(
              previous.copyWith(
                productName: '${previous.productName} ${cells.join(' ')}',
              ),
            );
          }
          continue;
        }

        final quantity = int.parse(cells[quantityIndex]);
        final leadingCells = cells.take(quantityIndex).toList();
        _addProduct(items, leadingCells, quantity);
      }
    }

    return items;
  }

  void _addProduct(
    List<InboundDraftItem> items,
    List<String> leadingCells,
    int quantity,
  ) {
    if (leadingCells.isEmpty) {
      return;
    }

    final code =
        _looksLikeProductCode(leadingCells.first) ? leadingCells.first : null;
    final nameCells =
        code == null ? leadingCells : leadingCells.skip(1).toList();
    final productName = _clean(nameCells.join(' '));
    if (productName.isEmpty || quantity <= 0) {
      return;
    }

    items.add(
      InboundDraftItem(
        productCode: code,
        productName: productName,
        quantity: quantity,
        sourceText: leadingCells.join(' | '),
      ),
    );
  }

  List<List<String>> _normalizeRow(List<String> row) {
    final cells = row.map(_clean).where((cell) => cell.isNotEmpty).toList();
    if (cells.isEmpty) {
      return const [];
    }
    final mergedRows = _splitMergedProductLine(cells.join(' '));
    if (mergedRows.length > 1) {
      return mergedRows;
    }
    if (cells.length != 1) {
      return [cells];
    }
    return [_splitLine(cells.single)];
  }

  List<InboundDraftItem> processPlainText(String text) {
    final rows = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(_splitLine)
        .toList();
    return processRows(rows);
  }

  String? extractSellerOrderNumber(String text) {
    final match = _orderNumberPattern.firstMatch(text);
    return match?.group(1);
  }

  List<String> _splitLine(String line) {
    final normalized = _clean(line);
    final tableCells = normalized.split(RegExp(r'\s{2,}|\t|\|'));
    if (tableCells.length > 1) {
      return tableCells;
    }
    final productCodeMatch = RegExp(r'^(\S+)\s+(.+)$').firstMatch(normalized);
    if (productCodeMatch != null &&
        _looksLikeProductCode(productCodeMatch.group(1)!)) {
      final code = productCodeMatch.group(1)!;
      final rest = productCodeMatch.group(2)!;
      final restWithQuantity = RegExp(r'^(.+)\s+(\d+)$').firstMatch(rest);
      if (restWithQuantity == null) {
        return [code, rest];
      }
      return [code, restWithQuantity.group(1)!, restWithQuantity.group(2)!];
    }
    final match = RegExp(r'^(\S+)\s+(.+)\s+(\d+)$').firstMatch(normalized);
    if (match == null) {
      return [normalized];
    }
    return [match.group(1)!, match.group(2)!, match.group(3)!];
  }

  List<List<String>> _splitMergedProductLine(String line) {
    final tokens = _clean(line).split(' ');
    final codeIndexes = <int>[];
    for (var index = 0; index < tokens.length; index += 1) {
      if (_looksLikeProductCode(tokens[index])) {
        codeIndexes.add(index);
      }
    }
    if (codeIndexes.length <= 1) {
      return const [];
    }

    final rows = <List<String>>[];
    for (var index = 0; index < codeIndexes.length; index += 1) {
      final start = codeIndexes[index];
      final end = index + 1 < codeIndexes.length
          ? codeIndexes[index + 1]
          : tokens.length;
      final cells = _splitLine(tokens.sublist(start, end).join(' '))
          .map(_clean)
          .where((cell) => cell.isNotEmpty)
          .toList();
      if (cells.isNotEmpty) {
        rows.add(cells);
      }
    }
    return rows;
  }

  bool _looksLikeProductCode(String token) {
    if (!_codePattern.hasMatch(token) || token.length < 5) {
      return false;
    }
    return RegExp(r'[A-Za-z]').hasMatch(token) && RegExp(r'\d').hasMatch(token);
  }

  int _lastQuantityIndex(List<String> cells) {
    for (var index = cells.length - 1; index >= 0; index -= 1) {
      if (_quantityPattern.hasMatch(cells[index])) {
        return index;
      }
    }
    return -1;
  }

  bool _isHeaderOrFooter(String value) {
    final normalized = value.replaceAll(' ', '');
    return normalized.contains('产品编号') ||
        normalized.contains('产品名称') ||
        (normalized.contains('数量') && normalized.length <= 8) ||
        normalized.contains('温馨提示') ||
        normalized.contains('订购清单') ||
        normalized.contains('官方旗舰店') ||
        normalized.contains('订单号') ||
        (normalized.contains('提示') &&
            (normalized.contains('电信') ||
                normalized.contains('网络') ||
                normalized.contains('远离') ||
                normalized.contains('诉骗') ||
                normalized.contains('诈骗'))) ||
        normalized.toLowerCase().contains('kerastase');
  }

  String _clean(String value) {
    return value
        .replaceAll(RegExp(r'[，,;；]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
