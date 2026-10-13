import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/app_lock.dart';
import '../data/backup_service.dart';
import '../data/csv.dart';
import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'recovery_dialogs.dart';

/// Logo of the business, printed on invoices and reports. Stored as a synced
/// setting (base64), so every device prints the same header.
class LogoSection extends StatelessWidget {
  const LogoSection({super.key, required this.repo});
  final Repo repo;

  static const maxBytes = 400 * 1024;

  /// PNG or JPEG signature.
  static bool isImage(Uint8List b) =>
      (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) || (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF);

  Future<void> _pick(BuildContext context) async {
    try {
      final f = await FilePicker.pickFile(dialogTitle: 'انتخاب لوگو', type: FileType.image);
      if (f == null) return;
      final bytes = await f.readAsBytes();
      if (!context.mounted) return;
      if (!isImage(bytes)) return toast(context, 'فقط تصویر PNG یا JPG پذیرفته می‌شود.');
      if (bytes.length > maxBytes) return toast(context, 'حجم تصویر باید کمتر از ۴۰۰ کیلوبایت باشد.');
      await repo.setSetting('business_logo', base64Encode(bytes));
    } catch (e) {
      if (context.mounted) toast(context, 'انتخاب تصویر ممکن نشد: $e');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repo,
        builder: (context, _) {
          final b64 = repo.setting('business_logo');
          Uint8List? bytes;
          try {
            if (b64.isNotEmpty) bytes = base64Decode(b64);
          } catch (_) {}
          return Section(
            title: 'لوگوی فروشگاه',
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white,
                ),
                padding: const EdgeInsets.all(6),
                child: bytes == null ? const Icon(Icons.image_outlined, size: 32, color: Colors.grey) : Image.memory(bytes, fit: BoxFit.contain),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('روی فاکتورها و گزارش‌های چاپی کنار نام فروشگاه می‌آید.'),
                  const SizedBox(height: 4),
                  Text('تصویر PNG یا JPG تا ۴۰۰ کیلوبایت', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.tonalIcon(onPressed: () => _pick(context), icon: const Icon(Icons.upload_outlined), label: Text(bytes == null ? 'انتخاب لوگو' : 'تغییر لوگو')),
                    if (bytes != null) TextButton(onPressed: () => repo.setSetting('business_logo', ''), child: const Text('حذف')),
                  ]),
                ]),
              ),
            ]),
          );
        },
      );
}

/// Manual backup/restore plus daily automatic backups.
class BackupSection extends StatefulWidget {
  const BackupSection({super.key, required this.repo, required this.backups});
  final Repo repo;
  final BackupService backups;
  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  Repo get repo => widget.repo;
  BackupService get backups => widget.backups;

