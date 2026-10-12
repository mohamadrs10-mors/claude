import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/repo.dart';
import '../print/pdf_docs.dart';
import '../print/print_settings.dart';
import '../print/report_doc.dart';
import '../util/format.dart';
import 'common.dart';

/// Small "print" button used on report screens.
class PrintButton extends StatelessWidget {
  const PrintButton({super.key, required this.repo, required this.doc, this.label = 'چاپ'});
  final Repo repo;

  /// Called when the button is pressed, so the printout reflects what is on screen now.
  final ReportDoc Function() doc;
  final String label;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: () => printReport(context, repo, doc()),
        icon: const Icon(Icons.print_outlined),
        label: Text(label),
      );
}

Future<void> printReport(BuildContext context, Repo repo, ReportDoc doc) => showPrintDialog(
      context,
      repo,
      title: doc.title,
      filename: '${doc.title}.pdf',
      build: (s, f) => PdfDocs(repo, settings: s).report(doc, format: f),
    );

/// Asks for the paper (A4/A5, portrait/landscape) and prints or saves the PDF.
/// The choice is remembered as the new default; margins, text size and the
/// roll width are in Settings.
Future<void> showPrintDialog(
  BuildContext context,
  Repo repo, {
  required String title,
  required String filename,
  required Future<Uint8List> Function(PrintSettings settings, PdfPageFormat format) build,
  Widget? options,
}) async {
  var cur = repo.printSettings;
  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: Text('چاپ: $title', maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (options != null) ...[options, const Divider(height: 28)],
              const Text('اندازهٔ کاغذ'),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [for (final e in PrintSettings.papers.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                selected: {cur.paper},
                onSelectionChanged: (v) => set(() => cur = cur.copyWith(paper: v.first)),
              ),
              const SizedBox(height: 14),
              const Text('جهت صفحه'),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.crop_portrait), label: Text('عمودی')),
                  ButtonSegment(value: true, icon: Icon(Icons.crop_landscape), label: Text('افقی')),
                ],
                selected: {cur.landscape},
                onSelectionChanged: (v) => set(() => cur = cur.copyWith(landscape: v.first)),
              ),
              const SizedBox(height: 10),
              Text('حاشیه و اندازهٔ نوشته را از «تنظیمات ← تنظیمات چاپ» تغییر دهید.', style: Theme.of(dc).textTheme.bodySmall),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          OutlinedButton.icon(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('ذخیره / اشتراک PDF'),
            onPressed: () async {
              final chosen = cur;
              Navigator.pop(dc);
              await repo.setPrint(chosen);
              try {
                await PdfDocs.share(await build(chosen, chosen.format), filename);
              } catch (e) {
                if (context.mounted) toast(context, 'ذخیره ممکن نشد: $e');
              }
            },
          ),
          FilledButton.icon(
            icon: const Icon(Icons.print_outlined),
            label: const Text('چاپ'),
            onPressed: () async {
              final chosen = cur;
              Navigator.pop(dc);
              await repo.setPrint(chosen);
              try {
                await PdfDocs.print((f) => build(chosen, f), title, chosen);
              } catch (e) {
                if (context.mounted) toast(context, 'چاپ ممکن نشد: $e');
              }
            },
          ),
        ],
      ),
    ),
  );
}

enum StatementPeriod { all, year, month, custom }

/// The period chosen in the statement print dialog.
class StatementRange {
  StatementPeriod period = StatementPeriod.all;
  late int year = Jalali.now().year, month = Jalali.now().month;
  String fromIso = todayIso(), toIso = todayIso();

  (String?, String?) get range => switch (period) {
        StatementPeriod.all => (null, null),
        StatementPeriod.year => jalaliYearRange(year),
        StatementPeriod.month => jalaliMonthRange(year, month),
        StatementPeriod.custom => (fromIso, isoOf(DateTime.parse(toIso).add(const Duration(days: 1)))),
      };

  String get label => switch (period) {
        StatementPeriod.all => 'کل دوران',
        StatementPeriod.year => 'سال ${faDigits('$year')}',
        StatementPeriod.month => '${monthNames[month - 1]} ${faDigits('$year')}',
        StatementPeriod.custom => 'از ${jalaliText(fromIso)} تا ${jalaliText(toIso)}',
      };
}

class _RangePicker extends StatefulWidget {
  const _RangePicker(this.r);
  final StatementRange r;
  @override
  State<_RangePicker> createState() => _RangePickerState();
}

class _RangePickerState extends State<_RangePicker> {
  StatementRange get r => widget.r;

  void _shift(int d) => setState(() {
        if (r.period == StatementPeriod.year) {
          r.year += d;
        } else {
          r.month += d;
          if (r.month > 12) { r.month = 1; r.year++; }
          if (r.month < 1) { r.month = 12; r.year--; }
        }
      });

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('بازهٔ صورت‌حساب'),
        const SizedBox(height: 8),
        SegmentedButton<StatementPeriod>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: StatementPeriod.all, label: Text('کل')),
            ButtonSegment(value: StatementPeriod.year, label: Text('سال')),
            ButtonSegment(value: StatementPeriod.month, label: Text('ماه')),
            ButtonSegment(value: StatementPeriod.custom, label: Text('دلخواه')),
          ],
          selected: {r.period},
          onSelectionChanged: (v) => setState(() => r.period = v.first),
        ),
        if (r.period == StatementPeriod.year || r.period == StatementPeriod.month)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_right)),
            SizedBox(width: 140, child: Center(child: Text(r.label, style: Theme.of(context).textTheme.titleSmall))),
            IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_left)),
          ]),
        if (r.period == StatementPeriod.custom) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: JalaliDateField(iso: r.fromIso, label: 'از تاریخ', onChanged: (v) => setState(() => r.fromIso = v))),
            const SizedBox(width: 10),
            Expanded(child: JalaliDateField(iso: r.toIso, label: 'تا تاریخ', onChanged: (v) => setState(() => r.toIso = v))),
          ]),
        ],
        if (r.period != StatementPeriod.all)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('مانده پیش از این بازه به‌عنوان «مانده از قبل» در صورت‌حساب می‌آید.', style: Theme.of(context).textTheme.bodySmall),
          ),
      ]);
}

/// Print dialog of a party statement with a choice of period.
Future<void> showStatementPrint(BuildContext context, Repo repo, Party party) {
  final range = StatementRange();
  return showPrintDialog(
    context,
    repo,
    title: 'صورت‌حساب ${party.name}',
    filename: 'صورت‌حساب ${party.name}.pdf',
    options: _RangePicker(range),
    build: (s, f) {
      final (from, to) = range.range;
      return PdfDocs(repo, settings: s).statement(party, from: from, toExclusive: to, periodLabel: range.label, format: f);
    },
  );
}
