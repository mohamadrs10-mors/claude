import 'package:flutter/material.dart';

import '../data/company_manager.dart';
import '../util/format.dart';
import 'common.dart';

/// Manage the companies (مجموعه‌ها) kept in this app: switch, add, rename, delete.
class CompaniesPage extends StatelessWidget {
  const CompaniesPage({super.key, required this.companies, required this.onOpenSync});
  final CompanyManager companies;

  /// Opens the synchronisation screen (to copy a company from another device).
  final VoidCallback onOpenSync;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: companies,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          return Constrained(
            maxWidth: 760,
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Text(
                'هر شرکت (مجموعه) پایگاه‌دادهٔ جداگانه دارد؛ حساب‌ها، کالاها، اشخاص و فاکتورهای شرکت‌ها هیچ‌وقت با هم قاطی نمی‌شود. '
                'در هر لحظه یکی از آن‌ها فعال است و همهٔ صفحه‌ها همان را نشان می‌دهند.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  for (var i = 0; i < companies.companies.length; i++) ...[
                    if (i > 0) const Divider(),
                    Builder(builder: (context) {
                      final c = companies.companies[i];
                      final active = c.id == companies.activeId;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: active ? scheme.primary : scheme.primaryContainer,
                          foregroundColor: active ? scheme.onPrimary : scheme.onPrimaryContainer,
                          child: Text(c.name.characters.first),
                        ),
                        title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(active ? 'شرکت فعال' : 'ایجاد: ${_created(c)}'),
                        onTap: active ? null : () => _switch(context, c),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (!active) TextButton(onPressed: () => _switch(context, c), child: const Text('باز کردن')),
                          IconButton(tooltip: 'تغییر نام', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context, c)),
                          IconButton(
                            tooltip: 'حذف',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: companies.companies.length <= 1 ? null : () => _delete(context, c),
                          ),
                        ]),
                      );
                    }),
                  ],
                ]),
              ),
              const SizedBox(height: 16),
              Wrap(spacing: 10, runSpacing: 10, children: [
                FilledButton.icon(onPressed: () => addCompanyDialog(context, companies), icon: const Icon(Icons.add_business_outlined), label: const Text('شرکت جدید')),
                OutlinedButton.icon(onPressed: onOpenSync, icon: const Icon(Icons.devices_outlined), label: const Text('دریافت شرکت از دستگاه دیگر')),
              ]),
              const SizedBox(height: 16),
              Text(
                'نکته: برای همگام‌سازی یک شرکت بین ویندوز و اندروید، آن شرکت باید روی هر دو دستگاه یک «شناسه» داشته باشد. '
                'از بخش «همگام‌سازی ← اتصال شرکت‌ها» شرکتی را که روی دستگاه دیگر هست دریافت یا با شرکت فعلی یکی کنید.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]),
          );
        },
      );

  String _created(CompanyInfo c) {
    final d = DateTime.tryParse(c.createdAt);
    return d == null ? '—' : jalaliText(isoOf(d));
  }

  Future<void> _switch(BuildContext context, CompanyInfo c) async {
    await companies.switchTo(c.id);
    if (context.mounted) toast(context, 'شرکت «${c.name}» باز شد.');
  }

  Future<void> _rename(BuildContext context, CompanyInfo c) async {
    final name = TextEditingController(text: c.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('تغییر نام شرکت'),
        content: TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'نام شرکت')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('ذخیره')),
        ],
      ),
    );
    if (ok == true) await companies.rename(c.id, name.text);
  }

  Future<void> _delete(BuildContext context, CompanyInfo c) async {
    final confirmName = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text('حذف شرکت «${c.name}»'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('همهٔ اطلاعات این شرکت روی این دستگاه برای همیشه پاک می‌شود و برگشت‌پذیر نیست. (دستگاه دیگر اگر همین شرکت را داشته باشد دست‌نخورده می‌ماند.)'),
            const SizedBox(height: 12),
            TextField(
              controller: confirmName,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(labelText: 'برای تأیید نام شرکت را بنویسید', helperText: c.name),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('انصراف')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(dc).colorScheme.error),
              onPressed: confirmName.text.trim() == c.name ? () => Navigator.pop(dc, true) : null,
              child: const Text('حذف همیشگی'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await companies.delete(c.id);
      } on StateError catch (e) {
        if (context.mounted) toast(context, e.message);
      }
    }
  }
}

/// Asks for a name and creates a company (optionally with a cash account and
/// the usual categories), then opens it.
Future<void> addCompanyDialog(BuildContext context, CompanyManager companies) async {
  final name = TextEditingController();
  var seed = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: const Text('شرکت جدید'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'نام شرکت یا مجموعه')),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: seed,
            onChanged: (v) => set(() => seed = v ?? true),
            title: const Text('حساب صندوق و دسته‌بندی‌های رایج را بساز'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('ایجاد و باز کردن')),
        ],
      ),
    ),
  );
  if (ok == true) await companies.create(name.text, seed: seed, activate: true);
}
