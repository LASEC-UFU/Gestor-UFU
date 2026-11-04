import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gestor_ufu/core/theme/app_theme.dart';

class ThemeController extends ChangeNotifier {
  static const storageKey = 'gestor_ufu_theme_light';

  ThemeController({required bool isLight}) : _isLight = isLight {
    AppTheme.isLight = isLight;
  }

  bool _isLight;

  bool get isLight => _isLight;
  ThemeMode get themeMode => _isLight ? ThemeMode.light : ThemeMode.dark;

  Future<void> setLight(bool value) async {
    if (_isLight == value) return;
    _isLight = value;
    AppTheme.isLight = value;
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(storageKey, value);
  }
}
