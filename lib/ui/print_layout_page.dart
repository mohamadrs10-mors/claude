import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/delivery_doc.dart';
import '../print/order_docs.dart';
import '../print/pdf_docs.dart';
import '../print/print_layout.dart';
import '../print/report_doc.dart';
import '../util/format.dart';
import 'common.dart';
import 'print_dialog.dart';

/// Print layout (چیدمان چاپ): for every kind of printout, which parts are
/// shown and the page margins, with a preview on sample data. Saved per device.
class PrintLayoutPage extends StatefulWidget {
  const PrintLayoutPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<PrintLayoutPage> createState() => _PrintLayoutPageState();
}

class _PrintLayoutPageState extends State<PrintLayoutPage> {
  /// One set of four margin fields per kind: top, right, bottom, left.
  final Map<String, List<TextEditingController>> _margins = {};

  Repo get repo => widget.repo;

  List<TextEditingController> _ctl(String kind) => _margins.putIfAbsent(kind, () {
        final m = repo.printLayout.margins(kind);
        return [for (var i = 0; i < 4; i++) TextEditingController(text: m?[i] == null ? '' : plainNum(m![i]!, decimals: 1))];
      });

  @override
  void dispose() {
    for (final l in _margins.values) {
      for (final c in l) {
        c.dispose();
      }
    }
    super.dispose();
  }

  /// What a part is set to right now, including the older synced invoice options.
  bool _effective(PrintLayout l, String kind, String key) {
    final v = l.explicit(kind, key);
    if (v != null) return v;
    if (kind == 'invoice') {
      const legacy = {'logo': 'invoice_logo', 'rownum': 'invoice_rownum', 'signatures': 'invoice_signatures'};
      if (legacy.containsKey(key)) return repo.setting(legacy[key]!, '1') != '0';
      if (key == 'qr') return repo.setting('invoice_qr', '0') == '1';
    }
    return l.shows(kind, key);
  }

  void _saveMargins(String kind) {
    final fields = _ctl(kind);
    final values = [for (final c in fields) c.text.trim().isEmpty ? null : double.tryParse(enDigits(c.text.trim().replaceAll('٫', '.')))];
    repo.setPrintLayout(repo.printLayout.withMargins(kind, values));
  }

  // ---- previews on sample data -----------------------------------------------

