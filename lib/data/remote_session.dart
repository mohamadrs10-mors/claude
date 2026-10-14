import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'access.dart';
import 'app_db_remote.dart';
import 'device_prefs.dart';
import 'remote_db.dart';
import 'repo.dart';
import 'user_admin.dart';

/// A company the server offers.
class ServerCompany {
  ServerCompany(this.id, this.name, this.usersEnabled);
  final String id, name;
  final bool usersEnabled;
}

/// A signed-in network client: the connection, who we are and what we may do.
/// It keeps the session alive with a heartbeat, notices when the data changed
/// on the server (so screens refresh) and when the session was ended.
class RemoteSession extends ChangeNotifier {
  RemoteSession._(this.channel, this.companyId, this.companyName, this.userId, this.username, this.display, this.roleName, this.access);

  final RemoteChannel channel;
  final String companyId, companyName, userId, username, display, roleName;
  Access access;

  late final Repo repo;
  Timer? _timer;
  int _seq = -1;
  int _misses = 0;

  /// False while the server cannot be reached.
  bool connected = true;

  /// Set once the server ended the session (see [SessionEnded.reason]).
  String? endedReason;
  bool get ended => endedReason != null;

  UserAdmin get admin => RemoteUserAdmin(channel);

  /// The companies the server at [host]:[port] offers.
  static Future<List<ServerCompany>> companies(String host, int port, String code) async {
    final ch = RemoteChannel(host: host, port: port, code: code);
    try {
      final r = await ch.post('api/info', {}, auth: false, timeout: const Duration(seconds: 12));
      return [for (final c in r['companies'] as List) ServerCompany((c as Map)['id'] as String, c['name'] as String, c['usersEnabled'] as bool)];
    } finally {
      ch.close();
    }
  }

  /// Signs in. Throws [NetException] (code `bad_credentials`, `already_active`, ...).
  static Future<RemoteSession> login({
    required String host,
    required int port,
    required String code,
    required String companyId,
    required String username,
    required String password,
    required DevicePrefs prefs,
    String? deviceName,
  }) async {
    final ch = RemoteChannel(host: host, port: port, code: code);
    final r = await ch.post('api/login', {
      'companyId': companyId,
      'username': username,
      'password': password,
      'deviceId': prefs.deviceUid,
      'deviceName': deviceName ?? _hostName(),
    }, auth: false);
    ch.token = r['token'] as String;
    final u = r['user'] as Map<String, dynamic>;
    final s = RemoteSession._(ch, companyId, r['companyName'] as String, u['id'] as String, u['username'] as String, u['display'] as String, u['roleName'] as String,
        Access.fromJson(Map<String, dynamic>.from(r['access'] as Map)));
    s._seq = (r['seq'] as num).toInt();
    s.repo = await openRemoteRepo(ch, prefs, companyId);
    return s;
  }

  static String _hostName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'یک سیستم';
    }
  }

  /// Starts the heartbeat (every [every]).
  void start({Duration every = const Duration(seconds: 4)}) {
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => beat());
  }

  /// One heartbeat: stay signed in, learn about changes and new permissions.
  Future<void> beat() async {
    if (ended) return;
    try {
      final r = await channel.post('api/heartbeat', {}, timeout: const Duration(seconds: 10));
      _misses = 0;
      final wasOff = !connected;
      connected = true;
      final seq = (r['seq'] as num).toInt();
      final acc = Access.fromJson(Map<String, dynamic>.from(r['access'] as Map));
      final newAccess = acc.perms.length != access.perms.length || !acc.perms.containsAll(access.perms);
      if (newAccess) access = acc;
      if (seq != _seq) {
        _seq = seq;
        await repo.refresh();
      }
      if (wasOff || newAccess) notifyListeners();
    } on SessionEnded catch (e) {
      _finish(e.reason);
    } on NetException catch (e) {
      if (e.offline && ++_misses >= 2 && connected) {
        connected = false;
        notifyListeners();
      }
    }
  }

  void _finish(String reason) {
    endedReason = reason;
    _timer?.cancel();
    notifyListeners();
  }

  /// Signs out on the server (so this user can sign in elsewhere) and stops.
  Future<void> logout() async {
    _timer?.cancel();
    if (!ended) {
      try {
        await channel.post('api/logout', {}, timeout: const Duration(seconds: 6));
      } catch (_) {
        // The server frees the user by itself after a short while.
      }
      endedReason = 'logout';
    }
    channel.close();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// User administration done over the network.
class RemoteUserAdmin implements UserAdmin {
  RemoteUserAdmin(this.channel);
  final RemoteChannel channel;

  Future<Map<String, dynamic>> _call(String action, [Map<String, Object?> extra = const {}]) => channel.post('api/admin', {'action': action, ...extra});

  @override
  Future<bool> enabled() async => true;

  @override
  Future<List<UserInfo>> users() async => [for (final u in (await _call('users'))['users'] as List) UserInfo.fromJson(Map<String, dynamic>.from(u as Map))];

  @override
  Future<List<Role>> roles() async => [
        for (final r in (await _call('roles'))['roles'] as List)
          Role((r as Map)['id'] as String, r['name'] as String, {for (final p in r['perms'] as List) '$p'}, builtin: r['builtin'] as bool)
      ];

  @override
  Future<List<SessionInfo>> sessions() async => [for (final s in (await _call('sessions'))['sessions'] as List) SessionInfo.fromJson(Map<String, dynamic>.from(s as Map))];

  @override
  Future<String> saveUser({String? id, required String username, String fullName = '', required String roleId, String? password, bool active = true}) async =>
      (await _call('saveUser', {'id': id, 'username': username, 'fullName': fullName, 'roleId': roleId, 'password': password, 'active': active}))['id'] as String;

  @override
  Future<void> deleteUser(String id) async => _call('deleteUser', {'id': id});

  @override
  Future<String> saveRole({String? id, required String name, required Set<String> perms}) async =>
      (await _call('saveRole', {'id': id, 'name': name, 'perms': perms.toList()}))['id'] as String;

  @override
  Future<void> deleteRole(String id) async => _call('deleteRole', {'id': id});

  @override
  Future<void> kick(String userId) async => _call('kick', {'userId': userId});
}
