import 'access.dart';
import 'sessions.dart';
import 'users.dart';

/// A user as the management screen shows them.
class UserInfo {
  UserInfo({required this.id, required this.username, required this.fullName, required this.roleId, required this.roleName, required this.active, this.online = false, this.device = ''});
  final String id, username, fullName, roleId, roleName, device;
  final bool active, online;
  String get display => fullName.isEmpty ? username : fullName;

  Map<String, Object?> toJson() => {'id': id, 'username': username, 'fullName': fullName, 'roleId': roleId, 'roleName': roleName, 'active': active, 'online': online, 'device': device};
  factory UserInfo.fromJson(Map<String, dynamic> j) => UserInfo(
      id: j['id'] as String, username: j['username'] as String, fullName: j['fullName'] as String, roleId: j['roleId'] as String,
      roleName: j['roleName'] as String, active: j['active'] as bool, online: j['online'] as bool, device: j['device'] as String);
}

/// One signed-in session as the management screen shows it.
class SessionInfo {
  SessionInfo({required this.userId, required this.username, required this.deviceName, required this.since, required this.local});
  final String userId, username, deviceName;
  final DateTime since;
  final bool local;

  Map<String, Object?> toJson() => {'userId': userId, 'username': username, 'deviceName': deviceName, 'since': since.toIso8601String(), 'local': local};
  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
      userId: j['userId'] as String, username: j['username'] as String, deviceName: j['deviceName'] as String,
      since: DateTime.parse(j['since'] as String), local: j['local'] as bool);
}

/// Managing the users, roles and sessions of one company. The same screens work
/// on the server itself ([LocalUserAdmin]) and from a network client (which
/// asks the server to do it).
abstract class UserAdmin {
  Future<bool> enabled();
  Future<List<UserInfo>> users();
  Future<List<Role>> roles();
  Future<List<SessionInfo>> sessions();
  Future<String> saveUser({String? id, required String username, String fullName = '', required String roleId, String? password, bool active = true});
  Future<void> deleteUser(String id);
  Future<String> saveRole({String? id, required String name, required Set<String> perms});
  Future<void> deleteRole(String id);

  /// Signs the user out everywhere.
  Future<void> kick(String userId);
}

class LocalUserAdmin implements UserAdmin {
  LocalUserAdmin(this.store, this.manager, this.companyId);
  final UserStore store;
  final SessionManager manager;
  final String companyId;

  Future<void> _revalidate() => manager.revalidate(companyId, (uid) async {
        final u = await store.user(uid);
        return u == null || !u.active ? null : store.accessOf(u);
      });

  @override
  Future<bool> enabled() => store.enabled();

  @override
  Future<List<UserInfo>> users() async {
    final roles = {for (final r in await store.roles()) r.id: r.name};
    final live = {for (final s in manager.active(companyId)) s.userId: s};
    return [
      for (final u in await store.users())
        UserInfo(
          id: u.id, username: u.username, fullName: u.fullName, roleId: u.roleId, roleName: roles[u.roleId] ?? '؟', active: u.active,
          online: live.containsKey(u.id), device: live[u.id]?.deviceName ?? '',
        )
    ];
  }

  @override
  Future<List<Role>> roles() => store.roles();

  @override
  Future<List<SessionInfo>> sessions() async => [
        for (final s in manager.active(companyId)) SessionInfo(userId: s.userId, username: s.username, deviceName: s.deviceName, since: s.started, local: s.local)
      ];

  @override
  Future<String> saveUser({String? id, required String username, String fullName = '', required String roleId, String? password, bool active = true}) async {
    final r = await store.saveUser(id: id, username: username, fullName: fullName, roleId: roleId, password: password, active: active);
    await _revalidate();
    return r;
  }

  @override
  Future<void> deleteUser(String id) async {
    await store.deleteUser(id);
    await _revalidate();
  }

  @override
  Future<String> saveRole({String? id, required String name, required Set<String> perms}) async {
    final r = await store.saveRole(id: id, name: name, perms: perms);
    await _revalidate();
    return r;
  }

  @override
  Future<void> deleteRole(String id) => store.deleteRole(id);

  @override
  Future<void> kick(String userId) async {
    manager.kick(companyId, userId);
  }
}