  Future<void> _preview(String kind) async {
    final items = [InvoiceItem('برنج ایرانی', 10, 1500000), InvoiceItem('روغن مایع', 4, 2200000), InvoiceItem('خدمات حمل', 1, 300000)];
    final party = Party('p', 'مشتری نمونه', '09120000000', '', 0);
    final inv = Invoice('sample', 12, 'sale', todayIso(), 'p', 100000, 'توضیحات نمونه', items.fold(0, (a, i) => a + i.total), 0, 9, null, null, 0, null, todayIso());
    final order = Order(
      id: 'o', number: 5, date: todayIso(), partyId: 'p', title: 'برنج', items: [OrderItem('کابینت MDF', 12, 2500000), OrderItem('نصب', 1, 3000000)], percent: 40,
      cash: kind == 'draft' ? 0 : 13200000, status: kind == 'draft' ? 'draft' : 'open', released: 0, closedDate: '', note: 'تحویل در محل', applied: 0, deliveryDate: todayIso(), planned: kind == 'draft' ? 13200000 : 0,
    );
    final delivery = DeliveryDoc(number: '8', date: todayIso(), partyName: 'مشتری نمونه', phone: '09120000000', address: 'تهران، خیابان نمونه', ref: 'بابت فاکتور فروش شمارهٔ ۱۲', note: 'توضیحات نمونه', lines: [('برنج ایرانی', 10, 'کیسه'), ('روغن مایع', 4, 'گالن')]);
    final sampleReport = ReportDoc(
      kind: kind,
      title: kind == 'statement' ? 'صورت‌حساب مشتری نمونه' : 'گزارش نمونه',
      subtitle: 'بازهٔ نمونه',
      summary: [('جمع', moneyC(12500000)), ('تعداد', faDigits('3'))],
      tables: [
        ReportTable(headers: const ['تاریخ', 'شرح', 'مبلغ'], cols: const [Col.center, Col.text, Col.number], flex: const [1.5, 4, 2], rows: [
          [jalaliText(todayIso()), 'ردیف نمونه یک', money(5000000)],
          [jalaliText(todayIso()), 'ردیف نمونه دو', money(7500000)],
        ], totals: ['', 'جمع', money(12500000)]),
      ],
      footnote: 'توضیح پایین نمونه.',
    );
    final title = 'پیش‌نمایش ${PrintLayout.kind(kind)?.label ?? ''}';
    switch (kind) {
      case 'invoice':
        return showPrintDialog(context, repo, title: title, filename: 'preview.pdf', build: (s, f) => PdfDocs(repo, settings: s).invoice(inv, items, party, format: f));
      case 'roll':
        return showPrintDialog(context, repo, title: title, filename: 'preview.pdf', roll: true, build: (s, f) => PdfDocs(repo, settings: s).invoice(inv, items, party, roll: true));
      case 'order':
      case 'draft':
        return showPrintDialog(context, repo, title: title, filename: 'preview.pdf',
            build: (s, f) => PdfDocs(repo, settings: s).report(orderDoc(order, party, const [], const {}, layout: repo.printLayout), format: f));
      case 'delivery':
        return showPrintDialog(context, repo, title: title, filename: 'preview.pdf', build: (s, f) => PdfDocs(repo, settings: s).delivery(delivery, format: f));
      default:
        return showPrintDialog(context, repo, title: title, filename: 'preview.pdf', build: (s, f) => PdfDocs(repo, settings: s).report(sampleReport, format: f));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('چیدمان چاپ هر برگه')),
        body: ListenableBuilder(
          listenable: repo,
          builder: (context, _) {
            final layout = repo.printLayout;
            final defaultMargin = repo.printSettings.marginMm;
            return Constrained(
              maxWidth: 760,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Text(
                  'برای هر برگه مشخص کنید چه بخش‌هایی چاپ شود و حاشیه‌های بالا، راست، پایین و چپ چند میلی‌متر باشد. حاشیهٔ خالی یعنی همان حاشیهٔ تنظیمات چاپ (${faDigits('${defaultMargin.round()}')} میلی‌متر). '
                  'هر بخش پیش‌نمایش با اطلاعات نمونه دارد. این تنظیم‌ها فقط روی همین دستگاه ذخیره می‌شود.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                gap(),
                for (final k in printKinds)
                  Card(
                    child: ExpansionTile(
                      key: ValueKey('pl-${k.id}'),
                      title: Text(k.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: layout.isCustom(k.id) ? const Text('سفارشی‌شده') : null,
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in k.elements)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(e.label),
                            value: _effective(layout, k.id, e.key),
                            onChanged: (v) => repo.setPrintLayout(repo.printLayout.withShow(k.id, e.key, v)),
                          ),
                        const SizedBox(height: 6),
                        const Text('حاشیهٔ صفحه (میلی‌متر)'),
                        const SizedBox(height: 6),
                        Row(children: [
                          for (final (i, label) in const ['بالا', 'راست', 'پایین', 'چپ'].indexed) ...[
                            if (i > 0) const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _ctl(k.id)[i],
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                textDirection: TextDirection.ltr,
                                decoration: InputDecoration(labelText: label, hintText: faDigits('${defaultMargin.round()}'), isDense: true),
                                onChanged: (_) => _saveMargins(k.id),
                              ),
                            ),
                          ],
                        ]),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, children: [
                          FilledButton.tonalIcon(onPressed: () => _preview(k.id), icon: const Icon(Icons.visibility_outlined), label: const Text('پیش‌نمایش')),
                          TextButton.icon(
                            onPressed: !layout.isCustom(k.id)
                                ? null
                                : () async {
                                    await repo.setPrintLayout(repo.printLayout.reset(k.id));
                                    for (final c in _ctl(k.id)) {
                                      c.clear();
                                    }
                                  },
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('بازنشانی به حالت اولیه'),
                          ),
                        ]),
                      ],
                    ),
                  ),
              ]),
            );
          },
        ),
      );
}
