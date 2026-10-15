import 'package:flutter/material.dart';

import '../data/device_prefs.dart';
import '../data/net_mode.dart';
import '../data/remote_db.dart';
import '../data/remote_session.dart';
import 'common.dart';

/// The app on a network client: first connect to the server and sign in, then
/// [homeBuilder] shows the app on the server's data. When the server ends the
/// session (signed out by an administrator, signed in elsewhere, connection lost
/// for too long) the user is brought back here with the reason.
class ClientRoot extends StatefulWidget {
  const ClientRoot({super.key, required this.net, required this.prefs, required this.homeBuilder});
  final NetMode net;
  final DevicePrefs prefs;
  final Widget Function(BuildContext context, RemoteSession session, Future<void> Function() leave) homeBuilder;

  @override
  State<ClientRoot> createState() => _ClientRootState();
}

class _ClientRootState extends State<ClientRoot> {
  RemoteSession? session;
  String? notice;

  void _adopt(RemoteSession s) {
    s.start();
    s.addListener(_changed);
    setState(() {
      session = s;
      notice = null;
    });
  }

  void _changed() {
    final s = session;
    if (s != null && s.ended && mounted) {
      s.removeListener(_changed);
      final why = s.endedReason == 'logout' ? null : SessionEnded(s.endedReason!).message;
      setState(() {
        session = null;
        notice = why;
      });
      s.logout();
    }
  }

  Future<void> _leave() async {
    final s = session;
    if (s == null) return;
    s.removeListener(_changed);
    await s.logout();
    if (mounted) setState(() => session = null);
  }

  @override
  void dispose() {
    session?.removeListener(_changed);
    session?.logout();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s != null) return widget.homeBuilder(context, s, _leave);
    return ConnectScreen(net: widget.net, prefs: widget.prefs, notice: notice, onConnected: _adopt);
  }
}

/// Server address, company and user name/password.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.net, required this.prefs, required this.onConnected, this.notice});
  final NetMode net;
  final DevicePrefs prefs;
  final String? notice;
  final void Function(RemoteSession) onConnected;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final host = TextEditingController(text: widget.net.host);
  late final port = TextEditingController(text: '${widget.net.port}');
  late final code = TextEditingController(text: widget.net.code);
  late final user = TextEditingController(text: widget.net.lastUser);
  final pass = TextEditingController();
  List<ServerCompany>? companies;
  String? companyId;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.net.host.isNotEmpty && widget.net.code.isNotEmpty) _fetch(quiet: true);
  }

  @override
  void dispose() {
    for (final c in [host, port, code, user, pass]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _port => int.tryParse(port.text.trim()) ?? 8765;

  Future<void> _fetch({bool quiet = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final list = await RemoteSession.companies(host.text.trim(), _port, code.text.trim());
      if (!mounted) return;
      setState(() {
        companies = list;
        companyId = list.any((c) => c.id == widget.net.lastCompany) ? widget.net.lastCompany : list.firstOrNull?.id;
      });
    } on NetException catch (e) {
      if (mounted && !quiet) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _login() async {
    final id = companyId;
    if (id == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final s = await RemoteSession.login(
          host: host.text.trim(), port: _port, code: code.text.trim(), companyId: id, username: user.text.trim(), password: pass.text, prefs: widget.prefs);
      await widget.net.remember(host: host.text.trim(), port: _port, code: code.text.trim(), company: id, user: user.text.trim());
      if (mounted) widget.onConnected(s);
    } on NetException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Image.asset('assets/logo.png', height: 72),
                const SizedBox(height: 12),
                Text('اتصال به سرور', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('این سیستم روی اطلاعات سرور کار می‌کند.', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                if (widget.notice != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiaryContainer, borderRadius: BorderRadius.circular(10)),
                    child: Text(widget.notice!),
                  ),
                ],
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(flex: 3, child: TextField(controller: host, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'آدرس سرور (مثلاً 192.168.1.10)'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: port, keyboardType: TextInputType.number, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'پورت'))),
                ]),
                const SizedBox(height: 12),
                TextField(controller: code, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'کد اتصال (از برنامهٔ سرور)')),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: busy ? null : _fetch,
                  icon: const Icon(Icons.search),
                  label: Text(companies == null ? 'اتصال و دریافت فهرست شرکت‌ها' : 'دریافت دوبارهٔ شرکت‌ها'),
                ),
                if (companies != null) ...[
                  const Divider(height: 28),
                  if (companies!.isEmpty)
                    const Text('سرور شرکتی ندارد.')
                  else ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey(companyId),
                      initialValue: companyId,
                      decoration: const InputDecoration(labelText: 'شرکت'),
                      items: [for (final c in companies!) DropdownMenuItem(value: c.id, child: Text(c.usersEnabled ? c.name : '${c.name} (کاربر تعریف نشده)'))],
                      onChanged: (v) => setState(() => companyId = v),
                    ),
                    const SizedBox(height: 12),
                    TextField(controller: user, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'نام کاربری', prefixIcon: Icon(Icons.person_outline))),
                    const SizedBox(height: 12),
                    TextField(controller: pass, obscureText: true, textDirection: TextDirection.ltr, onSubmitted: (_) => _login(), decoration: const InputDecoration(labelText: 'رمز عبور', prefixIcon: Icon(Icons.lock_outline))),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: busy ? null : _login, child: const Text('ورود')),
                  ],
                ],
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () async {
                    if (await confirm(context, 'به حالت مستقل (اطلاعات روی همین سیستم) برگردید؟')) await widget.net.setMode(NetMode.standalone);
                  },
                  child: const Text('بازگشت به حالت مستقل'),
                ),
              ]),
            ),
          ),
        ),
      );
}
