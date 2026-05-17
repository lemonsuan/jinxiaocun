import 'package:flutter/material.dart';

import 'src/ui/app_home.dart';

void main() {
  runApp(const InventoryApp());
}

class InventoryApp extends StatelessWidget {
  const InventoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '云推推库存管理',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2d6a4f)),
        useMaterial3: true,
      ),
      home: const AppHome(),
    );
  }
}