  Future<void> _save() async {
    final json = await repo.exportJson();
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'ذخیرهٔ فایل پشتیبان',
        fileName: 'accounting-backup-${todayIso()}.json',
        bytes: utf8.encode(json),
      );
      if (!mounted) return;
      toast(context, path == null && !Platform.isAndroid ? 'ذخیره لغو شد.' : 'فایل پشتیبان ذخیره شد.');
    } catch (e) {
      if (mounted) toast(context, 'ذخیره ممکن نشد: $e');
    }
  }

  Future<void> _restoreText(String text) async {
    try {
      final n = await repo.importJson(text);
      if (mounted) toast(context, 'بازیابی انجام شد (${faDigits('$n')} مورد).');
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'بازیابی ممکن نشد: $e');
    }
  }

  Future<void> _restoreFile() async {
    final f = await FilePicker.pickFile(dialogTitle: 'انتخاب فایل پشتیبان');
    if (f == null) return;
    await _restoreText(utf8.decode(await f.readAsBytes()));
  }

  @override
  Widget build(BuildContext context) => Section(
        title: 'پشتیبان‌گیری',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('پشتیبان همهٔ اطلاعات «همین شرکت» است. بازیابی، اطلاعات فایل را با اطلاعات فعلی ادغام می‌کند (مورد جدیدتر می‌ماند).'),
          gap(),
          Wrap(spacing: 10, runSpacing: 10, children: [
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.download_outlined), label: const Text('گرفتن پشتیبان')),
            OutlinedButton.icon(onPressed: _restoreFile, icon: const Icon(Icons.upload_file_outlined), label: const Text('بازیابی از فایل')),
          ]),
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('پشتیبان‌گیری خودکار روزانه'),
            subtitle: const Text('هر روز یک نسخه از همهٔ شرکت‌ها روی همین دستگاه ذخیره می‌شود.'),
            value: backups.enabled,
            onChanged: (v) async {
              await backups.setEnabled(v);
              setState(() {});
            },
          ),
          Row(children: [
            const Text('تعداد نسخه‌های نگهداری‌شده'),
            const Spacer(),
            DropdownButton<int>(
              value: [7, 14, 30, 60, 90].contains(backups.keep) ? backups.keep : 14,
              items: [for (final n in [7, 14, 30, 60, 90]) DropdownMenuItem(value: n, child: Text(faDigits('$n')))],
              onChanged: (v) async {
                await backups.setKeep(v ?? 14);
                setState(() {});
              },
            ),
          ]),
          gap(8),
          OutlinedButton.icon(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await backups.backupNow(repo.companyId);
              messenger.showSnackBar(const SnackBar(content: Text('نسخهٔ پشتیبان ساخته شد.')));
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.backup_outlined),
            label: const Text('پشتیبان‌گیری همین حالا'),
          ),
          gap(8),
          FutureBuilder<List<BackupFile>>(
            future: backups.list(repo.companyId),
            builder: (c, snap) {
              final list = snap.data ?? [];
              if (list.isEmpty) return Text('هنوز پشتیبان خودکاری ساخته نشده است.', style: Theme.of(c).textTheme.bodySmall);
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('آخرین پشتیبان‌ها', style: Theme.of(c).textTheme.titleSmall),
                for (final b in list.take(5))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history),
                    title: Text('${jalaliText(isoOf(b.modified))} ${faDigits('${b.modified.hour.toString().padLeft(2, '0')}:${b.modified.minute.toString().padLeft(2, '0')}')}'),
                    subtitle: Text('${faDigits('${(b.size / 1024).ceil()}')} کیلوبایت'),
                    trailing: TextButton(
                      onPressed: () async {
                        if (!await confirm(c, 'اطلاعات این نسخه با اطلاعات فعلی ادغام شود؟')) return;
                        await _restoreText(await b.file.readAsString());
                      },
                      child: const Text('بازیابی'),
                    ),
                  ),
                const SizedBox(height: 4),
                SelectableText('پوشه: ${backups.dirFor(repo.companyId).path}', style: Theme.of(c).textTheme.bodySmall, textDirection: TextDirection.ltr),
              ]);
            },
          ),
        ]),
      );
}

/// Export lists to Excel (CSV) and import products and people from it.
class CsvSection extends StatefulWidget {
  const CsvSection({super.key, required this.repo});
  final Repo repo;
  @override
  State<CsvSection> createState() => _CsvSectionState();
}

class _CsvSectionState extends State<CsvSection> {
  String what = 'products';
  Repo get repo => widget.repo;

  static const names = {'products': 'کالاها', 'parties': 'اشخاص', 'transactions': 'تراکنش‌ها', 'invoices': 'فاکتورها'};

  Future<void> _save(String fileName, List<List<String>> rows) async {
    try {
      final path = await FilePicker.saveFile(dialogTitle: 'ذخیرهٔ فایل اکسل', fileName: fileName, bytes: utf8.encode(Csv.encode(rows)));
      if (!mounted) return;
      toast(context, path == null && !Platform.isAndroid ? 'ذخیره لغو شد.' : 'فایل ذخیره شد.');
    } catch (e) {
      if (mounted) toast(context, 'ذخیره ممکن نشد: $e');
    }
  }

