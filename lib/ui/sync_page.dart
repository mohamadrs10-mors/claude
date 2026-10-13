import 'dart:async';

import 'package:flutter/material.dart';

import '../data/company_manager.dart';
import '../data/repo.dart';
import '../sync/sync_service.dart';
import '../util/format.dart';
import 'common.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.repo, required this.sync, required this.companies});
  final Repo repo;
  final SyncService sync;
  final CompanyManager companies;
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final peer = TextEditingController();
  final code = TextEditingController();
  List<String> ips = [];
  String? status;
  bool busy = false, auto = false;
  Timer? timer;

  SyncService get sync => widget.sync;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final db = widget.repo.store;
    peer.text = await db.getMeta('peer') ?? '';
    code.text = await sync.pairCode();
    auto = (await db.getMeta('auto_sync')) == '1';
    ips = await SyncService.localAddresses();
    final last = await db.getMeta('last_sync');
    if (last != null) status = 'آخرین همگام‌سازی: ${_fmt(DateTime.parse(last))}';
    if (auto && peer.text.isNotEmpty) _startTimer();
    if (mounted) setState(() {});
  }

  String _fmt(DateTime d) {
    final t = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return faDigits('${jalaliText(isoOf(d))} $t');
  }

  void _startTimer() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => _run(silent: true));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  (String, int)? _parsePeer() {
    final t = enDigits(peer.text.trim());
    if (t.isEmpty) return null;
    final parts = t.split(':');
    final port = parts.length > 1 ? int.tryParse(parts[1]) : defaultSyncPort;
    if (port == null) return null;
    return (parts[0], port);
  }

  Future<void> _run({bool silent = false}) async {
    final p = _parsePeer();
    if (p == null) {
      if (!silent) toast(context, 'آدرس دستگاه مقابل را وارد کنید.');
      return;
    }
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.repo.store.setMeta('peer', peer.text.trim());
      final r = await sync.syncWith(widget.repo, p.$1, port: p.$2);
      status = 'موفق • ارسال ${faDigits('${r.sent}')} / دریافت ${faDigits('${r.received}')} • ${_fmt(DateTime.now())}';
    } catch (e) {
      status = 'ناموفق: $e${e is SyncException && e.message.contains('وجود ندارد') ? '\nدکمهٔ «اتصال شرکت‌ها» را بزنید.' : ''}';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }


  /// Lists the companies of the other device and lets the user copy one here or
  /// declare that one of them is the same as the active company.
  Future<void> _link() async {
    final p = _parsePeer();
    if (p == null) {
      toast(context, 'آدرس دستگاه مقابل را وارد کنید.');
      return;
    }
    List<(String, String)> theirs;
    try {
      theirs = await sync.fetchCompanies(p.$1, port: p.$2);
    } catch (e) {
      if (mounted) toast(context, '$e');
      return;
    }
    if (!mounted) return;
    final mgr = widget.companies;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: const Text('شرکت‌های دستگاه مقابل'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('شرکت فعال این دستگاه: «${mgr.activeInfo.name}»', style: Theme.of(dc).textTheme.titleSmall),
                const SizedBox(height: 10),
                if (theirs.isEmpty) const Text('دستگاه مقابل شرکتی ندارد.'),
                for (final (id, name) in theirs)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        if (mgr.companies.any((c) => c.id == id))
                          Text(id == mgr.activeId ? 'همین شرکتِ فعال است؛ آمادهٔ همگام‌سازی.' : 'این شرکت روی این دستگاه هم هست (با همین شناسه).',
                              style: Theme.of(dc).textTheme.bodySmall)
                        else
                          Wrap(spacing: 8, runSpacing: 6, children: [
                            FilledButton.tonal(
                              onPressed: () async {
                                Navigator.pop(dc);
                                await mgr.create(name, seed: false, activate: true, id: id);
                                if (mounted) toast(context, 'شرکت «$name» ساخته شد. «همگام‌سازی الان» را بزنید.');
                              },
                              child: const Text('دریافت به‌عنوان شرکت جدید'),
                            ),
                            OutlinedButton(
                              onPressed: () async {
                                if (!await confirm(dc, 'شرکت فعال این دستگاه («${mgr.activeInfo.name}») همان شرکت «$name» دستگاه مقابل در نظر گرفته شود؟ اطلاعات دو طرف در همگام‌سازی بعدی ادغام می‌شود.')) return;
                                final ok = await mgr.adoptId(mgr.activeId, id);
                                if (dc.mounted) Navigator.pop(dc);
                                if (mounted) toast(context, ok ? 'شناسهٔ شرکت یکی شد. «همگام‌سازی الان» را بزنید.' : 'این شناسه قبلاً در این دستگاه هست.');
                              },
                              child: const Text('همان شرکت فعلی است'),
                            ),
                          ]),
                      ]),
                    ),
                  ),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dc), child: const Text('بستن'))],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Constrained(maxWidth: 760, child: ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('این دستگاه', style: Theme.of(context).textTheme.titleMedium),
            gap(8),
            Text(sync.serverRunning
                ? 'آمادهٔ اتصال از دستگاه دیگر روی درگاه ${faDigits('${sync.port}')}'
                : 'سرویس اتصال فعال نیست (ممکن است درگاه اشغال باشد).'),
            for (final ip in ips) SelectableText('$ip:${sync.port ?? defaultSyncPort}', textDirection: TextDirection.ltr),
            if (ips.isEmpty) const Text('به هیچ شبکه‌ای وصل نیستید.'),
            gap(),
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'کد اتصال (در هر دو دستگاه یکسان باشد)', border: OutlineInputBorder()),
              onChanged: (v) => sync.setPairCode(enDigits(v)),
            ),
          ]),
        ),
      ),
      gap(),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('دستگاه مقابل', style: Theme.of(context).textTheme.titleMedium),
            gap(8),
            TextField(
              controller: peer,
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                  labelText: 'آدرس، مثلاً 192.168.1.20:8765', border: OutlineInputBorder()),
            ),
            gap(),
            FilledButton.icon(
              onPressed: busy ? null : _run,
              icon: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              label: const Text('همگام‌سازی الان'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('همگام‌سازی خودکار هر ۳۰ ثانیه'),
              value: auto,
              onChanged: (v) async {
                await widget.repo.store.setMeta('auto_sync', v ? '1' : '0');
                if (v) { _startTimer(); } else { timer?.cancel(); }
                setState(() => auto = v);
              },
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: busy ? null : _link,
              icon: const Icon(Icons.link),
              label: const Text('اتصال شرکت‌ها'),
            ),
            if (status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(status!)),
          ]),
        ),
      ),
      gap(),
      const Text(
        'هر دو دستگاه باید به یک شبکه (Wi‑Fi) وصل باشند. در ویندوز اگر پیام فایروال آمد، «Allow» را بزنید. '
        'اگر دو دستگاه هم‌زمان یک مورد را ویرایش کنند، آخرین ویرایش می‌ماند.',
      ),
    ]));
  }
}
