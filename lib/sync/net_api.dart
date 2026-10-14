import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/access.dart';
import '../data/company_manager.dart';
import '../data/db_ops.dart';
import '../data/sessions.dart';
import '../data/user_admin.dart';
import '../data/users.dart';

class _Rollback implements Exception {}

/// A transaction a client has open on the server. The real database
/// transaction waits for the client to say commit or rollback; a client that
/// goes quiet is rolled back after [_Tx.idle].
class _Tx {
  _Tx(this.owner);
  static const idle = Duration(seconds: 45);
  final String owner; // session token
  late final Transaction tx;
  final ready = Completer<void>();
  final finish = Completer<bool>();
  late final Future<void> done;
  Timer? timer;
}

/// The network side of the server: clients sign in with a user name and
/// password and then run database calls here, so every system works on the
/// same live data. Writes are checked against the signed-in user's role.
class NetApi {
  NetApi({required this.companies, required this.sessions, required this.pairCode, required this.enabled});

  final CompanyManager companies;
  final SessionManager sessions;
  final Future<String> Function() pairCode;

  /// Whether this device currently acts as a server for clients.
  final bool Function() enabled;

  final Map<String, _Tx> _txs = {};
  final Map<String, (int, DateTime)> _failures = {};

  Response _json(Object o, [int status = 200]) => Response(status, body: jsonEncode(o), headers: {'content-type': 'application/json; charset=utf-8'});
  Response _err(String message, int status, [String code = 'error', Map<String, Object?> extra = const {}]) => _json({'error': message, 'code': code, ...extra}, status);

  /// Handles `api/...` requests; null for other paths.
  Future<Response?> handle(Request req) async {
    final path = req.url.path;
    if (!path.startsWith('api/')) return null;
    if (!enabled()) return _err('این دستگاه به‌عنوان سرور فعال نیست.', 403, 'server_off');
    try {
      final body = req.method == 'POST' ? (jsonDecode(await req.readAsString()) as Map<String, dynamic>) : <String, dynamic>{};
      switch (path) {
        case 'api/info':
          return await _info(req);
        case 'api/login':
          return await _login(req, body);
      }
      final s = sessions.touch((body['token'] ?? '') as String);
      if (s == null) return _err('نشست شما پایان یافته است.', 401, 'session_ended', {'reason': sessions.endedReason((body['token'] ?? '') as String)});
      switch (path) {
        case 'api/logout':
          sessions.logout(s.token);
          await _dropTxs(s.token);
          return _json({'ok': true});
        case 'api/heartbeat':
          final repo = await companies.repoFor(s.companyId);
          return _json({'ok': true, 'seq': await repo!.store.currentSeq(), 'access': s.access.toJson()});
        case 'api/db':
          return await _db(s, body);
        case 'api/tx':
          return await _txRoute(s, body);
        case 'api/admin':
          return await _admin(s, body);
      }
      return _err('آدرس نامعتبر', 404, 'not_found');
    } on AccessDenied catch (e) {
      return _err(e.message, 403, 'access_denied');
    } on DatabaseException catch (e) {
      return _err('$e', 400, 'sql_error');
    } catch (e) {
      return _err('$e', 500);
    }
  }

  bool _codeOk(Request req, String code) => req.headers['x-pair-code'] == code;

  Future<Response> _info(Request req) async {
    if (!_codeOk(req, await pairCode())) return _err('کد اتصال اشتباه است.', 401, 'bad_code');
    final list = <Map<String, Object?>>[];
    for (final c in companies.companies) {
      final repo = await companies.repoFor(c.id);
      list.add({'id': c.id, 'name': c.name, 'usersEnabled': repo == null ? false : await UserStore(repo.store).enabled()});
    }
    return _json({'app': 'simple_accounting', 'companies': list});
  }

  Future<Response> _login(Request req, Map<String, dynamic> b) async {
    if (!_codeOk(req, await pairCode())) return _err('کد اتصال اشتباه است.', 401, 'bad_code');
    final companyId = (b['companyId'] ?? '') as String;
    final username = ((b['username'] ?? '') as String).trim().toLowerCase();
    final repo = await companies.repoFor(companyId);
    if (repo == null) return _err('این شرکت روی سرور وجود ندارد.', 404, 'no_company');
    final users = UserStore(repo.store);
    if (!await users.enabled()) {
      return _err('برای این شرکت کاربری تعریف نشده است. اول در برنامهٔ سرور از «کاربران و دسترسی» کاربر مدیر بسازید.', 403, 'no_users');
    }
    final key = '$companyId:$username';
    final f = _failures[key];
    if (f != null && f.$1 >= 5 && DateTime.now().isBefore(f.$2)) {
      return _err('ورودهای ناموفق زیاد بود؛ چند ثانیه بعد دوباره تلاش کنید.', 429, 'locked');
    }
    final u = await users.verify(username, (b['password'] ?? '') as String);
    if (u == null) {
      _failures[key] = ((f != null && DateTime.now().isBefore(f.$2) ? f.$1 : 0) + 1, DateTime.now().add(const Duration(seconds: 30)));
      return _err('نام کاربری یا رمز عبور اشتباه است.', 401, 'bad_credentials');
    }
    _failures.remove(key);
    final role = await users.role(u.roleId);
    final access = await users.accessOf(u);
    final NetSession s;
    try {
      s = sessions.login(
        companyId: companyId, userId: u.id, username: u.username, display: u.display, roleName: role?.name ?? '', access: access,
        deviceId: (b['deviceId'] ?? '') as String, deviceName: (b['deviceName'] ?? 'یک سیستم') as String,
      );
    } on AlreadyActive catch (e) {
      return _err(e.toString(), 409, 'already_active', {'device': e.deviceName});
    }
    return _json({
      'token': s.token,
      'companyName': companies.companies.firstWhere((c) => c.id == companyId).name,
      'user': {'id': u.id, 'username': u.username, 'display': u.display, 'roleName': role?.name ?? ''},
      'access': access.toJson(),
      'seq': await repo.store.currentSeq(),
    });
  }

