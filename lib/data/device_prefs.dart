import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Small key/value store for settings that belong to this device, not to a
/// company: theme, print set-up, the pairing code. Kept in a JSON file next to
/// the company databases.
class DevicePrefs {
  DevicePrefs._(this._file, this._map);

  final File? _file;
  final Map<String, String> _map;
  Future<void> _write = Future.value();

  static Future<DevicePrefs> open(Directory dir) async {
    final f = File(p.join(dir.path, 'prefs.json'));
    var map = <String, String>{};
    if (await f.exists()) {
      try {
        map = {for (final e in (jsonDecode(await f.readAsString()) as Map).entries) e.key as String: '${e.value}'};
      } catch (_) {
        // A damaged file just resets the preferences.
      }
    }
    return DevicePrefs._(f, map);
  }

  /// In-memory only (tests, or before a folder is known).
  factory DevicePrefs.memory() => DevicePrefs._(null, {});

  String? get(String key) => _map[key];

  /// A random id of this installation, made once; the server uses it to tell
  /// two systems apart (one user may be signed in on one system only).
  String get deviceUid {
    var v = _map['device_uid'];
    if (v == null || v.isEmpty) {
      v = base64Url.encode(List.generate(12, (_) => Random.secure().nextInt(256)));
      set('device_uid', v);
    }
    return v;
  }

  Future<void> set(String key, String value) {
    _map[key] = value;
    final f = _file;
    if (f == null) return Future.value();
    // Writes are queued so two quick changes never interleave.
    return _write = _write.then((_) => f.writeAsString(jsonEncode(_map), flush: true));
  }
}
