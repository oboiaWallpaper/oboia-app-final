// lib/providers/locale_provider.dart
//
// Holds the app's current language. Auto-detects the phone's language on
// first launch (Uzbek → 'uz', everything else → 'en'), lets the user override
// via a toggle, and persists the choice with SharedPreferences. Changing the
// language calls notifyListeners(), so the whole app rebuilds instantly.

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';

class LocaleProvider extends ChangeNotifier {
  static const _prefsKey = 'oboia_lang';

  String _lang = 'en';
  bool _userChose = false;

  String get lang => _lang;
  bool get isUzbek => _lang == 'uz';

  /// Call once at startup (e.g. in main before runApp, or via ..hydrate()).
  Future<void> hydrate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && AppStrings.isSupported(saved)) {
        _lang = saved;
        _userChose = true;
      } else {
        // Auto-detect from the device locale.
        final deviceLang = ui.PlatformDispatcher.instance.locale.languageCode;
        _lang = (deviceLang == 'uz') ? 'uz' : 'en';
      }
    } catch (_) {
      _lang = 'en';
    }
    notifyListeners();
  }

  Future<void> setLanguage(String lang) async {
    if (!AppStrings.isSupported(lang)) return;
    _lang = lang;
    _userChose = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, lang);
    } catch (_) {}
  }

  Future<void> toggle() async {
    await setLanguage(_lang == 'en' ? 'uz' : 'en');
  }

  String t(String key) => AppStrings.translate(_lang, key);
}
