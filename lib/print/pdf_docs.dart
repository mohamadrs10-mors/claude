import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/repo.dart';
import '../util/format.dart';

/// Builds printable PDFs (A4 invoice, 80 mm receipt, party statement).
/// Persian shaping and right-to-left layout are done by the pdf package using
/// the embedded Vazirmatn font.
class PdfDocs {
  PdfDocs(this.repo);
  final Repo repo;

  static pw.Font? _regular, _bold;

  Future<pw.ThemeData> _theme() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'));
    return pw.ThemeData.withFont(base: _regular!, bold: _bold!, fontFallback: [_regular!]);
  }

  String get _business => repo.setting('business_name', 'حسابداری ساده');

  static String _qty(double q) => faDigits(q == q.roundToDouble() ? '${q.round()}' : q.toString());

  static final _accent = PdfColor.fromInt(0xFF0F5F58);
  static final _line = PdfColor.fromInt(0xFFD0D7DE);
  static final _soft = PdfColor.fromInt(0xFFF1F5F4);

  /// The pdf package draws the zero-width non-joiner (نیم‌فاصله) as an
  /// overlapping glyph, so it is replaced by a thin space.
  static String _z(String s) => s.replaceAll('\u200c', '\u2009');

  static pw.Widget _text(String s, {pw.TextStyle? style, pw.TextAlign? textAlign}) =>
      pw.Text(_z(s), style: style, textAlign: textAlign);

  /// pw.Table always lays columns out left to right, so rows are written in
  /// reading order and reversed here to get a right-to-left table.
  static pw.TableRow _row(List<pw.Widget> cells, {PdfColor? background}) => pw.TableRow(
        decoration: background == null ? null : pw.BoxDecoration(color: background),
        children: cells.reversed.toList(),
      );

  static Map<int, pw.TableColumnWidth> _widths(List<pw.TableColumnWidth> w) =>
      {for (var i = 0; i < w.length; i++) i: w[w.length - 1 - i]};

  pw.Widget _cell(String t, {bool bold = false, pw.TextAlign align = pw.TextAlign.right, PdfColor? color, double size = 10}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: _text(t,
            textAlign: align,
            style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : null, color: color)),
      );

  /// A4 invoice, or an 80 mm roll receipt when [roll] is true.
  Future<Uint8List> invoice(Invoice inv, List<InvoiceItem> items, Party? party, {bool roll = false}) async {
    final doc = pw.Document(title: '${inv.info.label} ${inv.number}', author: _business);
    final theme = await _theme();
    final info = inv.info;
    final phone = repo.setting('business_phone');
    final address = repo.setting('business_address');
    final footer = repo.setting('invoice_footer');
    final taxId = repo.setting('business_tax_id');
    final cur = currencyLabel;

    final totals = <(String, String, bool)>[
      ('جمع اقلام', money(inv.subtotal), false),
      if (inv.discount > 0) ('تخفیف', money(inv.discount), false),
      if (inv.taxPercent > 0) ('مالیات بر ارزش افزوده (${faDigits('${inv.taxPercent}')}٪)', money(inv.tax), false),
      ('مبلغ نهایی', money(inv.total), true),
      if (inv.paid > 0) (info.paymentKind == 'receipt' ? 'دریافت‌شده' : 'پرداخت‌شده', money(inv.paid), false),
      if (inv.paid > 0) ('مانده', money(inv.remaining), true),
    ];

    if (roll) {
      doc.addPage(pw.Page(
        pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
        textDirection: pw.TextDirection.rtl,
        theme: theme,
        build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          pw.Center(child: _text(_business, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold))),
          if (phone.isNotEmpty) pw.Center(child: _text(faDigits(phone), style: const pw.TextStyle(fontSize: 9))),
          pw.SizedBox(height: 4),
          pw.Divider(thickness: 0.6),
          _text('${info.label} ${faDigits('${inv.number}')}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          _text('تاریخ: ${jalaliText(inv.date)}', style: const pw.TextStyle(fontSize: 9)),
          if (party != null) _text('${info.partyLabel}: ${party.name}', style: const pw.TextStyle(fontSize: 9)),
          pw.Divider(thickness: 0.6),
          for (final it in items)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                _text(it.title, style: const pw.TextStyle(fontSize: 9)),
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  _text('${_qty(it.qty)} × ${money(it.unitPrice)}', style: const pw.TextStyle(fontSize: 8)),
                  _text(money(it.total), style: const pw.TextStyle(fontSize: 9)),
                ]),
              ]),
            ),
          pw.Divider(thickness: 0.6),
          for (final t in totals)
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              _text(t.$1, style: pw.TextStyle(fontSize: t.$3 ? 10 : 9, fontWeight: t.$3 ? pw.FontWeight.bold : null)),
              _text('${t.$2} $cur', style: pw.TextStyle(fontSize: t.$3 ? 10 : 9, fontWeight: t.$3 ? pw.FontWeight.bold : null)),
            ]),
          if (footer.isNotEmpty) ...[
            pw.SizedBox(height: 8),
            pw.Center(child: _text(footer, style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center)),
          ],
        ]),
      ));
      return doc.save();
    }

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      footer: (c) => pw.Align(
        alignment: pw.Alignment.center,
        child: _text('صفحه ${faDigits('${c.pageNumber}')} از ${faDigits('${c.pagesCount}')}',
            style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ),
      build: (c) => [
        // Header: business on the start side, invoice title on the end side.
        pw.Container(
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(color: _accent, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              _text(_business, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
              if (address.isNotEmpty) _text(address, style: const pw.TextStyle(fontSize: 9, color: PdfColors.white)),
              if (phone.isNotEmpty) _text('تلفن: ${faDigits(phone)}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.white)),
              if (taxId.isNotEmpty) _text('شناسه اقتصادی: ${faDigits(taxId)}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.white)),
            ]),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              _text(info.label, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
              _text('شماره: ${faDigits('${inv.number}')}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.white)),
              _text('تاریخ: ${jalaliText(inv.date)}', style: const pw.TextStyle(fontSize: 10, color: PdfColors.white)),
            ]),
          ]),
        ),
        pw.SizedBox(height: 12),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            _text('${info.partyLabel}: ${party?.name ?? '—'}', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
            if ((party?.phone ?? '').isNotEmpty) _text('تلفن: ${faDigits(party!.phone)}', style: const pw.TextStyle(fontSize: 9)),
          ]),
        ),
        pw.SizedBox(height: 12),
        pw.Table(
          border: pw.TableBorder.all(color: _line, width: 0.6),
          columnWidths: _widths(const [
            pw.FixedColumnWidth(36),
            pw.FlexColumnWidth(4),
            pw.FixedColumnWidth(52),
            pw.FlexColumnWidth(1.6),
            pw.FlexColumnWidth(1.8),
          ]),
          children: [
            _row([
              _cell('ردیف', bold: true, align: pw.TextAlign.center),
              _cell('شرح کالا / خدمات', bold: true),
              _cell('تعداد', bold: true, align: pw.TextAlign.center),
              _cell('قیمت واحد', bold: true, align: pw.TextAlign.left),
              _cell('مبلغ', bold: true, align: pw.TextAlign.left),
            ], background: _soft),
            for (var i = 0; i < items.length; i++)
              _row([
                _cell(faDigits('${i + 1}'), align: pw.TextAlign.center),
                _cell(items[i].title),
                _cell(_qty(items[i].qty), align: pw.TextAlign.center),
                _cell(money(items[i].unitPrice), align: pw.TextAlign.left),
                _cell(money(items[i].total), align: pw.TextAlign.left),
              ]),
          ],
        ),
        pw.SizedBox(height: 12),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: inv.note.isEmpty
                ? pw.SizedBox()
                : pw.Container(
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
                    child: _text('توضیحات: ${inv.note}', style: const pw.TextStyle(fontSize: 9)),
                  ),
          ),
          pw.SizedBox(width: 16),
          pw.Container(
            width: 220,
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(children: [
              for (final t in totals)
                pw.Container(
                  color: t.$3 ? _soft : null,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                    _text(t.$1, style: pw.TextStyle(fontSize: 10, fontWeight: t.$3 ? pw.FontWeight.bold : null)),
                    _text('${t.$2} $cur', style: pw.TextStyle(fontSize: 10, fontWeight: t.$3 ? pw.FontWeight.bold : null)),
                  ]),
                ),
            ]),
          ),
        ]),
        pw.SizedBox(height: 40),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
          _text(inv.kind.startsWith('sale') ? 'امضای فروشنده' : 'امضای خریدار', style: const pw.TextStyle(fontSize: 10)),
          _text(inv.kind.startsWith('sale') ? 'امضای خریدار' : 'امضای فروشنده', style: const pw.TextStyle(fontSize: 10)),
        ]),
        if (footer.isNotEmpty) ...[
          pw.SizedBox(height: 24),
          pw.Center(child: _text(footer, style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700))),
        ],
      ],
    ));
    return doc.save();
  }

  /// Chronological statement (invoices and payments) with a running balance.
  Future<Uint8List> statement(Party party) async {
    final invoices = await repo.invoices(partyId: party.id);
    final txs = await repo.transactions(partyId: party.id);
    final rows = <(String, String, String, int)>[]; // date, description, kind, signed amount (+ they owe)
    for (final i in invoices) {
      rows.add((i.date, '${i.info.label} ${faDigits('${i.number}')}', 'inv', i.info.partyOwesUs ? i.total : -i.total));
    }
    for (final t in txs) {
      rows.add((t.date, '${t.kind == 'receipt' ? 'دریافت' : 'پرداخت'}${t.description.isEmpty ? '' : ' - ${t.description}'}', 'tx',
          t.kind == 'payment' ? t.amount : -t.amount));
    }
    rows.sort((a, b) => a.$1.compareTo(b.$1));

    final doc = pw.Document(title: 'صورت‌حساب ${party.name}', author: _business);
    final theme = await _theme();
    var running = 0;
    final body = <pw.TableRow>[];
    for (final r in rows) {
      running += r.$4;
      body.add(_row([
        _cell(jalaliText(r.$1), align: pw.TextAlign.center),
        _cell(r.$2),
        _cell(r.$4 > 0 ? money(r.$4) : '', align: pw.TextAlign.left),
        _cell(r.$4 < 0 ? money(-r.$4) : '', align: pw.TextAlign.left),
        _cell(money(running), align: pw.TextAlign.left),
      ]));
    }
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      build: (c) => [
        _text(_business, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        _text('صورت‌حساب ${party.name}', style: pw.TextStyle(fontSize: 14, color: _accent, fontWeight: pw.FontWeight.bold)),
        _text('تاریخ گزارش: ${jalaliText(todayIso())}', style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: _line, width: 0.6),
          columnWidths: _widths(const [
            pw.FlexColumnWidth(1.4),
            pw.FlexColumnWidth(3.4),
            pw.FlexColumnWidth(1.6),
            pw.FlexColumnWidth(1.6),
            pw.FlexColumnWidth(1.8),
          ]),
          children: [
            _row([
              _cell('تاریخ', bold: true, align: pw.TextAlign.center),
              _cell('شرح', bold: true),
              _cell('بدهکار', bold: true, align: pw.TextAlign.left),
              _cell('بستانکار', bold: true, align: pw.TextAlign.left),
              _cell('مانده', bold: true, align: pw.TextAlign.left),
            ], background: _soft),
            ...body,
          ],
        ),
        pw.SizedBox(height: 10),
        _text(
          running == 0
              ? 'حساب تسویه است.'
              : (running > 0
                  ? 'مانده: ${money(running)} $currencyLabel بدهکار به ما'
                  : 'مانده: ${money(-running)} $currencyLabel بستانکار از ما'),
          style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
        ),
      ],
    ));
    return doc.save();
  }

  // ---- output -------------------------------------------------------------

  static Future<void> printBytes(Uint8List bytes, String name, {PdfPageFormat? format}) =>
      Printing.layoutPdf(name: name, onLayout: (_) async => bytes, format: format ?? PdfPageFormat.a4);

  static Future<void> shareBytes(Uint8List bytes, String filename) =>
      Printing.sharePdf(bytes: bytes, filename: filename);
}
