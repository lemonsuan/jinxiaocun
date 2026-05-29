import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_mobile_app/src/data/local_inventory_database.dart';
import 'package:inventory_mobile_app/src/ocr/gemma_extractor.dart';

class MockDatabase extends LocalInventoryDatabase {
  @override
  Future<String> loadGeminiApiKey() async => 'test-key';
  @override
  Future<String> loadGeminiApiUrl() async => 'https://example.com';
  @override
  Future<String> loadGeminiModel() async => 'gemini-1.5-flash';
}

void main() {
  test('GemmaExtractor exists and can be initialized', () {
    final database = MockDatabase();
    final extractor = GemmaExtractor(database);
    expect(extractor, isNotNull);
  });
}