import 'dart:async';

import 'package:flutter/material.dart';

import '../data/access.dart';
import '../data/company_manager.dart';
import '../data/guard.dart';
import '../data/sessions.dart';
import '../data/user_admin.dart';
import '../data/users.dart';
import '../sync/sync_service.dart';

/// Who is using the app right now and what they may do.
class Identity {
  Identity({required this.access, this.display = '', this.roleName = '', this.userId = '', this.admin, this.logout, this.client = false, this.mobile = false});

  final Access access;
  final String display, roleName, userId;

  bool can(String perm) => access.can(perm);
  bool canView(String area) => access.canView(area);
  bool canEdit(String area) => access.canEdit(area);

  /// For the users screen; null when it is not available.
  final UserAdmin? admin;

  /// Signs the user out (null when users are not switched on).
  final Future<void> Function()? logout;

  /// Working over the network on a server's data.
  final bool client;

  /// An offline copy on a phone that synchronises with a server.
  final bool mobile;

  bool get signedIn => logout != null;

  /// Everything allowed, nobody signed in (users are not switched on).
  static final open = Identity(access: const Access.unrestricted());
}

/// Makes the [Identity] available to every screen below it.
class AccessScope extends InheritedWidget {
  const AccessScope({super.key, required this.identity, required super.child});
  final Identity identity;

  static Identity of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AccessScope>()?.identity ?? Identity.open;

  @override
  bool updateShouldNotify(AccessScope old) => old.identity != identity || old.identity.access != identity.access;
}

/// Sign-in on this very system (the server or a stand-alone one), per company.
/// Every sign-in is a session in the server's [SessionManager], so a user who
/// is signed in here cannot be signed in on a network client and the other way
/// round.
class LocalAuth extends ChangeNotifier {
  LocalAuth(this.companies, this.sync);
  final CompanyManager companies;
  final SyncService sync;

  final Map<String, NetSession> _mine = {};
  final Map<String, (int, DateTime)> _failures = {};
  final Map<String, Access> _applied = {}; // the access currently installed per company
  Timer? _timer;

  /// Bumped when users are switched on or off, so gates re-check.
  int version = 0;

  Future<UserStore?> _store(String companyId) async {
    final repo = await companies.repoFor(companyId);
    return repo == null ? null : UserStore(repo.store);
  }

  Future<bool> usersEnabled(String companyId) async => (await _store(companyId))?.enabled() ?? false;

  NetSession? sessionFor(String companyId) => _mine[companyId];

  Future<void> _apply(String companyId, Access? access) async {
    final repo = await companies.repoFor(companyId);
    repo?.store.setAccess(access);
  }

  /// Everything is open for this company (users are not switched on).
  Future<void> release(String companyId) => _apply(companyId, null);

  /// Signs in. Throws [StateError] with a message to show.
  Future<void> login(String companyId, String username, String password) async {
    final store = await _store(companyId);
    if (store == null) throw StateError('شرکت پیدا نشد.');
    final key = '$companyId:${username.trim().toLowerCase()}';
    final f = _failures[key];
    if (f != null && f.$1 >= 5 && DateTime.now().isBefore(f.$2)) throw StateError('ورودهای ناموفق زیاد بود؛ چند ثانیه بعد دوباره تلاش کنید.');
    final u = await store.verify(username, password);
    if (u == null) {
      _failures[key] = ((f != null && DateTime.now().isBefore(f.$2) ? f.$1 : 0) + 1, DateTime.now().add(const Duration(seconds: 30)));
      throw StateError('نام کاربری یا رمز عبور اشتباه است.');
    }
    _failures.remove(key);
    final role = await store.role(u.roleId);
    final access = await store.accessOf(u, device: 'سرور (این سیستم)');
    try {
      _mine[companyId] = sync.sessions.login(
        companyId: companyId, userId: u.id, username: u.username, display: u.display, roleName: role?.name ?? '', access: access,
        deviceId: companies.prefs.deviceUid, deviceName: 'سرور (این سیستم)', local: true,
      );
    } on AlreadyActive catch (e) {
      throw StateError(e.toString());
    }
    _applied[companyId] = access;
    await _apply(companyId, access);
    await logEvent((await companies.repoFor(companyId))!.store.raw, access, 'login', summary: 'ورود به برنامه');
    _timer ??= Timer.periodic(const Duration(seconds: 10), (_) => _beat());
    version++;
    notifyListeners();
  }

