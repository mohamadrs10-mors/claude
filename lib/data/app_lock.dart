import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'device_prefs.dart';

/// Optional PIN per company, stored on this device only (salted SHA-256, never
/// the PIN itself). A company with a PIN is locked when the app starts, when
/// you switch to it, and after the app was in the background for a while.
class AppLock extends ChangeNotifier {
  AppLock(this.prefs, {this.timeout = const Duration(minutes: 2), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DevicePrefs prefs;
  final Duration timeout;
  final DateTime Function() _clock;

  final Set<String> _unlocked = {};
  DateTime? _pausedAt;
  int _failures = 0;
  DateTime? _lockedUntil;

  static const minLength = 4, maxLength = 8;

  String _key(String companyId) => 'lock_$companyId';

  bool hasPin(String companyId) => (prefs.get(_key(companyId)) ?? '').isNotEmpty;

  bool isUnlocked(String companyId) => !hasPin(companyId) || _unlocked.contains(companyId);

  static String _hash(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  static bool validPin(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  Future<void> setPin(String companyId, String pin) async {
    if (!validPin(pin)) throw const FormatException('رمز باید ۴ تا ۸ رقم باشد.');
    final salt = base64Url.encode(List.generate(12, (_) => Random.secure().nextInt(256)));
    await prefs.set(_key(companyId), '$salt:${_hash(salt, pin)}');
    _unlocked.add(companyId); // the person who just set it is in
    notifyListeners();
  }

  Future<void> clearPin(String companyId) async {
    await prefs.set(_key(companyId), '');
    _unlocked.remove(companyId);
    notifyListeners();
  }

  /// Seconds to wait after too many wrong attempts (0 when free to try).
  int get waitSeconds {
    final u = _lockedUntil;
    if (u == null) return 0;
    final s = u.difference(_clock()).inSeconds + 1;
    return s > 0 ? s : 0;
  }

  /// Checks a PIN without unlocking anything (to confirm before changing it).
  bool check(String companyId, String pin) {
    final stored = prefs.get(_key(companyId)) ?? '';
    final i = stored.indexOf(':');
    if (i <= 0) return stored.isEmpty;
    return _hash(stored.substring(0, i), pin) == stored.substring(i + 1);
  }

  /// Unlocks [companyId] if [pin] is right. After five wrong attempts the next
  /// one is refused for 30 seconds.
  bool unlock(String companyId, String pin) {
    if (waitSeconds > 0) return false;
    if (check(companyId, pin)) {
      _failures = 0;
      _lockedUntil = null;
      _unlocked.add(companyId);
      notifyListeners();
      return true;
    }
    if (++_failures >= 5) {
      _failures = 0;
      _lockedUntil = _clock().add(const Duration(seconds: 30));
    }
    notifyListeners();
    return false;
  }

  void lockAll() {
    _unlocked.clear();
    notifyListeners();
  }

  void lock(String companyId) {
    _unlocked.remove(companyId);
    notifyListeners();
  }

  void appPaused() => _pausedAt = _clock();

  void appResumed() {
    final p = _pausedAt;
    _pausedAt = null;
    if (p != null && _clock().difference(p) >= timeout) lockAll();
  }
}
