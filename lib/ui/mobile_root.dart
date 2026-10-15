import 'package:flutter/material.dart';

import '../data/company_manager.dart';
import '../data/net_mode.dart';
import '../data/remote_db.dart';
import '../data/repo.dart';
import '../sync/mobile_sync.dart';
import '../util/format.dart';
import 'auth.dart';
import 'common.dart';

/// The app in mobile mode: a complete offline copy of one company. Until it is
/// connected to a server the setup screen is shown; after that the normal app
/// runs on the local copy, with the rights of the user who connected it.
class MobileRoot extends StatefulWidget {
  const MobileRoot({super.key, required this.mobile, required this.companies, required this.net, required this.homeBuilder});
  final MobileController mobile;
  final CompanyManager companies;
  final NetMode net;
  final Widget Function(BuildContext context, Repo repo, Identity identity) homeBuilder;

  @override
  State<MobileRoot> createState() => _MobileRootState();
}

class _MobileRootState extends State<MobileRoot> {
  bool ready = false;

  MobileController get mobile => widget.mobile;

  @override
  void initState() {
    super.initState();
    mobile.addListener(_changed);
    _prepare();
  }

  @override
  void dispose() {
    mobile.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
    _prepare();
  }

  /// Opens the local copy and limits it to what this user may change.
  Future<void> _prepare() async {
    if (!mobile.configured) {
      if (ready && mounted) setState(() => ready = false);
      return;
    }
    await widget.companies.switchTo(mobile.localId);
    final p = mobile.profile;
    if (p != null) widget.companies.active.store.setAccess(p.access);
    if (mounted) setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!mobile.configured) return MobileSetupScreen(mobile: mobile, companies: widget.companies, net: widget.net);
    final p = mobile.profile;
    if (!ready || p == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final identity = Identity(access: p.access, display: p.display.isEmpty ? p.username : p.display, roleName: p.roleName, userId: p.userId, client: true, mobile: true);
    return AccessScope(identity: identity, child: widget.homeBuilder(context, widget.companies.active, identity));
  }
}

/// First connection of a phone: server, company, user. Downloads the company.
class MobileSetupScreen extends StatefulWidget {
  const MobileSetupScreen({super.key, required this.mobile, required this.companies, required this.net});
  final MobileController mobile;
  final CompanyManager companies;
  final NetMode net;

  @override
  State<MobileSetupScreen> createState() => _MobileSetupScreenState();
}

class _MobileSetupScreenState extends State<MobileSetupScreen> {
  late final host = TextEditingController(text: widget.mobile.host);
  late final port = TextEditingController(text: '${widget.mobile.port}');
  late final code = TextEditingController(text: widget.mobile.code);
  late final user = TextEditingController(text: widget.mobile.username);
  final pass = TextEditingController();
  List<(String, String)>? list;
  String? companyId, error;
  bool busy = false;

  int get _port => int.tryParse(port.text.trim()) ?? 8765;

