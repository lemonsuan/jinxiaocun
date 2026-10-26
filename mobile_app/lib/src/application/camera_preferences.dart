import 'dart:io';
import 'package:path_provider/path_provider.dart';

class CameraPreferences {
  static Future<File> _file() async => File(
      '${(await getApplicationDocumentsDirectory()).path}/camera_flash_pref.txt');
  static Future<bool> loadTorch() async {
    try {
      return (await (await _file()).readAsString()).trim() == 'torch';
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveTorch(bool enabled) async {
    await (await _file()).writeAsString(enabled ? 'torch' : 'off', flush: true);
  }
}
