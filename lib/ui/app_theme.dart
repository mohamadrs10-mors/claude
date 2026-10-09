import 'package:flutter/material.dart';

import '../data/db.dart';

const themePresets = <(String, Color)>[
  ('فیروزه‌ای', Color(0xFF00897B)),
  ('آبی', Color(0xFF1E6FD9)),
  ('نیلی', Color(0xFF4F5BD5)),
  ('بنفش', Color(0xFF8E44AD)),
  ('صورتی', Color(0xFFD81B60)),
  ('قرمز', Color(0xFFD32F2F)),
  ('نارنجی', Color(0xFFEF6C00)),
  ('کهربایی', Color(0xFFF9A825)),
  ('سبز', Color(0xFF2E7D32)),
  ('قهوه‌ای', Color(0xFF6D4C41)),
  ('خاکستری', Color(0xFF546E7A)),
];

/// Appearance preferences. They are stored per device (not synced) so the
/// phone and the PC can look different.
class AppTheme extends ChangeNotifier {
  AppTheme(this._db);
  final AppDb _db;

  ThemeMode mode = ThemeMode.system;
  Color seed = themePresets.first.$2;
  double fontScale = 1.0;
  bool compact = false;

  Future<void> load() async {
    mode = switch (await _db.getMeta('theme_mode')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final c = int.tryParse(await _db.getMeta('theme_seed') ?? '');
    if (c != null) seed = Color(c);
    fontScale = double.tryParse(await _db.getMeta('font_scale') ?? '') ?? 1.0;
    compact = (await _db.getMeta('compact')) == '1';
    notifyListeners();
  }

  Future<void> setMode(ThemeMode m) async {
    mode = m;
    await _db.setMeta('theme_mode', m.name);
    notifyListeners();
  }

  Future<void> setSeed(Color c) async {
    seed = c;
    await _db.setMeta('theme_seed', '${c.toARGB32()}');
    notifyListeners();
  }

  Future<void> setFontScale(double v) async {
    fontScale = v;
    await _db.setMeta('font_scale', '$v');
    notifyListeners();
  }

  Future<void> setCompact(bool v) async {
    compact = v;
    await _db.setMeta('compact', v ? '1' : '0');
    notifyListeners();
  }

  ThemeData build(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b).copyWith(
      surface: dark ? const Color(0xFF14171A) : const Color(0xFFF7F8FA),
    );
    final radius = BorderRadius.circular(14);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Vazirmatn',
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
            fontFamily: 'Vazirmatn', fontSize: 20, fontWeight: FontWeight.w700, color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: dark ? const Color(0xFF1D2125) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.5 : 0.7)),
        ),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF1D2125) : Colors.white,
        border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: scheme.outlineVariant)),
        enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: scheme.outlineVariant)),
        focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: scheme.primary, width: 1.6)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xFF1D2125) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    );
  }
}