  // ---- database -----------------------------------------------------------

  Future<Response> _db(NetSession s, Map<String, dynamic> b) async {
    final repo = (await companies.repoFor(s.companyId))!;
    final op = Op.fromJson(Map<String, dynamic>.from(b['op'] as Map));
    checkOp(s.access, op);
    final txId = b['tx'] as String?;
    final DatabaseExecutor ex;
    if (txId != null) {
      final t = _txs[txId];
      if (t == null || t.owner != s.token) return _err('تراکنش نامعتبر یا منقضی شده است.', 400, 'tx_gone');
      _touchTx(txId, t);
      ex = t.tx;
    } else {
      ex = repo.store.raw;
    }
    final result = await runOp(ex, op);
    if (op.isWrite && txId == null) repo.changed();
    return _json({'result': result});
  }

  void _touchTx(String id, _Tx t) {
    t.timer?.cancel();
    t.timer = Timer(_Tx.idle, () => _endTx(id, false));
  }

  Future<void> _endTx(String id, bool commit) async {
    final t = _txs.remove(id);
    if (t == null) return;
    t.timer?.cancel();
    if (!t.finish.isCompleted) t.finish.complete(commit);
    await t.done;
  }

  Future<void> _dropTxs(String token) async {
    for (final e in _txs.entries.where((e) => e.value.owner == token).toList()) {
      await _endTx(e.key, false);
    }
  }

  Future<Response> _txRoute(NetSession s, Map<String, dynamic> b) async {
    final repo = (await companies.repoFor(s.companyId))!;
    if (b['action'] == 'begin') {
      if (_txs.values.where((t) => t.owner == s.token).length >= 4) return _err('تراکنش‌های باز زیاد است.', 429, 'too_many_tx');
      final t = _Tx(s.token);
      final id = List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _txs[id] = t;
      t.done = () async {
        try {
          await repo.store.raw.transaction((tx) async {
            t.tx = tx;
            t.ready.complete();
            if (!await t.finish.future) throw _Rollback();
          });
          repo.changed();
        } on _Rollback {
          // rolled back on purpose
        } catch (e) {
          if (!t.ready.isCompleted) t.ready.completeError(e);
        }
      }();
      _touchTx(id, t);
      try {
        await t.ready.future;
      } catch (e) {
        _txs.remove(id);
        rethrow;
      }
      return _json({'tx': id});
    }
    final id = (b['tx'] ?? '') as String;
    final t = _txs[id];
    if (t == null || t.owner != s.token) return _json({'ok': true}); // already ended (timeout): nothing to do
    await _endTx(id, b['commit'] == true);
    return _json({'ok': true});
  }

  // ---- administration -----------------------------------------------------

  Future<Response> _admin(NetSession s, Map<String, dynamic> b) async {
    if (!s.access.can(permUsers)) throw AccessDenied();
    final repo = (await companies.repoFor(s.companyId))!;
    final admin = LocalUserAdmin(UserStore(repo.store), sessions, s.companyId);
    try {
      switch (b['action']) {
        case 'users':
          return _json({'users': [for (final u in await admin.users()) u.toJson()]});
        case 'roles':
          return _json({'roles': [for (final r in await admin.roles()) {'id': r.id, 'name': r.name, 'perms': r.perms.toList()..sort(), 'builtin': r.builtin}]});
        case 'sessions':
          return _json({'sessions': [for (final x in await admin.sessions()) x.toJson()]});
        case 'saveUser':
          final id = await admin.saveUser(
            id: b['id'] as String?, username: b['username'] as String, fullName: (b['fullName'] ?? '') as String, roleId: b['roleId'] as String,
            password: b['password'] as String?, active: b['active'] != false,
          );
          return _json({'id': id});
        case 'deleteUser':
          if (b['id'] == s.userId) return _err('خودتان را نمی‌توانید حذف کنید.', 400);
          await admin.deleteUser(b['id'] as String);
          return _json({'ok': true});
        case 'saveRole':
          final id = await admin.saveRole(id: b['id'] as String?, name: b['name'] as String, perms: {for (final p in (b['perms'] as List)) '$p'});
          return _json({'id': id});
        case 'deleteRole':
          await admin.deleteRole(b['id'] as String);
          return _json({'ok': true});
        case 'kick':
          await admin.kick(b['userId'] as String);
          return _json({'ok': true});
      }
    } on StateError catch (e) {
      return _err(e.message, 400, 'rejected');
    }
    return _err('درخواست نامعتبر', 400);
  }
}
