import 'dart:math';

import 'package:flutter/foundation.dart';

import 'access.dart';

/// One signed-in user on one system.
class NetSession {
  NetSession({
    required this.token,
    required this.companyId,
    required this.userId,
    required this.username,
    required this.display,
    required this.roleName,
    required this.access,
    required this.deviceId,
    required this.deviceName,
    required this.started,
    this.local = false,
  }) : lastSeen = started;

  final String token, companyId, userId, username, display, roleName, deviceId, deviceName;
  Access access;
  final DateTime started;
  DateTime lastSeen;

  /// The person sitting at the server itself, not a network client.
  final bool local;
}

/// Thrown when the user is already signed in on another system.
class AlreadyActive implements Exception {
  AlreadyActive(this.deviceName);
  final String deviceName;
  @override
  String toString() => 'این کاربر هم‌اکنون در سیستم «$deviceName» وارد شده است. اول از آنجا خارج شود (یا مدیر نشست را قطع کند).';
}

/// Who is signed in where. A user can be signed in on one system at a time per
/// company: a second sign-in from another system is refused while the first is
/// alive. A session stays alive as long as its system keeps sending heartbeats;
/// if the system crashes or loses the network the user is free again after
/// [ttl].
class SessionManager extends ChangeNotifier {
  SessionManager({this.ttl = const Duration(seconds: 40), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;
  final Map<String, NetSession> _byToken = {};
  final Map<String, String> _ended = {}; // token -> why, remembered for a while

  static String _newToken() => List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  bool _alive(NetSession s) => _clock().difference(s.lastSeen) <= ttl;

  void _sweep() {
    final dead = [for (final s in _byToken.values) if (!_alive(s)) s.token];
    for (final t in dead) {
      _byToken.remove(t);
      _ended[t] = 'expired';
    }
    if (_ended.length > 200) _ended.remove(_ended.keys.first);
    if (dead.isNotEmpty) notifyListeners();
  }

  /// Signs the user in. Throws [AlreadyActive] when another system has them.
  NetSession login({
    required String companyId,
    required String userId,
    required String username,
    required String display,
    required String roleName,
    required Access access,
    required String deviceId,
    required String deviceName,
    bool local = false,
  }) {
    _sweep();
    for (final s in _byToken.values.toList()) {
      if (s.companyId == companyId && s.userId == userId) {
        if (s.deviceId != deviceId) throw AlreadyActive(s.deviceName);
        _byToken.remove(s.token); // the same system signing in again (restart): replace
        _ended[s.token] = 'replaced';
      }
    }
    final s = NetSession(
      token: _newToken(), companyId: companyId, userId: userId, username: username, display: display, roleName: roleName,
      access: access, deviceId: deviceId, deviceName: deviceName, started: _clock(), local: local,
    );
    _byToken[s.token] = s;
    notifyListeners();
    return s;
  }

  /// The live session behind [token], marking it as seen; null when it ended.
  NetSession? touch(String token) {
    _sweep();
    final s = _byToken[token];
    if (s == null) return null;
    s.lastSeen = _clock();
    return s;
  }

  /// Why a token is no longer valid: kicked, expired, replaced or logout.
  String endedReason(String token) => _ended[token] ?? 'unknown';

  void logout(String token) {
    if (_byToken.remove(token) != null) {
      _ended[token] = 'logout';
      notifyListeners();
    }
  }

  List<NetSession> active([String? companyId]) {
    _sweep();
    return [for (final s in _byToken.values) if (companyId == null || s.companyId == companyId) s];
  }

  /// Ends every session of a user. Returns how many.
  int kick(String companyId, String userId) {
    final victims = [for (final s in _byToken.values) if (s.companyId == companyId && s.userId == userId) s];
    for (final s in victims) {
      _byToken.remove(s.token);
      _ended[s.token] = 'kicked';
    }
    if (victims.isNotEmpty) notifyListeners();
    return victims.length;
  }

  /// After users or roles changed: sessions of removed or deactivated users end,
  /// the others get their current permissions. [load] returns the access of a
  /// user, or null when they may not be signed in any more.
  Future<void> revalidate(String companyId, Future<Access?> Function(String userId) load) async {
    for (final s in active(companyId)) {
      final a = await load(s.userId);
      if (a == null) {
        _byToken.remove(s.token);
        _ended[s.token] = 'removed';
      } else {
        s.access = a;
      }
    }
    notifyListeners();
  }
}