  Future<void> _import(bool products) async {
    try {
      final f = await FilePicker.pickFile(dialogTitle: 'انتخاب فایل CSV');
      if (f == null) return;
      final rows = Csv.decode(utf8.decode(await f.readAsBytes(), allowMalformed: true));
      final r = products ? await repo.importProducts(rows) : await repo.importParties(rows);
      if (mounted) {
        toast(context, '${faDigits('${r.added}')} مورد اضافه و ${faDigits('${r.updated}')} مورد به‌روز شد${r.skipped > 0 ? ' (${faDigits('${r.skipped}')} ردیف بدون نام نادیده ماند)' : ''}.');
      }
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'ورود فایل ممکن نشد: $e');
    }
  }

  @override
  Widget build(BuildContext context) => Section(
        title: 'اکسل (فایل CSV)',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('فهرست‌ها را برای کار در اکسل بیرون بدهید، یا کالاها و اشخاص را از یک فایل وارد کنید. فایل CSV را اکسل مستقیم باز می‌کند.'),
          gap(),
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DropdownButton<String>(
              value: what,
              items: [for (final e in names.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => what = v ?? 'products'),
            ),
            FilledButton.icon(
              onPressed: () async => _save('${names[what]}-${todayIso()}.csv', await repo.exportRows(what)),
              icon: const Icon(Icons.table_view_outlined),
              label: const Text('خروجی اکسل'),
            ),
          ]),
          const Divider(height: 28),
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton.icon(onPressed: () => _import(true), icon: const Icon(Icons.inventory_2_outlined), label: const Text('ورود کالاها از فایل')),
            OutlinedButton.icon(onPressed: () => _import(false), icon: const Icon(Icons.people_outline), label: const Text('ورود اشخاص از فایل')),
            TextButton.icon(
              onPressed: () => _save('نمونه-کالاها.csv', [
                ['نام', 'کد', 'واحد', 'قیمت فروش', 'قیمت خرید', 'موجودی اولیه', 'حداقل موجودی', 'توضیحات'],
                ['برنج ایرانی', '1001', 'کیلوگرم', '185000', '150000', '50', '10', ''],
              ]),
              icon: const Icon(Icons.description_outlined),
              label: const Text('نمونهٔ فایل کالاها'),
            ),
            TextButton.icon(
              onPressed: () => _save('نمونه-اشخاص.csv', [
                ['نام', 'تلفن', 'مانده اول دوره', 'یادداشت'],
                ['علی رضایی', '09121234567', '0', ''],
              ]),
              icon: const Icon(Icons.description_outlined),
              label: const Text('نمونهٔ فایل اشخاص'),
            ),
          ]),
          const SizedBox(height: 6),
          Text('کالاها با «کد» (یا نام) و اشخاص با نام تطبیق داده می‌شوند؛ موجودها به‌روز و بقیه اضافه می‌شوند. ستون‌ها فارسی یا انگلیسی پذیرفته است.',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

/// PIN lock of the active company (kept on this device only).
class SecuritySection extends StatefulWidget {
  const SecuritySection({super.key, required this.repo, required this.lock});
  final Repo repo;
  final AppLock lock;
  @override
  State<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<SecuritySection> {
  AppLock get lock => widget.lock;
  String get id => widget.repo.companyId;

  Future<String?> _askPin(String title, {bool confirmField = false}) async {
    final a = TextEditingController(), b = TextEditingController();
    String? err;
    return showDialog<String>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: a, obscureText: true, autofocus: true, keyboardType: TextInputType.number, maxLength: AppLock.maxLength, decoration: InputDecoration(labelText: confirmField ? 'رمز جدید (۴ تا ۸ رقم)' : 'رمز', counterText: '')),
            if (confirmField) ...[
              const SizedBox(height: 8),
              TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: AppLock.maxLength, decoration: const InputDecoration(labelText: 'تکرار رمز', counterText: '')),
            ],
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () {
                final pin = enDigits(a.text.trim());
                if (confirmField) {
                  if (!AppLock.validPin(pin)) return set(() => err = 'رمز باید ۴ تا ۸ رقم باشد.');
                  if (pin != enDigits(b.text.trim())) return set(() => err = 'تکرار رمز یکسان نیست.');
                }
                Navigator.pop(dc, pin);
              },
              child: const Text('تأیید'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _set() async {
    if (lock.hasPin(id)) {
      final old = await _askPin('رمز فعلی');
      if (old == null) return;
      if (!lock.check(id, old)) return mounted ? toast(context, 'رمز فعلی اشتباه است.') : null;
    }
    final pin = await _askPin('رمز جدید', confirmField: true);
    if (pin == null) return;
    final key = await lock.setPin(id, pin);
    if (mounted) await showRecoveryKey(context, key);
  }

  Future<void> _newKey() async {
    final pin = await _askPin('رمز فعلی را برای ساخت کلید جدید وارد کنید');
    if (pin == null) return;
    if (!lock.check(id, pin)) return mounted ? toast(context, 'رمز اشتباه است.') : null;
    final key = await lock.newRecoveryKey(id);
    if (mounted) await showRecoveryKey(context, key, title: 'کلید بازیابی تازه');
  }

  Future<void> _remove() async {
    final pin = await _askPin('رمز فعلی را برای حذف وارد کنید');
    if (pin == null) return;
    if (!lock.check(id, pin)) return mounted ? toast(context, 'رمز اشتباه است.') : null;
    await lock.clearPin(id);
    if (mounted) toast(context, 'رمز حذف شد.');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: lock,
        builder: (context, _) => Section(
          title: 'قفل و امنیت',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lock.hasPin(id) ? 'این شرکت با رمز قفل شده است و هنگام ورود، تعویض شرکت و بعد از چند دقیقه دور بودن از برنامه رمز می‌خواهد.' : 'این شرکت رمز ندارد. هر کس برنامه را باز کند اطلاعات را می‌بیند.'),
            gap(),
            Wrap(spacing: 10, runSpacing: 10, children: [
              FilledButton.tonalIcon(onPressed: _set, icon: const Icon(Icons.password), label: Text(lock.hasPin(id) ? 'تغییر رمز' : 'تعیین رمز')),
              if (lock.hasPin(id)) ...[
                OutlinedButton.icon(onPressed: () => lock.lock(id), icon: const Icon(Icons.lock_outline), label: const Text('قفل کردن الان')),
                OutlinedButton.icon(onPressed: _newKey, icon: const Icon(Icons.key_outlined), label: Text(lock.hasRecoveryKey(id) ? 'کلید بازیابی جدید' : 'ساخت کلید بازیابی')),
                TextButton(onPressed: _remove, child: const Text('حذف رمز')),
              ],
            ]),
            if (lock.hasPin(id)) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(lock.hasRecoveryKey(id) ? Icons.verified_outlined : Icons.warning_amber_rounded, size: 18, color: lock.hasRecoveryKey(id) ? Colors.green : Colors.orange),
                const SizedBox(width: 6),
                Expanded(child: Text(lock.hasRecoveryKey(id) ? 'کلید بازیابی ساخته شده است.' : 'برای این رمز هنوز کلید بازیابی ساخته نشده؛ همین حالا یکی بسازید.')),
              ]),
            ],
            const SizedBox(height: 6),
            Text('رمز فقط روی همین دستگاه و برای همین شرکت ذخیره می‌شود (به‌صورت رمزگذاری‌شده) و همگام نمی‌شود. اگر رمز را فراموش کنید، با «کلید بازیابی» (که هنگام تعیین رمز نشان داده می‌شود) می‌توانید رمز تازه بسازید. رمز اطلاعات را رمزگذاری نمی‌کند و فقط ورود به برنامه را قفل می‌کند.',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}
