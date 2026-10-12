import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'app_theme.dart';
import '../print/print_settings.dart';
import '../print/report_doc.dart';
import 'common.dart';
import 'print_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repo, required this.theme});
  final Repo repo;
  final AppTheme theme;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Map<String, TextEditingController> ctl = {
    for (final k in ['business_name', 'business_phone', 'business_address', 'business_tax_id', 'invoice_footer', 'default_tax'])
      k: TextEditingController(text: widget.repo.setting(k)),
  };
  String currency = 'تومان';

  Repo get repo => widget.repo;
  AppTheme get theme => widget.theme;

  @override
  void initState() {
    super.initState();
    currency = repo.setting('currency', 'تومان');
  }

  Future<void> _saveBusiness() async {
    for (final e in ctl.entries) {
      final v = e.key == 'default_tax' ? '${parseAmount(e.value.text).clamp(0, 100)}' : e.value.text.trim();
      if (repo.setting(e.key) != v) await repo.setSetting(e.key, v);
    }
    if (mounted) toast(context, 'اطلاعات ذخیره شد.');
  }

  Future<void> _backup() async {
    final json = await repo.exportJson();
    final name = 'accounting-backup-${todayIso()}.json';
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'ذخیرهٔ فایل پشتیبان',
        fileName: name,
        bytes: utf8.encode(json),
      );
      if (!mounted) return;
      toast(context, path == null && !Platform.isAndroid ? 'ذخیره لغو شد.' : 'فایل پشتیبان ذخیره شد.');
    } catch (e) {
      if (mounted) toast(context, 'ذخیره ممکن نشد: $e');
    }
  }

  Future<void> _restore() async {
    try {
      final f = await FilePicker.pickFile(dialogTitle: 'انتخاب فایل پشتیبان');
      if (f == null) return;
      final bytes = await f.readAsBytes();
      final n = await repo.importJson(utf8.decode(bytes));
      if (mounted) toast(context, 'بازیابی انجام شد (${faDigits('$n')} مورد).');
    } on FormatException catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, 'بازیابی ممکن نشد: $e');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: theme,
        builder: (context, _) => Constrained(
          maxWidth: 760,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            Section(title: 'ظاهر برنامه', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('حالت نمایش'),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('روشن')),
                  ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('تیره')),
                  ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('خودکار')),
                ],
                selected: {theme.mode},
                onSelectionChanged: (s) => theme.setMode(s.first),
              ),
              gap(20),
              const Text('رنگ اصلی'),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final (name, color) in themePresets)
                  Tooltip(
                    message: name,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => theme.setSeed(color),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: theme.seed.toARGB32() == color.toARGB32() ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                              width: 3),
                        ),
                        child: theme.seed.toARGB32() == color.toARGB32() ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                      ),
                    ),
                  ),
              ]),
              gap(12),
              Row(children: [
                const Text('رنگ دلخواه'),
                Expanded(
                  child: Slider(
                    value: HSVColor.fromColor(theme.seed).hue,
                    min: 0,
                    max: 359,
                    onChanged: (h) => theme.setSeed(HSVColor.fromAHSV(1, h, 0.75, 0.75).toColor()),
                  ),
                ),
              ]),
              gap(8),
              Row(children: [
                const Text('اندازهٔ نوشته'),
                Expanded(
                  child: Slider(
                    value: theme.fontScale,
                    min: 0.85,
                    max: 1.35,
                    divisions: 10,
                    label: faDigits('${(theme.fontScale * 100).round()}٪'),
                    onChanged: theme.setFontScale,
                  ),
                ),
                Text(faDigits('${(theme.fontScale * 100).round()}٪')),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('نمایش فشرده'),
                subtitle: const Text('فاصله‌ها کمتر می‌شود و اطلاعات بیشتری دیده می‌شود.'),
                value: theme.compact,
                onChanged: theme.setCompact,
              ),
            ])),
            gap(16),
            Section(title: 'اطلاعات کسب‌وکار (روی فاکتور چاپ می‌شود)', child: Column(children: [
              TextField(controller: ctl['business_name'], decoration: const InputDecoration(labelText: 'نام فروشگاه / شرکت')),
              gap(),
              Row(children: [
                Expanded(child: TextField(controller: ctl['business_phone'], keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'تلفن'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: ctl['business_tax_id'], decoration: const InputDecoration(labelText: 'شناسهٔ اقتصادی / کد ملی'))),
              ]),
              gap(),
              TextField(controller: ctl['business_address'], decoration: const InputDecoration(labelText: 'نشانی')),
              gap(),
              TextField(controller: ctl['invoice_footer'], decoration: const InputDecoration(labelText: 'متن پایین فاکتور (مثلاً شرایط ضمانت)')),
              gap(),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: ctl['default_tax'],
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'مالیات پیش‌فرض فاکتور (درصد)', helperText: '۰ یعنی بدون مالیات'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: currency,
                    decoration: const InputDecoration(labelText: 'واحد پول'),
                    items: const [
                      DropdownMenuItem(value: 'تومان', child: Text('تومان')),
                      DropdownMenuItem(value: 'ریال', child: Text('ریال')),
                    ],
                    onChanged: (v) async {
                      currency = v!;
                      await repo.setSetting('currency', v);
                    },
                  ),
                ),
              ]),
              gap(16),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.icon(onPressed: _saveBusiness, icon: const Icon(Icons.save_outlined), label: const Text('ذخیره')),
              ),
              const SizedBox(height: 4),
              Text('این اطلاعات با دستگاه دیگر هم همگام می‌شود.', style: Theme.of(context).textTheme.bodySmall),
            ])),
            gap(16),
            ListenableBuilder(
              listenable: repo,
              builder: (context, _) {
                final ps = repo.printSettings;
                return Section(title: 'تنظیمات چاپ', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('اندازهٔ کاغذ'),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: [for (final e in PrintSettings.papers.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                    selected: {ps.paper},
                    onSelectionChanged: (v) => repo.setPrint(ps.copyWith(paper: v.first)),
                  ),
                  gap(16),
                  const Text('جهت صفحه'),
                  const SizedBox(height: 8),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, icon: Icon(Icons.crop_portrait), label: Text('عمودی')),
                      ButtonSegment(value: true, icon: Icon(Icons.crop_landscape), label: Text('افقی')),
                    ],
                    selected: {ps.landscape},
                    onSelectionChanged: (v) => repo.setPrint(ps.copyWith(landscape: v.first)),
                  ),
                  gap(8),
                  Row(children: [
                    const Text('حاشیه'),
                    Expanded(
                      child: Slider(
                        value: ps.marginMm,
                        min: 0,
                        max: 30,
                        divisions: 30,
                        label: '${faDigits('${ps.marginMm.round()}')} میلی‌متر',
                        onChanged: (v) => repo.setPrint(ps.copyWith(marginMm: v)),
                      ),
                    ),
                    SizedBox(width: 70, child: Text('${faDigits('${ps.marginMm.round()}')} mm', textDirection: TextDirection.ltr)),
                  ]),
                  Row(children: [
                    const Text('اندازهٔ نوشته'),
                    Expanded(
                      child: Slider(
                        value: ps.fontScale,
                        min: 0.7,
                        max: 1.4,
                        divisions: 14,
                        label: faDigits('${(ps.fontScale * 100).round()}٪'),
                        onChanged: (v) => repo.setPrint(ps.copyWith(fontScale: double.parse(v.toStringAsFixed(2)))),
                      ),
                    ),
                    SizedBox(width: 70, child: Text(faDigits('${(ps.fontScale * 100).round()}٪'))),
                  ]),
                  gap(8),
                  const Text('پهنای رسید حرارتی'),
                  const SizedBox(height: 8),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 58, label: Text('۵۸ میلی‌متر')),
                      ButtonSegment(value: 80, label: Text('۸۰ میلی‌متر')),
                    ],
                    selected: {ps.rollWidthMm},
                    onSelectionChanged: (v) => repo.setPrint(ps.copyWith(rollWidthMm: v.first)),
                  ),
                  gap(16),
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('چاپ صفحهٔ آزمایشی'),
                      onPressed: () => printReport(
                        context,
                        repo,
                        ReportDoc(
                          title: 'صفحهٔ آزمایشی چاپ',
                          subtitle: 'کاغذ ${PrintSettings.papers[ps.paper]} • ${ps.landscape ? 'افقی' : 'عمودی'} • حاشیه ${faDigits('${ps.marginMm.round()}')} میلی‌متر',
                          summary: [('نمونه مبلغ', moneyC(1234567)), ('تاریخ امروز', jalaliText(todayIso()))],
                          tables: [
                            ReportTable(
                              headers: const ['ردیف', 'شرح', 'تعداد', 'مبلغ'],
                              cols: const [Col.center, Col.text, Col.number, Col.number],
                              flex: const [0.7, 4, 1.2, 2],
                              rows: [for (var i = 1; i <= 8; i++) [faDigits('$i'), 'نمونهٔ ردیف شمارهٔ ${faDigits('$i')}', faDigits('$i'), money(i * 125000)]],
                              totals: ['', 'جمع', faDigits('36'), money(36 * 125000)],
                            ),
                          ],
                          footnote: 'اگر لبه‌های جدول بریده شد، حاشیه را بیشتر کنید.',
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'اندازهٔ کاغذ و جهت را هنگام چاپ هم می‌توانید عوض کنید. چاپگر و تعداد نسخه را از پنجرهٔ چاپ سیستم انتخاب کنید. '
                    'این تنظیمات فقط روی همین دستگاه ذخیره می‌شود.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ]));
              },
            ),
            gap(16),
            Section(title: 'پشتیبان‌گیری', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('از همهٔ اطلاعات یک فایل پشتیبان بگیرید و در جای امن نگه دارید. بازیابی، اطلاعات فایل را با اطلاعات فعلی ادغام می‌کند (مورد جدیدتر می‌ماند).'),
              gap(),
              Wrap(spacing: 10, runSpacing: 10, children: [
                FilledButton.icon(onPressed: _backup, icon: const Icon(Icons.download_outlined), label: const Text('گرفتن پشتیبان')),
                OutlinedButton.icon(onPressed: _restore, icon: const Icon(Icons.upload_file_outlined), label: const Text('بازیابی از فایل')),
              ]),
            ])),
            gap(16),
            const Section(title: 'دربارهٔ برنامه', child: Text('حسابداری ساده • نسخهٔ ۱٫۳\nفونت وزیرمتن (مجوز OFL)')),
          ]),
        ),
      );
}
