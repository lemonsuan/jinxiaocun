import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  static const List<BarcodeFormat> _linearBarcodeFormats = [
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.code93,
    BarcodeFormat.codabar,
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.itf2of5,
    BarcodeFormat.itf2of5WithChecksum,
    BarcodeFormat.itf14,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
  ];

  final MobileScannerController _controller = MobileScannerController(
    formats: _linearBarcodeFormats,
  );
  bool _hasResult = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描快递码')),
      body: MobileScanner(
        controller: _controller,
        onDetect: (capture) {
          if (_hasResult) {
            return;
          }
          final barcodes = capture.barcodes;
          if (barcodes.isEmpty) {
            return;
          }
          String? value;
          for (final barcode in barcodes) {
            if (!_linearBarcodeFormats.contains(barcode.format)) {
              continue;
            }
            value = barcode.rawValue?.trim();
            if (value != null && value.isNotEmpty) {
              break;
            }
          }
          if (value == null || value.isEmpty) {
            return;
          }
          _hasResult = true;
          Navigator.of(context).pop(value);
        },
      ),
    );
  }
}
