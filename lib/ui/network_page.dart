import 'package:flutter/material.dart';

import '../data/company_manager.dart';
import '../data/net_mode.dart';
import '../data/users.dart';
import '../sync/sync_service.dart';
import '../util/format.dart';
import 'auth.dart';
import 'common.dart';

/// Choose how this system takes part in a network: on its own, as the server
/// whose data the other systems use, or as a client of a server.
class NetworkPage extends StatefulWidget {
  const NetworkPage({super.key, required this.net, required this.sync, required this.companies, required this.auth});
  final NetMode net;
  final SyncService sync;
  final CompanyManager companies;
  final LocalAuth auth;

  @override
  State<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<NetworkPage> {
  List<String> addresses = [];
  String pairCode = '';

  NetMode get net => widget.net;

  @override
  void initState() {
    super.initState();
    () async {
      final a = await SyncService.localAddresses();
      final c = await widget.sync.pairCode();
      if (mounted) {
        setState(() {
          addresses = a;
          pairCode = c;
        });
      }
    }();
  }

  Future<void> _mode(String m) async {
    if (m == NetMode.mobile && !await confirm(context, 'این دستگاه به حالت موبایل می‌رود: یک نسخهٔ آفلاین از اطلاعات یک شرکت سرور را نگه می‌دارد و فقط فاکتور و اشخاص را ثبت می‌کند. اطلاعات فعلی همین دستگاه دست‌نخورده می‌ماند. ادامه بدهم؟')) return;
    if (!mounted) return;
    if (m == NetMode.client && !await confirm(context, 'این سیستم به یک سرور وصل می‌شود و اطلاعات آنجا را می‌بیند (بدون حق ثبت و ویرایش). اطلاعات فعلی همین سیستم دست‌نخورده می‌ماند و با بازگشت به حالت مستقل دوباره دیده می‌شود. ادامه بدهم؟')) return;
    await net.setMode(m);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Constrained(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Section(
            title: 'حالت این سیستم',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: NetMode.standalone, icon: Icon(Icons.computer), label: Text('مستقل')),
                  ButtonSegment(value: NetMode.server, icon: Icon(Icons.dns_outlined), label: Text('سرور')),
                  ButtonSegment(value: NetMode.client, icon: Icon(Icons.lan_outlined), label: Text('کلاینت')),
                  ButtonSegment(value: NetMode.mobile, icon: Icon(Icons.smartphone), label: Text('موبایل')),
                ],
                selected: {net.mode},
                onSelectionChanged: (s) => _mode(s.first),
              ),
              const SizedBox(height: 10),
              Text(
                switch (net.mode) {
                  NetMode.server => 'اطلاعات روی همین سیستم می‌ماند و سیستم‌های دیگر شبکه (کلاینت‌ها) با نام کاربری و رمز خودشان روی همین اطلاعات کار می‌کنند. این سیستم باید روشن و برنامه باز باشد.',
                  NetMode.client => 'این سیستم اطلاعاتی نگه نمی‌دارد و فقط اطلاعات سرور را می‌بیند؛ ثبت و ویرایش روی سیستم سرور انجام می‌شود.',
                  NetMode.mobile => 'یک نسخهٔ کامل از اطلاعات روی همین دستگاه می‌ماند و بدون شبکه هم کار می‌کند. فاکتورها را می‌زنید و هر وقت به سرور وصل شدید همگام می‌کنید.',
                  _ => 'هر سیستم اطلاعات خودش را دارد؛ در صورت نیاز از بخش «همگام‌سازی» دو سیستم را با هم یکی می‌کنید.',
                },
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          ),
          if (net.isServer) ..._server(context),
          if (net.mode == NetMode.standalone) ...[
            const SizedBox(height: 12),
            Section(
              title: 'اتصال به یک سرور',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('اگر در شبکه سیستمی به‌عنوان سرور تنظیم شده، با زدن «کلاینت» بالا به آن وصل می‌شوید.', style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ],
        ]),
      );

  List<Widget> _server(BuildContext context) => [
        const SizedBox(height: 12),
        Section(
          title: 'مشخصات سرور (برای وارد کردن در کلاینت‌ها)',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!widget.sync.serverRunning)
              Text('سرور روشن نشد (پورت اشغال است یا اجازهٔ شبکه نیست).', style: TextStyle(color: Theme.of(context).colorScheme.error))
            else ...[
              _kv('پورت', faDigits('${widget.sync.port}')),
              _kv('آدرس‌ها', addresses.isEmpty ? '—' : addresses.map(faDigits).join('  •  ')),
              _kv('کد اتصال', faDigits(pairCode)),
            ],
            const SizedBox(height: 6),
            Text('کلاینت‌ها باید در همین شبکه (Wi‑Fi یا کابل) باشند. اگر ویندوز پرسید، اجازهٔ دسترسی شبکه به برنامه را بدهید.', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'شرکت‌ها و کاربران',
          child: FutureBuilder<List<(String, String, bool)>>(
            future: () async {
              final out = <(String, String, bool)>[];
              for (final c in widget.companies.companies) {
                final repo = await widget.companies.repoFor(c.id);
                out.add((c.id, c.name, repo != null && await UserStore(repo.store).enabled()));
              }
              return out;
            }(),
            builder: (c, snap) {
              if (!snap.hasData) return const LinearProgressIndicator();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (_, name, ok) in snap.data!)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded, color: ok ? Colors.green : Colors.orange),
                    title: Text(name),
                    subtitle: Text(ok ? 'آمادهٔ اتصال کلاینت‌ها' : 'کاربری تعریف نشده؛ کلاینت‌ها نمی‌توانند وارد شوند'),
                  ),
                Text('برای هر شرکت از «کاربران و دسترسی» کاربر مدیر و بقیهٔ کاربران را بسازید (هر شرکت کاربران خودش را دارد).', style: Theme.of(c).textTheme.bodySmall),
              ]);
            },
          ),
        ),
        const SizedBox(height: 12),
        Section(
          title: 'کاربران وارد‌شده الان',
          child: ListenableBuilder(
            listenable: widget.sync.sessions,
            builder: (c, _) {
              final list = widget.sync.sessions.active();
              if (list.isEmpty) return const Text('کسی وارد نیست.');
              final names = {for (final x in widget.companies.companies) x.id: x.name};
              return Column(children: [
                for (final s in list)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(s.local ? Icons.dns_outlined : Icons.computer_outlined),
                    title: Text('${s.display} (${s.username})'),
                    subtitle: Text('${names[s.companyId] ?? ''} • ${s.deviceName}'),
                    trailing: TextButton(onPressed: () => widget.sync.sessions.kick(s.companyId, s.userId), child: const Text('قطع نشست')),
                  ),
              ]);
            },
          ),
        ),
      ];

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 90, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: SelectableText(v, textDirection: TextDirection.ltr, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}
