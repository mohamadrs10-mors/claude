import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'access.dart';
import 'db.dart';

class User {
  User(this.id, this.username, this.fullName, this.roleId, this.active, this.createdAt);
  final String id, username, fullName, roleId, createdAt;
  final bool active;
  String get display => fullName.isEmpty ? username : fullName;
}

/// Users and roles of one company. They live in the company's database but
/// outside the synced tables, and only this class (on the machine that owns
/// the database) reads or writes them: a network client never gets at the
/// password hashes.
class UserStore {
  UserStore(this.store);
  final AppDb store;
  Database get _db => store.raw;

  static const minPassword = 4;

  static String _hash(String salt, String password) {
    List<int> d = utf8.encode('$salt:$password');
    for (var i = 0; i < 12000; i++) {
      d = sha256.convert(d).bytes;
    }
    return base64Url.encode(d);
  }

  static String _newSalt() => base64Url.encode(List.generate(16, (_) => Random.secure().nextInt(256)));

  /// Whether users are switched on for this company (at least one exists).
  Future<bool> enabled() async => ((await _db.rawQuery('SELECT COUNT(*) AS n FROM users')).first['n'] as int) > 0;

  /// Switches users on: creates the ready-made roles and the first user, who
  /// is the administrator.
  Future<String> enable({required String username, required String password, String fullName = ''}) async {
    if (await enabled()) throw StateError('کاربران قبلاً فعال شده‌اند.');
    for (final r in presetRoles()) {
      await _db.insert('roles', {'id': r.id, 'name': r.name, 'perms': jsonEncode(r.perms.toList()..sort()), 'builtin': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return saveUser(username: username, password: password, fullName: fullName, roleId: 'admin');
  }

  /// Switches users off again (everyone can then use the company freely).
  Future<void> disable() async {
    await _db.delete('users');
  }

  // ---- roles --------------------------------------------------------------

  Role _role(Map<String, Object?> r) {
    final id = r['id'] as String;
    // The administrator role always has every permission, even new ones.
    final perms = id == 'admin' ? allPermissions.toSet() : {for (final p in (jsonDecode(r['perms'] as String) as List)) '$p'};
    return Role(id, r['name'] as String, perms, builtin: (r['builtin'] as int) == 1);
  }

  Future<List<Role>> roles() async => [for (final r in await _db.query('roles', orderBy: 'builtin DESC, name')) _role(r)];

  Future<Role?> role(String id) async {
    final rows = await _db.query('roles', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty ? null : _role(rows.first);
  }

  Future<String> saveRole({String? id, required String name, required Set<String> perms}) async {
    final n = name.trim();
    if (n.isEmpty) throw StateError('نام نقش را بنویسید.');
    final rid = id ?? 'role_${AppDb.newId()}';
    if (rid == 'admin') return rid; // always everything
    final clean = perms.where(allPermissions.contains).toList()..sort();
    final old = await role(rid);
    await _assertAdmin(rolesOverride: {rid: clean.contains(permUsers)});
    await _db.insert('roles', {'id': rid, 'name': n, 'perms': jsonEncode(clean), 'builtin': old?.builtin == true ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);
    return rid;
  }

  Future<void> deleteRole(String id) async {
    if (id == 'admin') throw StateError('نقش مدیر کل حذف نمی‌شود.');
    final used = (await _db.rawQuery('SELECT COUNT(*) AS n FROM users WHERE role_id=?', [id])).first['n'] as int;
    if (used > 0) throw StateError('کاربرانی با این نقش هست؛ اول نقش آن‌ها را عوض کنید.');
    await _db.delete('roles', where: 'id=?', whereArgs: [id]);
  }

  // ---- users --------------------------------------------------------------

  User _user(Map<String, Object?> r) => User(r['id'] as String, r['username'] as String, r['full_name'] as String, r['role_id'] as String, (r['active'] as int) == 1, r['created_at'] as String);

  Future<List<User>> users() async => [for (final r in await _db.query('users', orderBy: 'username')) _user(r)];

  Future<User?> user(String id) async {
    final rows = await _db.query('users', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty ? null : _user(rows.first);
  }

  static bool validUsername(String u) => RegExp(r'^[A-Za-z0-9_.\-]{2,32}$').hasMatch(u);

  /// Creates or edits a user. [password] is required for a new one; for an
  /// existing user it changes the password when given.
  Future<String> saveUser({String? id, required String username, String fullName = '', required String roleId, String? password, bool active = true}) async {
    final u = username.trim().toLowerCase();
    if (!validUsername(u)) throw StateError('نام کاربری باید ۲ تا ۳۲ حرف انگلیسی، عدد یا _ . - باشد.');
    if (await role(roleId) == null) throw StateError('نقش انتخاب‌شده وجود ندارد.');
    final clash = await _db.query('users', where: 'username=? AND id<>?', whereArgs: [u, id ?? '']);
    if (clash.isNotEmpty) throw StateError('این نام کاربری قبلاً استفاده شده است.');
    final uid = id ?? AppDb.newId();
    final old = id == null ? null : await user(id);
    await _assertAdmin(userOverride: (uid, roleId, active));
    if (old == null && (password == null || password.length < minPassword)) throw StateError('رمز عبور باید حداقل $minPassword نویسه باشد.');
    if (password != null && password.isNotEmpty && password.length < minPassword) throw StateError('رمز عبور باید حداقل $minPassword نویسه باشد.');
    final row = <String, Object?>{
      'id': uid, 'username': u, 'full_name': fullName.trim(), 'role_id': roleId, 'active': active ? 1 : 0,
      'created_at': old?.createdAt ?? DateTime.now().toIso8601String(),
    };
    if (password != null && password.isNotEmpty) {
      final salt = _newSalt();
      row['salt'] = salt;
      row['hash'] = _hash(salt, password);
    } else {
      final prev = (await _db.query('users', columns: ['salt', 'hash'], where: 'id=?', whereArgs: [uid])).first;
      row['salt'] = prev['salt'];
      row['hash'] = prev['hash'];
    }
    await _db.insert('users', row, conflictAlgorithm: ConflictAlgorithm.replace);
    return uid;
  }

  Future<void> deleteUser(String id) async {
    await _assertAdmin(removeUser: id);
    await _db.delete('users', where: 'id=?', whereArgs: [id]);
  }

  /// At least one active user must be able to manage users, or nobody could fix
  /// anything. Checked against what the data will look like after the change.
  Future<void> _assertAdmin({(String, String, bool)? userOverride, String? removeUser, Map<String, bool>? rolesOverride}) async {
    if (!await enabled()) return;
    final canManage = {for (final r in await roles()) r.id: r.perms.contains(permUsers), ...?rolesOverride};
    var list = [for (final u in await users()) (u.id, u.roleId, u.active)].where((u) => u.$1 != removeUser && u.$1 != userOverride?.$1).toList();
    if (userOverride != null) list.add(userOverride);
    if (!list.any((u) => u.$3 && (canManage[u.$2] ?? false))) throw StateError('حداقل یک مدیر فعال باید باقی بماند.');
  }

  /// The user with this name and password, if the account is active.
  Future<User?> verify(String username, String password) async {
    final rows = await _db.query('users', where: 'username=?', whereArgs: [username.trim().toLowerCase()]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    if ((r['active'] as int) != 1) return null;
    return _hash(r['salt'] as String, password) == r['hash'] ? _user(r) : null;
  }

  Future<Access> accessOf(User u, {String device = ''}) async =>
      Access((await role(u.roleId))?.perms ?? {}, who: u.fullName.isEmpty ? u.username : u.fullName, userId: u.id, device: device);
}
