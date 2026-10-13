import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'device_prefs.dart';
import 'recovery.dart';

/// Optional PIN per company, stored on this device only (salted SHA-256, never
/// the PIN itself). A company with a PIN is locked when the app starts, when
/// you switch to it, and after the app was in the background for a while.
///
/// A forgotten PIN can be recovered with the recovery key shown when the PIN was
/// set, or with the owner's master phrase (only in builds made with
/// `--dart-define=MASTER_KEY_HASH=<hash>`, see `tool/make_master_key.dart`).
class AppLock extends ChangeNotifier {
  AppLock(this.prefs, {this.timeout = const Duration(minutes: 2), DateTime Function()? clock, String? masterHash})
      : _clock = clock ?? DateTime.now,
        _masterHash = masterHash ?? const String.fromEnvironment('MASTER_KEY_HASH');

  final String _masterHash;

  /// Whether this build accepts an owner master phrase.
  bool get masterEnabled => _masterHash.isNotEmpty;

  final DevicePrefs prefs;
  final Duration timeout;
  final DateTime Function() _clock;

  final Set<String> _unlocked = {};
  DateTime? _pausedAt;
  int _failures = 0;
  DateTime? _lockedUntil;

  static const minLength = 4, maxLength = 8;

  String _key(String companyId) => 'lock_$companyId';
  String _recKey(String companyId) => 'lockrk_$companyId';

  /// A recovery key exists for this company's PIN (PINs made before keys were
  /// introduced have none; make one in Settings).
  bool hasRecoveryKey(String companyId) => (prefs.get(_recKey(companyId)) ?? '').isNotEmpty;

  bool hasPin(String companyId) => (prefs.get(_key(companyId)) ?? '').isNotEmpty;

  bool isUnlocked(String companyId) => !hasPin(companyId) || _unlocked.contains(companyId);

  static String _hash(String salt, String pin) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  static bool validPin(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  /// Sets the PIN and returns a new recovery key, which is shown once and only
  /// its hash is kept.
  Future<String> setPin(String companyId, String pin) async {
    if (!validPin(pin)) throw const FormatException('رمز باید ۴ تا ۸ رقم باشد.');
    final salt = base64Url.encode(List.generate(12, (_) => Random.secure().nextInt(256)));
    await prefs.set(_key(companyId), '$salt:${_hash(salt, pin)}');
    final key = await newRecoveryKey(companyId, notify: false);
    _unlocked.add(companyId); // the person who just set it is in
    notifyListeners();
    return key;
  }

  /// Replaces the recovery key (the old one stops working). The caller should
  /// have checked the PIN first.
  Future<String> newRecoveryKey(String companyId, {bool notify = true}) async {
    final key = Recovery.newKey();
    await prefs.set(_recKey(companyId), Recovery.store(key));
    if (notify) notifyListeners();
    return key;
  }

  Future<void> clearPin(String companyId) async {
    await prefs.set(_key(companyId), '');
    await prefs.set(_recKey(companyId), '');
    _unlocked.remove(companyId);
    notifyListeners();
  }

  bool _isMaster(String phrase) => masterEnabled && Recovery.masterHash(phrase) == _masterHash;

  /// Sets a new PIN when [key] is this company's recovery key, or the owner's
  /// master phrase. Returns the new recovery key, or null when the key is wrong.
  /// Wrong attempts count towards the same lockout as wrong PINs.
  Future<String?> recover(String companyId, String key, String newPin) async {
    if (!validPin(newPin)) throw const FormatException('رمز باید ۴ تا ۸ رقم باشد.');
    if (waitSeconds > 0) return null;
    final ok = _isMaster(key) || Recovery.matches(prefs.get(_recKey(companyId)) ?? '', key);
    if (!ok) {
      _countFailure();
      notifyListeners();
      return null;
    }
    _failures = 0;
    _lockedUntil = null;
    return setPin(companyId, newPin);
  }

  void _countFailure() {
    if (++_failures >= 5) {
      _failures = 0;
      _lockedUntil = _clock().add(const Duration(seconds: 30));
    }
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
    _countFailure();
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