  Future<void> logout(String companyId) async {
    final s = _mine.remove(companyId);
    final was = _applied.remove(companyId);
    if (s != null) sync.sessions.logout(s.token);
    if (was != null) await logEvent((await companies.repoFor(companyId))!.store.raw, was, 'logout', summary: 'خروج از برنامه');
    await _apply(companyId, Access({})); // nothing may be changed until someone signs in
    if (_mine.isEmpty) _stopTimer();
    version++;
    notifyListeners();
  }

  /// Called after users were switched on or off.
  void usersChanged() {
    version++;
    notifyListeners();
  }

  Future<void> _beat() async {
    var changed = false;
    for (final e in _mine.entries.toList()) {
      final s = sync.sessions.touch(e.value.token);
      if (s == null) {
        _mine.remove(e.key); // ended by an administrator (or removed)
        _applied.remove(e.key);
        await _apply(e.key, Access({}));
        changed = true;
      } else if (!identical(s.access, _applied[e.key])) {
        _applied[e.key] = s.access; // a role changed: install the new permissions
        await _apply(e.key, s.access);
        changed = true;
      }
    }
    if (_mine.isEmpty) _stopTimer();
    if (changed) {
      version++;
      notifyListeners();
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// The identity for a company once the gate let the user in.
  Future<Identity> identityFor(String companyId) async {
    final repo = (await companies.repoFor(companyId))!;
    final admin = LocalUserAdmin(UserStore(repo.store), sync.sessions, companyId);
    final s = _mine[companyId];
    if (s == null) return Identity(access: const Access.unrestricted(), admin: admin);
    return Identity(access: s.access, display: s.display, roleName: s.roleName, userId: s.userId, admin: admin, logout: () => logout(companyId));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Shows the sign-in screen when users are switched on for the company and
/// nobody is signed in; otherwise the app for that company.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.auth, required this.companyId, required this.companyName, required this.builder});
  final LocalAuth auth;
  final String companyId, companyName;
  final Widget Function(Identity identity) builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: auth,
        builder: (context, _) => FutureBuilder<(bool, Identity)>(
          key: ValueKey('gate$companyId${auth.version}'),
          future: () async {
            final enabled = await auth.usersEnabled(companyId);
            if (!enabled) {
              await auth.release(companyId);
              return (true, await auth.identityFor(companyId));
            }
            if (auth.sessionFor(companyId) == null) return (false, Identity.open);
            return (true, await auth.identityFor(companyId));
          }(),
          builder: (c, snap) {
            if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
            final (ok, identity) = snap.data!;
            if (!ok) return LoginForm(title: companyName, onLogin: (u, p) => auth.login(companyId, u, p), subtitle: 'برای ورود به این شرکت نام کاربری و رمز عبور را وارد کنید.');
            return AccessScope(identity: identity, child: builder(identity));
          },
        ),
      );
}

/// A full-screen sign-in form. [onLogin] throws an error (shown to the user) when it fails.
class LoginForm extends StatefulWidget {
  const LoginForm({super.key, required this.title, required this.onLogin, this.subtitle = '', this.initialUser = '', this.footer, this.message});
  final String title, subtitle, initialUser;
  final Future<void> Function(String user, String password) onLogin;
  final Widget? footer;

  /// A notice shown above the form (e.g. why the session ended).
  final String? message;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  late final user = TextEditingController(text: widget.initialUser);
  final pass = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void dispose() {
    user.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onLogin(user.text.trim(), pass.text);
    } on StateError catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Image.asset('assets/logo.png', height: 72),
                const SizedBox(height: 12),
                Text(widget.title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                if (widget.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(widget.subtitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                ],
                if (widget.message != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
                    child: Text(widget.message!),
                  ),
                ],
                const SizedBox(height: 20),
                TextField(
                  controller: user,
                  textDirection: TextDirection.ltr,
                  autofocus: widget.initialUser.isEmpty,
                  decoration: const InputDecoration(labelText: 'نام کاربری', prefixIcon: Icon(Icons.person_outline)),
                  onSubmitted: (_) => _go(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: pass,
                  obscureText: true,
                  textDirection: TextDirection.ltr,
                  autofocus: widget.initialUser.isNotEmpty,
                  decoration: const InputDecoration(labelText: 'رمز عبور', prefixIcon: Icon(Icons.lock_outline)),
                  onSubmitted: (_) => _go(),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy ? null : _go,
                  child: busy ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('ورود'),
                ),
                if (widget.footer != null) ...[const SizedBox(height: 12), widget.footer!],
              ]),
            ),
          ),
        ),
      );
}
