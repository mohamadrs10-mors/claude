import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart' show PdfPreview, LayoutCallback;
import 'package:shamsi_date/shamsi_date.dart';

import '../data/repo.dart';
import '../print/delivery_doc.dart';
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

/// Opens the print preview: the page as it will come out of the printer, with
/// the paper (A4/A5, portrait/landscape) and the report's own options beside
/// it. Nothing is printed until "چاپ" is pressed there; every change redraws
/// the preview. The paper choice is remembered; margins, text size and the
/// roll width are in Settings.
///
/// [options] builds extra controls (a period, a switch...) and gets a callback
/// to call after a change so the preview is drawn again. With [roll] the page
/// is a thermal roll whose width comes from Settings.
Future<void> showPrintDialog(
  BuildContext context,
  Repo repo, {
  required String title,
  required String filename,
  required Future<Uint8List> Function(PrintSettings settings, PdfPageFormat format) build,
  Widget Function(BuildContext context, VoidCallback refresh)? options,
  bool roll = false,
}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PrintPreviewPage(repo: repo, title: title, filename: filename, build: build, options: options, roll: roll),
    ));

/// Draws the preview of a PDF. Replaceable in tests, where there is no PDF rasteriser.
typedef PreviewBuilder = Widget Function(Key key, LayoutCallback build, PdfPageFormat initialFormat);

/// Tests set this to draw a stand-in for the PDF pages (there is no PDF rasteriser there).
@visibleForTesting
PreviewBuilder? printPreviewBuilderOverride;

class PrintPreviewPage extends StatefulWidget {
  const PrintPreviewPage({
    super.key,
    required this.repo,
    required this.title,
    required this.filename,
    required this.build,
    this.options,
    this.roll = false,
    this.previewBuilder,
  });
  final Repo repo;
  final String title, filename;
  final Future<Uint8List> Function(PrintSettings settings, PdfPageFormat format) build;
  final Widget Function(BuildContext context, VoidCallback refresh)? options;
  final bool roll;
  final PreviewBuilder? previewBuilder;

  @override
  State<PrintPreviewPage> createState() => _PrintPreviewPageState();
}

class _PrintPreviewPageState extends State<PrintPreviewPage> {
  late PrintSettings cur = widget.repo.printSettings;
  int version = 0;

  void _refresh() => setState(() => version++);

  void _change(PrintSettings next) {
    cur = next;
    widget.repo.setPrint(next);
    _refresh();
  }

  PdfPageFormat get _format => widget.roll
      ? PdfPageFormat(cur.rollWidthMm * PdfPageFormat.mm, 200 * PdfPageFormat.mm, marginAll: 4 * PdfPageFormat.mm)
      : cur.format;

  Future<void> _print() async {
    try {
      if (widget.roll) {
        await PdfDocs.printRoll(await widget.build(cur, _format), widget.title, cur);
      } else {
        await PdfDocs.print((f) => widget.build(cur, f), widget.title, cur);
      }
    } catch (e) {
      if (mounted) toast(context, 'چاپ ممکن نشد: $e');
    }
  }

  Future<void> _share() async {
    try {
      await PdfDocs.share(await widget.build(cur, _format), widget.filename);
    } catch (e) {
      if (mounted) toast(context, 'ذخیره ممکن نشد: $e');
    }
  }

  Widget _controls(BuildContext c) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (widget.options != null) ...[widget.options!(c, _refresh), const Divider(height: 24)],
        if (!widget.roll) ...[
          const Text('اندازهٔ کاغذ'),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [for (final e in PrintSettings.papers.entries) ButtonSegment(value: e.key, label: Text(e.value))],
            selected: {cur.paper},
            onSelectionChanged: (v) => _change(cur.copyWith(paper: v.first)),
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
            onSelectionChanged: (v) => _change(cur.copyWith(landscape: v.first)),
          ),
          const SizedBox(height: 10),
        ] else
          Text('رسید حرارتی ${faDigits('${cur.rollWidthMm}')} میلی‌متری؛ پهنا را از تنظیمات چاپ عوض کنید.', style: Theme.of(c).textTheme.bodySmall),
        Text('حاشیه و اندازهٔ نوشته را از «تنظیمات ← تنظیمات چاپ» تغییر دهید.', style: Theme.of(c).textTheme.bodySmall),
      ]);

  Widget _preview() {
    final key = ValueKey('preview-$version-${cur.paper}-${cur.landscape}');
    Future<Uint8List> render(PdfPageFormat f) => widget.build(cur, f);
    final custom = widget.previewBuilder ?? printPreviewBuilderOverride;
    if (custom != null) return custom(key, render, _format);
    return PdfPreview(
      key: key,
      build: render,
      initialPageFormat: _format,
      useActions: false,
      canChangePageFormat: false,
      canChangeOrientation: false,
      canDebug: false,
      allowPrinting: false,
      allowSharing: false,
      maxPageWidth: 760,
      pdfFileName: widget.filename,
      onError: (c, e) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('پیش‌نمایش ساخته نشد: $e', textAlign: TextAlign.center))),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('پیش‌نمایش چاپ: ${widget.title}', maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: LayoutBuilder(
          builder: (c, box) {
            final wide = box.maxWidth >= 860;
            if (wide) {
              return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(width: 320, child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: _controls(c))),
                const VerticalDivider(width: 1),
                Expanded(child: _preview()),
              ]);
            }
            return Column(children: [
              ExpansionTile(
                leading: const Icon(Icons.tune),
                title: const Text('تنظیمات چاپ'),
                subtitle: Text(widget.roll ? 'رسید حرارتی' : '${PrintSettings.papers[cur.paper]} • ${cur.landscape ? 'افقی' : 'عمودی'}'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [_controls(c)],
              ),
              const Divider(height: 1),
              Expanded(child: _preview()),
            ]);
          },
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('ذخیره / اشتراک PDF'),
                  onPressed: _share,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('چاپ'),
                  onPressed: _print,
                ),
              ),
            ]),
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
  const _RangePicker(this.r, this.onChanged);
  final StatementRange r;
  final VoidCallback onChanged;
  @override
  State<_RangePicker> createState() => _RangePickerState();
}

class _RangePickerState extends State<_RangePicker> {
  StatementRange get r => widget.r;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.onChanged(); // the statement is drawn again for the new period
  }

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
    options: (c, refresh) => _RangePicker(range, refresh),
    build: (s, f) {
      final (from, to) = range.range;
      return PdfDocs(repo, settings: s).statement(party, from: from, toExclusive: to, periodLabel: range.label, format: f);
    },
  );
}

/// Prints a delivery receipt (no prices) with an optional stamp and signature
/// area for the deliverer and the receiver. The choice is remembered.
Future<void> printDelivery(BuildContext context, Repo repo, DeliveryDoc doc) {
  var sign = repo.setting('delivery_sign', '1') == '1';
  return showPrintDialog(
    context,
    repo,
    title: 'رسید تحویل ${faDigits(doc.number)}',
    filename: 'delivery-${doc.number}.pdf',
    build: (s, f) => PdfDocs(repo, settings: s).delivery(doc, signatures: sign, format: f),
    options: (c, refresh) => StatefulBuilder(
      builder: (c, set) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('محل مهر و امضای تحویل‌دهنده و تحویل‌گیرنده'),
        value: sign,
        onChanged: (v) {
          set(() => sign = v);
          repo.setSetting('delivery_sign', v ? '1' : '0');
          refresh();
        },
      ),
    ),
  );
}
