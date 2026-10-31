import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'delivery_doc.dart';
import 'print_settings.dart';
import 'report_doc.dart';

/// Builds printable PDFs: invoice (any paper size, or a thermal roll),
/// party statement and every report. Persian shaping and right-to-left layout
/// are done by the pdf package using the embedded Vazirmatn font. Paper size,
/// margins and text size come from [PrintSettings].
class PdfDocs {
  PdfDocs(this.repo, {PrintSettings? settings}) : s = settings ?? repo.printSettings;
  final Repo repo;
  final PrintSettings s;

  static pw.Font? _regular, _bold;

  Future<pw.ThemeData> _theme() async {
    _regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Vazirmatn-Regular.ttf'));
    _bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Vazirmatn-Bold.ttf'));
    return pw.ThemeData.withFont(base: _regular!, bold: _bold!, fontFallback: [_regular!]);
  }

  String get _business => repo.setting('business_name', 'MORS ACC');

  /// The business logo from Settings, if there is a valid one.
  pw.MemoryImage? get _logo {
    final b64 = repo.setting('business_logo');
    if (b64.isEmpty) return null;
    try {
      return pw.MemoryImage(base64Decode(b64));
    } catch (_) {
      return null;
    }
  }

  /// Logo in a small white rounded box (readable on the coloured invoice header too).
  pw.Widget _logoBox(pw.MemoryImage img, double size, {bool border = false}) => pw.Container(
        width: size,
        height: size,
        padding: const pw.EdgeInsets.all(3),
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          borderRadius: pw.BorderRadius.circular(6),
          border: border ? pw.Border.all(color: _line, width: 0.5) : null,
        ),
        child: pw.Image(img, fit: pw.BoxFit.contain),
      );

  /// Scaled font size.
  double _s(double v) => v * s.fontScale;

  pw.EdgeInsets get _margin => pw.EdgeInsets.all(s.marginMm * PdfPageFormat.mm);

  static String _qty(double q) => faDigits(q == q.roundToDouble() ? '${q.round()}' : q.toString());

  static final _accent = PdfColor.fromInt(0xFF0F5F58);

  /// Invoice designs for the A4/A5 print: id and title.
  static const invoiceTemplates = <(String, String)>[
    ('classic', 'کلاسیک (سربرگ رنگی)'),
    ('simple', 'ساده و رسمی'),
    ('modern', 'مدرن (ردیف‌های راه‌راه)'),
    ('compact', 'فشرده (برای فاکتورهای بلند)'),
  ];

  /// Accent colours to choose from: id, title and ARGB value.
  static const accentChoices = <(String, String, int)>[
    ('green', 'سبز', 0xFF0F5F58),
    ('blue', 'آبی', 0xFF1D4ED8),
    ('burgundy', 'عنابی', 0xFF9F1239),
    ('purple', 'بنفش', 0xFF6D28D9),
    ('orange', 'نارنجی', 0xFFC2410C),
    ('black', 'مشکی', 0xFF111827),
  ];

  static PdfColor _accentOf(String id) => PdfColor.fromInt(accentChoices.firstWhere((a) => a.$1 == id, orElse: () => accentChoices.first).$3);
  static final _line = PdfColor.fromInt(0xFFD0D7DE);
  static final _soft = PdfColor.fromInt(0xFFF1F5F4);

  /// The pdf package draws the zero-width non-joiner (نیم‌فاصله) as an
  /// overlapping glyph, so it is replaced by a thin space.
  static String _z(String s) => s.replaceAll('‌', ' ');

  pw.Widget _text(String text, {double size = 10, bool bold = false, PdfColor? color, pw.TextAlign? align}) => pw.Text(
        _z(text),
        textAlign: align,
        style: pw.TextStyle(fontSize: _s(size), fontWeight: bold ? pw.FontWeight.bold : null, color: color),
      );

  /// pw.Table always lays columns out left to right, so rows are written in
  /// reading order and reversed here to get a right-to-left table.
  static pw.TableRow _row(List<pw.Widget> cells, {PdfColor? background, bool repeat = false}) => pw.TableRow(
        repeat: repeat,
        decoration: background == null ? null : pw.BoxDecoration(color: background),
        children: cells.reversed.toList(),
      );

  static Map<int, pw.TableColumnWidth> _widths(List<pw.TableColumnWidth> w) =>
      {for (var i = 0; i < w.length; i++) i: w[w.length - 1 - i]};

  pw.Widget _cell(String t, {bool bold = false, Col col = Col.text, PdfColor? color, double size = 10}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: _text(t,
            bold: bold,
            color: color,
            size: size,
            align: switch (col) {
              Col.text => pw.TextAlign.right,
              Col.number => pw.TextAlign.left,
              Col.center => pw.TextAlign.center,
            }),
      );

  pw.Widget _tableOf(ReportTable t) => pw.Table(
        border: pw.TableBorder.all(color: _line, width: 0.6),
        columnWidths: _widths([for (final f in t.flex) pw.FlexColumnWidth(f)]),
        children: [
          _row([for (var i = 0; i < t.headers.length; i++) _cell(t.headers[i], bold: true, col: t.cols[i])],
              background: _soft, repeat: true),
          for (final r in t.rows) _row([for (var i = 0; i < r.length; i++) _cell(r[i], col: t.cols[i])]),
          if (t.totals != null)
            _row([for (var i = 0; i < t.totals!.length; i++) _cell(t.totals![i], bold: true, col: t.cols[i])], background: _soft),
        ],
      );

  pw.Widget _footer(pw.Context c) => pw.Align(
        alignment: pw.Alignment.center,
        child: pw.Text('صفحه ${faDigits('${c.pageNumber}')} از ${faDigits('${c.pagesCount}')}',
            style: pw.TextStyle(fontSize: _s(8), color: PdfColors.grey600)),
      );

  // ---- generic report -----------------------------------------------------

  /// Any report: business name, title, optional summary boxes and tables.
  /// [format] is the page the print dialog asked for (defaults to the
  /// configured paper), so changing the paper in the dialog re-lays the page.
  Future<Uint8List> report(ReportDoc d, {PdfPageFormat? format}) async {
    final doc = pw.Document(title: d.title, author: _business);
    final theme = await _theme();
    doc.addPage(pw.MultiPage(
      pageFormat: format ?? s.format,
      margin: _margin,
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      footer: _footer,
      build: (c) => [
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          if (_logo != null) ...[_logoBox(_logo!, 42, border: true), pw.SizedBox(width: 10)],
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              _text(_business, size: 15, bold: true),
              _text(d.title, size: 13, bold: true, color: _accent),
              if (d.subtitle.isNotEmpty) _text('${d.subtitle} • تاریخ گزارش: ${jalaliText(todayIso())}', size: 9)
              else _text('تاریخ گزارش: ${jalaliText(todayIso())}', size: 9),
            ]),
          ),
        ]),
        pw.SizedBox(height: 10),
        if (d.summary.isNotEmpty) ...[
          pw.Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (label, value) in d.summary)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: pw.BoxDecoration(color: _soft, border: pw.Border.all(color: _line, width: 0.5), borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                  _text(label, size: 8, color: PdfColors.grey700),
                  _text(value, size: 11, bold: true),
                ]),
              ),
          ]),
          pw.SizedBox(height: 12),
        ],
        for (final t in d.tables) ...[
          if (t.heading != null) ...[_text(t.heading!, size: 11, bold: true), pw.SizedBox(height: 4)],
          _tableOf(t),
          if (t.caption.isNotEmpty) ...[pw.SizedBox(height: 4), _text(t.caption, size: 10, bold: true)],
          pw.SizedBox(height: 14),
        ],
        if (d.footnote.isNotEmpty) _text(d.footnote, size: 8, color: PdfColors.grey700),
        if (d.signatures.isNotEmpty) ...[
          pw.SizedBox(height: 22),
          pw.Row(children: [
            for (var i = 0; i < d.signatures.length; i++) ...[
              if (i > 0) pw.SizedBox(width: 18),
              pw.Expanded(
                child: pw.Container(
                  height: 70,
                  padding: const pw.EdgeInsets.all(6),
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8), borderRadius: pw.BorderRadius.circular(6)),
                  child: pw.Align(alignment: pw.Alignment.topRight, child: _text(d.signatures[i], size: 9, bold: true)),
                ),
              ),
            ],
          ]),
        ],
        if (d.closing.trim().isNotEmpty) ...[
          pw.SizedBox(height: 18),
          pw.Center(child: _text(d.closing.trim(), size: 10, color: PdfColors.grey800, align: pw.TextAlign.center)),
        ],
      ],
    ));
    return doc.save();
  }

  // ---- party statement ----------------------------------------------------

  /// Statement of a party for a period (null = everything), with the balance
  /// carried in from before it.
  Future<Uint8List> statement(Party party, {String? from, String? toExclusive, String periodLabel = 'کل دوران', PdfPageFormat? format}) async {
    final d = await repo.statement(party.id, from: from, toExclusive: toExclusive);
    String bal(int v) => v == 0 ? '۰' : (v > 0 ? '${money(v)} بدهکار' : '${money(-v)} بستانکار');
    return report(
      ReportDoc(
        title: 'صورت‌حساب ${party.name}',
        subtitle: 'بازه: $periodLabel${party.phone.isEmpty ? '' : ' • تلفن: ${faDigits(party.phone)}'}',
        summary: [
          ('مانده از قبل', bal(d.opening)),
          ('جمع بدهکار', moneyC(d.totalDebit)),
          ('جمع بستانکار', moneyC(d.totalCredit)),
          ('مانده پایان', bal(d.closing)),
        ],
        tables: [
          ReportTable(
            headers: const ['تاریخ', 'شرح', 'بدهکار', 'بستانکار', 'مانده'],
            cols: const [Col.center, Col.text, Col.number, Col.number, Col.number],
            flex: const [1.4, 3.4, 1.6, 1.6, 2],
            rows: [
              if (d.opening != 0) ['', 'مانده از قبل', '', '', money(d.opening)],
              for (final r in d.rows)
                [jalaliText(r.date), r.description, r.debit > 0 ? money(r.debit) : '', r.credit > 0 ? money(r.credit) : '', money(r.balance)],
            ],
            totals: ['', 'جمع', money(d.totalDebit), money(d.totalCredit), money(d.closing)],
          ),
        ],
        footnote: 'بدهکار یعنی طلب ما از شخص؛ بستانکار یعنی بدهی ما به او. مبالغ بر حسب $currencyLabel.',
      ),
      format: format,
    );
  }

  // ---- invoice ------------------------------------------------------------

  /// An invoice on the configured paper, or a thermal roll when [roll] is true.
  Future<Uint8List> invoice(Invoice inv, List<InvoiceItem> items, Party? party, {bool roll = false, PdfPageFormat? format, String? template}) async {
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
      if (inv.prepaid > 0) ('کسر از پیش‌دریافت', money(inv.prepaid), false),
      if (inv.paid > 0) (info.paymentKind == 'receipt' ? 'دریافت‌شده' : 'پرداخت‌شده', money(inv.paid), false),
      if (inv.paid > 0 || inv.prepaid > 0) ('مانده', money(inv.remaining), true),
    ];

    if (roll) {
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(s.rollWidthMm * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
        textDirection: pw.TextDirection.rtl,
        theme: theme,
        build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
          if (_logo != null) pw.Center(child: pw.SizedBox(height: 40, child: pw.Image(_logo!, fit: pw.BoxFit.contain))),
          pw.Center(child: _text(_business, size: 14, bold: true)),
          if (phone.isNotEmpty) pw.Center(child: _text(faDigits(phone), size: 9)),
          pw.SizedBox(height: 4),
          pw.Divider(thickness: 0.6),
          _text('${info.label} ${faDigits('${inv.number}')}', size: 11, bold: true),
          _text('تاریخ: ${jalaliText(inv.date)}', size: 9),
          if (party != null) _text('${info.partyLabel}: ${party.name}', size: 9),
          pw.Divider(thickness: 0.6),
          for (final it in items)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 2),
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                _text(it.title, size: 9),
                pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
                  _text('${_qty(it.qty)} × ${money(it.unitPrice)}', size: 8),
                  _text(money(it.total), size: 9),
                ]),
              ]),
            ),
          pw.Divider(thickness: 0.6),
          for (final t in totals)
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              _text(t.$1, size: t.$3 ? 10 : 9, bold: t.$3),
              _text('${t.$2} $cur', size: t.$3 ? 10 : 9, bold: t.$3),
            ]),
          if (footer.isNotEmpty) ...[
            pw.SizedBox(height: 8),
            pw.Center(child: _text(footer, size: 8, align: pw.TextAlign.center)),
          ],
        ]),
      ));
      return doc.save();
    }

    final fmt = format ?? s.format;
    final usable = fmt.width - 2 * s.marginMm * PdfPageFormat.mm;
    final narrow = usable < 400; // A5 portrait: stack the note above the totals
    final tpl = template ?? repo.setting('invoice_template', 'classic');
    final compact = tpl == 'compact';
    final accent = _accentOf(repo.setting('invoice_accent', 'green'));
    final showLogo = repo.setting('invoice_logo', '1') != '0';
    final rowNo = repo.setting('invoice_rownum', '1') != '0';
    final sign = repo.setting('invoice_signatures', '1') != '0';
    final qr = repo.setting('invoice_qr', '0') == '1';
    final whs = await repo.warehouses();
    final wh = whs.length > 1 ? whs.where((w) => w.id == (inv.warehouseId ?? mainWarehouseId)).firstOrNull?.name : null;
    final logo = showLogo ? _logo : null;
    final fs = compact ? 0.88 : 1.0; // text scale of the table
    final pad = compact ? 2.0 : 4.0;

    final totalsBox = pw.Container(
      width: narrow ? double.infinity : (usable * 0.42).clamp(190, 240).toDouble(),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
      child: pw.Column(children: [
        for (final t in totals)
          pw.Container(
            color: t.$3 ? (tpl == 'modern' ? accent : _soft) : null,
            padding: pw.EdgeInsets.symmetric(horizontal: 8, vertical: pad),
            child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              _text(t.$1, bold: t.$3, color: t.$3 && tpl == 'modern' ? PdfColors.white : null, size: 10 * fs),
              _text('${t.$2} $cur', bold: t.$3, color: t.$3 && tpl == 'modern' ? PdfColors.white : null, size: 10 * fs),
            ]),
          ),
      ]),
    );
    final noteBox = inv.note.isEmpty
        ? null
        : pw.Container(
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
            child: _text('توضیحات: ${inv.note}', size: 9),
          );

    final meta = [
      _text(info.label, size: compact ? 13 : 17, bold: true, color: tpl == 'classic' ? PdfColors.white : (tpl == 'modern' ? accent : null)),
      _text('شماره: ${faDigits('${inv.number}')}', color: tpl == 'classic' ? PdfColors.white : null),
      _text('تاریخ: ${jalaliText(inv.date)}', color: tpl == 'classic' ? PdfColors.white : null),
      if (inv.dueDate != null && inv.kind != 'proforma') _text('سررسید: ${jalaliText(inv.dueDate!)}', size: 9, color: tpl == 'classic' ? PdfColors.white : null),
      if (wh != null) _text('انبار: $wh', size: 9, color: tpl == 'classic' ? PdfColors.white : null),
    ];
    final onHead = tpl == 'classic' ? PdfColors.white : null;
    final business = pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _text(_business, size: compact ? 13 : 17, bold: true, color: onHead ?? (tpl == 'modern' ? accent : null)),
      if (address.isNotEmpty && !compact) _text(address, size: 9, color: onHead),
      if (phone.isNotEmpty) _text('تلفن: ${faDigits(phone)}', size: 9, color: onHead),
      if (taxId.isNotEmpty && !compact) _text('شناسه اقتصادی: ${faDigits(taxId)}', size: 9, color: onHead),
    ]);
    final head = pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      if (logo != null) ...[tpl == 'classic' ? _logoBox(logo, 54) : pw.SizedBox(width: compact ? 40 : 54, height: compact ? 40 : 54, child: pw.Image(logo, fit: pw.BoxFit.contain)), pw.SizedBox(width: 10)],
      pw.Expanded(child: business),
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: meta),
    ]);
    final header = switch (tpl) {
      'classic' => pw.Container(padding: const pw.EdgeInsets.all(12), decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(8)), child: head),
      'modern' => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 10),
          decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: accent, width: 3))),
          child: head),
      'compact' => pw.Container(padding: const pw.EdgeInsets.only(bottom: 6), decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: accent, width: 1))), child: head),
      _ => pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey800, width: 1.2), borderRadius: pw.BorderRadius.circular(4)),
          child: head),
    };

    // The table: grid (classic, simple, compact) or horizontal rules with
    // alternating rows (modern).
    final modern = tpl == 'modern';
    final headBg = modern ? accent : _soft;
    final headFg = modern ? PdfColors.white : null;
    pw.Widget c(String t, {bool bold = false, Col col = Col.text, PdfColor? color}) => pw.Padding(
          padding: pw.EdgeInsets.symmetric(horizontal: 6, vertical: pad),
          child: _text(t,
              bold: bold,
              color: color,
              size: 10 * fs,
              align: switch (col) {
                Col.text => pw.TextAlign.right,
                Col.number => pw.TextAlign.left,
                Col.center => pw.TextAlign.center,
              }),
        );
    final table = pw.Table(
      border: modern
          ? pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.5), bottom: pw.BorderSide(color: accent, width: 1))
          : pw.TableBorder.all(color: tpl == 'simple' ? PdfColors.grey700 : _line, width: 0.6),
      columnWidths: _widths([
        if (rowNo) const pw.FixedColumnWidth(36),
        const pw.FlexColumnWidth(4),
        const pw.FixedColumnWidth(52),
        const pw.FlexColumnWidth(1.6),
        const pw.FlexColumnWidth(1.8),
      ]),
      children: [
        _row([
          if (rowNo) c('ردیف', bold: true, col: Col.center, color: headFg),
          c('شرح کالا / خدمات', bold: true, color: headFg),
          c('تعداد', bold: true, col: Col.center, color: headFg),
          c('قیمت واحد', bold: true, col: Col.number, color: headFg),
          c('مبلغ', bold: true, col: Col.number, color: headFg),
        ], background: headBg, repeat: true),
        for (var i = 0; i < items.length; i++)
          _row([
            if (rowNo) c(faDigits('${i + 1}'), col: Col.center),
            c(items[i].title),
            c(_qty(items[i].qty), col: Col.center),
            c(money(items[i].unitPrice), col: Col.number),
            c(money(items[i].total), col: Col.number),
          ], background: modern && i.isOdd ? _soft : null),
      ],
    );

    doc.addPage(pw.MultiPage(
      pageFormat: fmt,
      margin: _margin,
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      footer: _footer,
      build: (ctx) => [
        header,
        pw.SizedBox(height: compact ? 6 : 10),
        pw.Container(
          width: double.infinity,
          padding: pw.EdgeInsets.all(compact ? 5 : 8),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            _text('${info.partyLabel}: ${party?.name ?? '—'}', size: compact ? 10 : 11, bold: true),
            if ((party?.phone ?? '').isNotEmpty) _text('تلفن: ${faDigits(party!.phone)}', size: 9),
          ]),
        ),
        pw.SizedBox(height: compact ? 6 : 10),
        table,
        pw.SizedBox(height: compact ? 6 : 10),
        if (narrow) ...[
          if (noteBox != null) ...[noteBox, pw.SizedBox(height: 8)],
          totalsBox,
        ] else
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: noteBox ?? pw.SizedBox()),
            pw.SizedBox(width: 14),
            totalsBox,
          ]),
        if (qr) ...[
          pw.SizedBox(height: 8),
          pw.Row(children: [
            pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: 'MORS|$_business|${info.label}|${inv.number}|${inv.date}|${inv.total}|${party?.name ?? ''}',
              width: 62,
              height: 62,
              drawText: false,
            ),
            pw.SizedBox(width: 8),
            _text('کد QR: مشخصات و مبلغ این فاکتور', size: 8, color: PdfColors.grey700),
          ]),
        ],
        if (sign) ...[
          pw.SizedBox(height: compact ? 16 : 30),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
            _text(inv.kind.startsWith('sale') || inv.kind == 'proforma' ? 'امضای فروشنده' : 'امضای خریدار'),
            _text(inv.kind.startsWith('sale') || inv.kind == 'proforma' ? 'امضای خریدار' : 'امضای فروشنده'),
          ]),
        ],
        if (footer.isNotEmpty) ...[
          pw.SizedBox(height: compact ? 8 : 18),
          pw.Center(child: _text(footer, size: 9, color: PdfColors.grey700)),
        ],
      ],
    ));
    return doc.save();
  }

  // ---- barcode labels -----------------------------------------------------

  /// A sheet of product labels: name, price and a Code 128 barcode of the
  /// product code, [columns] labels across. Products without a plain
  /// (letters and digits) code show the code as text instead.
  Future<Uint8List> labels(List<Product> products, {int columns = 3, bool showPrice = true, PdfPageFormat? format}) async {
    final doc = pw.Document(title: 'برچسب بارکد', author: _business);
    final theme = await _theme();
    final fmt = format ?? s.format;
    final usable = fmt.width - 2 * s.marginMm * PdfPageFormat.mm;
    final w = (usable - 8 * (columns - 1)) / columns;
    final ascii = RegExp(r'^[A-Za-z0-9\-_. ]+$');
    pw.Widget label(Product p) {
      final code = enDigits(p.code);
      return pw.Container(
        width: w,
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.5), borderRadius: pw.BorderRadius.circular(4)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          _text(p.name, size: 9, bold: true, align: pw.TextAlign.center),
          if (showPrice) _text('${money(p.salePrice)} $currencyLabel', size: 8),
          pw.SizedBox(height: 3),
          if (code.isNotEmpty && ascii.hasMatch(code))
            pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: code, width: w - 14, height: 30, drawText: true, textStyle: pw.TextStyle(fontSize: _s(7)))
          else if (code.isNotEmpty)
            _text(faDigits(code), size: 9),
        ]),
      );
    }

    doc.addPage(pw.MultiPage(
      pageFormat: fmt,
      margin: _margin,
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      footer: _footer,
      build: (c) => [pw.Wrap(spacing: 8, runSpacing: 8, children: [for (final p in products) label(p)])],
    ));
    return doc.save();
  }

  // ---- delivery receipt ---------------------------------------------------

  /// Delivery receipt: the goods only, never a price. With [signatures] the
  /// page ends in boxes for the stamp and signature of whoever hands the goods
  /// over and whoever receives them.
  Future<Uint8List> delivery(DeliveryDoc d, {bool signatures = true, PdfPageFormat? format}) async {
    final doc = pw.Document(title: 'رسید تحویل ${d.number}', author: _business);
    final theme = await _theme();
    final phone = repo.setting('business_phone');
    final address = repo.setting('business_address');
    final footer = repo.setting('invoice_footer');

    pw.Widget signBox(String who) => pw.Expanded(
          child: pw.Container(
            height: 96,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              _text(who, size: 11, bold: true),
              pw.SizedBox(height: 4),
              _text('نام و نام خانوادگی:', size: 9, color: PdfColors.grey700),
              pw.Spacer(),
              _text('مهر و امضا', size: 9, color: PdfColors.grey700),
            ]),
          ),
        );

    doc.addPage(pw.MultiPage(
      pageFormat: format ?? s.format,
      margin: _margin,
      textDirection: pw.TextDirection.rtl,
      theme: theme,
      footer: _footer,
      build: (c) => [
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: _accent, borderRadius: pw.BorderRadius.circular(8)),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            if (_logo != null) ...[_logoBox(_logo!, 54), pw.SizedBox(width: 10)],
            pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                _text(_business, size: 17, bold: true, color: PdfColors.white),
                if (address.isNotEmpty) _text(address, size: 9, color: PdfColors.white),
                if (phone.isNotEmpty) _text('تلفن: ${faDigits(phone)}', size: 9, color: PdfColors.white),
              ]),
            ),
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
              _text('رسید تحویل', size: 17, bold: true, color: PdfColors.white),
              _text('شماره: ${faDigits(d.number)}', color: PdfColors.white),
              _text('تاریخ: ${jalaliText(d.date)}', color: PdfColors.white),
            ]),
          ]),
        ),
        pw.SizedBox(height: 10),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            _text('${d.partyLabel}: ${d.partyName.isEmpty ? '—' : d.partyName}', size: 11, bold: true),
            if (d.phone.isNotEmpty) _text('تلفن: ${faDigits(d.phone)}', size: 9),
            if (d.address.isNotEmpty) _text('نشانی: ${d.address}', size: 9),
            if (d.ref.isNotEmpty) _text(d.ref, size: 9),
          ]),
        ),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: _line, width: 0.6),
          columnWidths: _widths(const [
            pw.FixedColumnWidth(36),
            pw.FlexColumnWidth(5),
            pw.FixedColumnWidth(60),
            pw.FixedColumnWidth(60),
          ]),
          children: [
            _row([
              _cell('ردیف', bold: true, col: Col.center),
              _cell('شرح کالا', bold: true),
              _cell('تعداد', bold: true, col: Col.center),
              _cell('واحد', bold: true, col: Col.center),
            ], background: _soft, repeat: true),
            for (var i = 0; i < d.lines.length; i++)
              _row([
                _cell(faDigits('${i + 1}'), col: Col.center),
                _cell(d.lines[i].$1),
                _cell(_qty(d.lines[i].$2), col: Col.center),
                _cell(d.lines[i].$3, col: Col.center),
              ]),
          ],
        ),
        pw.SizedBox(height: 6),
        _text('تعداد اقلام: ${faDigits('${d.lines.length}')} ردیف', size: 9, color: PdfColors.grey700),
        if (d.note.isNotEmpty) ...[
          pw.SizedBox(height: 8),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line), borderRadius: pw.BorderRadius.circular(6)),
            child: _text('توضیحات: ${d.note}', size: 9),
          ),
        ],
        if (signatures) ...[
          pw.SizedBox(height: 14),
          _text('اقلام فوق به‌طور کامل و سالم تحویل گردید.', size: 9),
          pw.SizedBox(height: 8),
          pw.Row(children: [signBox('تحویل‌دهنده'), pw.SizedBox(width: 14), signBox('تحویل‌گیرنده')]),
        ],
        if (footer.isNotEmpty) ...[
          pw.SizedBox(height: 14),
          pw.Center(child: _text(footer, size: 9, color: PdfColors.grey700)),
        ],
      ],
    ));
    return doc.save();
  }

  // ---- output -------------------------------------------------------------

  /// Opens the system print dialog. [build] is called again with the page
  /// format chosen in the dialog, so switching A4/A5 there re-lays the page.
  static Future<void> print(Future<Uint8List> Function(PdfPageFormat format) build, String name, PrintSettings settings) =>
      Printing.layoutPdf(name: name, onLayout: (f) => build(f), format: settings.format);

  /// Thermal receipt: a fixed-width roll, so the dialog must not re-lay it out.
  static Future<void> printRoll(Uint8List bytes, String name, PrintSettings settings) => Printing.layoutPdf(
        name: name,
        onLayout: (_) async => bytes,
        format: PdfPageFormat(settings.rollWidthMm * PdfPageFormat.mm, double.infinity, marginAll: 4 * PdfPageFormat.mm),
        dynamicLayout: false,
      );

  static Future<void> share(Uint8List bytes, String filename) => Printing.sharePdf(bytes: bytes, filename: filename);
}