  @override
  void dispose() {
    for (final c in [host, port, code, user, pass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final l = await serverCompanies(host.text.trim(), _port, code.text.trim());
      if (mounted) {
        setState(() {
          list = l;
          companyId = l.firstOrNull?.$1;
        });
      }
    } on NetException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _connect() async {
    final id = companyId;
    if (id == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    final m = widget.mobile;
    final cm = widget.companies;
    final before = cm.activeId;
    final local = 'mobile-$id';
    var created = false;
    try {
      await m.save(host: host.text.trim(), port: _port, code: code.text.trim(), companyId: id, username: user.text.trim(), localId: local);
      if (!cm.companies.any((c) => c.id == local)) {
        await cm.create('${list!.firstWhere((c) => c.$1 == id).$2} (موبایل)', seed: false, activate: true, id: local);
        created = true;
      } else {
        await cm.switchTo(local);
      }
      final repo = cm.active;
      await m.sync(repo, password: pass.text);
      if (mounted) setState(() {});
    } on NetException catch (e) {
      await m.disconnect();
      if (created) {
        await cm.switchTo(before);
        await cm.delete(local);
      }
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      await m.disconnect();
      if (created) {
        await cm.switchTo(before);
        await cm.delete(local);
      }
      if (mounted) setState(() => error = '$e');
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
                Text('حالت موبایل', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  'یک نسخهٔ کامل از اطلاعات شرکت روی این دستگاه ذخیره می‌شود و بدون اینترنت و شبکه هم کار می‌کند. فاکتورهایی که اینجا می‌زنید هر وقت به سرور وصل شدید به آن فرستاده می‌شود و شمارهٔ نهایی را سرور تعیین می‌کند.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(flex: 3, child: TextField(controller: host, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'آدرس سرور (مثلاً 192.168.1.10)'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: port, keyboardType: TextInputType.number, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'پورت'))),
                ]),
                const SizedBox(height: 12),
                TextField(controller: code, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'کد اتصال (از برنامهٔ سرور)')),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: busy ? null : _fetch, icon: const Icon(Icons.search), label: const Text('دریافت فهرست شرکت‌ها')),
                if (list != null) ...[
                  const Divider(height: 28),
                  if (list!.isEmpty)
                    const Text('سرور شرکتی ندارد.')
                  else ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey(companyId),
                      initialValue: companyId,
                      decoration: const InputDecoration(labelText: 'شرکت'),
                      items: [for (final c in list!) DropdownMenuItem(value: c.$1, child: Text(c.$2))],
                      onChanged: (v) => setState(() => companyId = v),
                    ),
                    const SizedBox(height: 12),
                    TextField(controller: user, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'نام کاربری', prefixIcon: Icon(Icons.person_outline))),
                    const SizedBox(height: 12),
                    TextField(controller: pass, obscureText: true, textDirection: TextDirection.ltr, onSubmitted: (_) => _connect(), decoration: const InputDecoration(labelText: 'رمز عبور', prefixIcon: Icon(Icons.lock_outline))),
                    const SizedBox(height: 16),
                    FilledButton.icon(onPressed: busy ? null : _connect, icon: const Icon(Icons.cloud_download_outlined), label: const Text('اتصال و دریافت اطلاعات')),
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

/// Status of the phone's copy and the button that exchanges data with the server.
class MobileSyncPage extends StatefulWidget {
  const MobileSyncPage({super.key, required this.repo, required this.mobile, required this.net});
  final Repo repo;
  final MobileController mobile;
  final NetMode net;

  @override
  State<MobileSyncPage> createState() => _MobileSyncPageState();
}

class _MobileSyncPageState extends State<MobileSyncPage> {
  bool busy = false;
  MobileSyncResult? last;
  String? error;
  late Future<int> pending = widget.mobile.pending(widget.repo);

  MobileController get m => widget.mobile;

  Future<String?> _askPassword() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('رمز عبور ${m.profile?.display ?? m.username}'),
        content: TextField(controller: c, obscureText: true, autofocus: true, textDirection: TextDirection.ltr, onSubmitted: (v) => Navigator.pop(ctx, v), decoration: const InputDecoration(labelText: 'رمز عبور')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('همگام‌سازی')),
        ],
      ),
    );
  }

  Future<void> _sync() async {
    String? pw;
    if (!m.hasPassword) {
      pw = await _askPassword();
      if (pw == null) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await m.sync(widget.repo, password: pw);
      if (mounted) {
        setState(() {
          last = r;
          pending = m.pending(widget.repo);
        });
        // The user's rights may have changed on the server.
        final p = m.profile;
        if (p != null) widget.repo.store.setAccess(p.access);
      }
    } on NetException catch (e) {
      if (mounted) setState(() => error = e.offline ? 'به سرور وصل نشد. اتصال شبکه و آدرس سرور را بررسی کنید؛ اطلاعات شما سر جایش هست.' : e.message);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = m.profile;
    final when = m.lastSync;
    return Constrained(
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Section(
          title: 'همگام‌سازی با سرور',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _kv('سرور', faDigits('${m.host}:${m.port}')),
            _kv('شرکت', p?.companyName ?? ''),
            _kv('کاربر', p == null ? m.username : '${p.display.isEmpty ? p.username : p.display} • ${p.roleName}'),
            _kv('آخرین همگام‌سازی', when == null ? 'هنوز انجام نشده' : '${faDigits(jalaliText(isoOf(when)))}  ${faDigits('${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}')}'),
            FutureBuilder<int>(
              future: pending,
              builder: (c, s) => _kv('منتظر ارسال', s.hasData ? (s.data == 0 ? 'چیزی نیست' : '${faDigits('${s.data}')} مورد (فاکتور / شخص)') : '…'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: busy ? null : _sync, icon: const Icon(Icons.sync), label: const Text('ارسال فاکتورها و دریافت تغییرات')),
            if (busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            if (last != null) ...[
              const SizedBox(height: 10),
              Text('${faDigits('${last!.sent}')} مورد فرستاده و ${faDigits('${last!.received}')} مورد دریافت شد.', style: Theme.of(context).textTheme.bodyMedium),
              if (last!.renumbered > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('شمارهٔ ${faDigits('${last!.renumbered}')} سند تغییر کرد، چون همان شماره روی سرور یا دستگاه دیگری استفاده شده بود. شمارهٔ نهایی را از فهرست فاکتورها ببینید.', style: Theme.of(context).textTheme.bodySmall),
                ),
              for (final x in last!.rejected)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                  title: Text(x.label),
                  subtitle: Text('سرور نپذیرفت: ${x.reason}'),
                ),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'این حالت چطور کار می‌کند',
          child: Text(
            'همهٔ اطلاعات روی همین دستگاه است و بدون شبکه می‌توانید فاکتور بزنید و مشتری اضافه کنید. فقط فاکتور و اشخاص قابل ثبت‌اند؛ بقیهٔ بخش‌ها را فقط می‌بینید. '
            'با «ارسال و دریافت» فاکتورهای تازه به سرور می‌رود، شمارهٔ نهایی را سرور می‌دهد و تغییرات سرور هم به این دستگاه می‌آید. '
            'فاکتور در دورهٔ مالی بسته‌شده یا بدون دسترسی نقش شما پذیرفته نمی‌شود.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.logout),
          label: const Text('قطع اتصال و بازگشت به حالت مستقل'),
          onPressed: () async {
            if (!await confirm(context, 'اتصال به سرور قطع می‌شود. نسخهٔ موجود روی این دستگاه به‌عنوان یک شرکت جداگانه می‌ماند، ولی فاکتورهای ارسال‌نشده دیگر به سرور نمی‌رسند. ادامه بدهم؟')) return;
            await m.disconnect();
            await widget.net.setMode(NetMode.standalone);
          },
        ),
      ]),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}
