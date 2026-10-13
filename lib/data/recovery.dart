import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Pure-Dart helpers for PIN recovery (no Flutter), so the command-line tools in
/// `tool/` can use exactly the same code as the app.
class Recovery {
  /// Letters and digits without the look-alikes 0/O and 1/I/L.
  static const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// A random key like `K7QX-2M9P-VD4R-8TWB` (about 80 bits).
  static String newKey({int groups = 4, int groupLength = 4}) {
    final r = Random.secure();
    return List.generate(groups, (_) => List.generate(groupLength, (_) => alphabet[r.nextInt(alphabet.length)]).join()).join('-');
  }

  /// Upper-case letters and digits only, so dashes, spaces and case do not matter.
  static String normalize(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static String newSalt() => base64Url.encode(List.generate(12, (_) => Random.secure().nextInt(256)));

  /// What is stored for a recovery key: `salt:hash`.
  static String store(String key) {
    final salt = newSalt();
    return '$salt:${_hash(salt, key)}';
  }

  static String _hash(String salt, String key) => sha256.convert(utf8.encode('$salt:${normalize(key)}')).toString();

  static bool matches(String stored, String key) {
    final i = stored.indexOf(':');
    if (i <= 0 || normalize(key).isEmpty) return false;
    return _hash(stored.substring(0, i), key) == stored.substring(i + 1);
  }

  /// Hash of an owner master phrase. Only this hash is put into the app (at build
  /// time); the phrase itself stays with the owner.
  static String masterHash(String phrase) => sha256.convert(utf8.encode('simple_accounting_master:${normalize(phrase)}')).toString();

  /// Removes the PIN (and recovery key) of one company, or of all companies,
  /// from the contents of `prefs.json`. Returns how many entries were removed.
  static int stripLocks(Map<String, dynamic> prefs, {String? companyId}) {
    final keys = [
      for (final k in prefs.keys)
        if ((k.startsWith('lock_') || k.startsWith('lockrk_')) && (companyId == null || k == 'lock_$companyId' || k == 'lockrk_$companyId')) k
    ];
    keys.forEach(prefs.remove);
    return keys.length;
  }
}
