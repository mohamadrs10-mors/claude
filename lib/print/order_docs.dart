import '../data/repo.dart';
import '../util/format.dart';
import 'report_doc.dart';

/// The line printed under a draft order unless the user changed it (Settings, or
/// while printing).
const defaultDraftFooter = 'قیمت‌های فوق با توجه به نوسانات قیمت متریال و مواد مصرفی تنها ۴۸ ساعت اعتبار دارد';

String _q(double q) => faDigits(q == q.roundToDouble() ? '${q.round()}' : q.toStringAsFixed(2));

/// An order (or a draft of one) for the customer: the products with prices,
/// the total, the advance (planned for a draft, received for an order), the
/// delivery date and the cheques received as advance.
ReportDoc orderDoc(Order o, Party? party, List<Cheque> cheques, Map<String, String> units, {String draftFooter = defaultDraftFooter}) {
  final draft = o.isDraft;
  final advance = draft ? o.planned : o.advance;
  final rest = o.total - advance;
  final head = [
    'شمارهٔ ${faDigits('${o.number}')}',
    'تاریخ: ${jalaliText(o.date)}',
    if (party != null) 'مشتری: ${party.name}${party.phone.isEmpty ? '' : ' • ${faDigits(party.phone)}'}',
  ].join(' • ');
  return ReportDoc(
    title: draft ? 'پیش‌نویس سفارش (پیش‌فاکتور سفارش)' : 'سفارش مشتری',
    subtitle: head,
    summary: [
      ('جمع سفارش', moneyC(o.total)),
      (draft ? 'پیش‌دریافت پیشنهادی (${faDigits(_q(o.percent))}٪)' : 'پیش‌دریافت دریافت‌شده (${faDigits(_q(o.percent))}٪)', moneyC(advance)),
      ('مانده بعد از پیش‌دریافت', moneyC(rest < 0 ? 0 : rest)),
      if (o.deliveryDate.isNotEmpty) ('تاریخ تحویل', jalaliText(o.deliveryDate)),
    ],
    tables: [
      ReportTable(
        heading: 'کالاهای سفارش',
        headers: const ['ردیف', 'کالا', 'تعداد', 'قیمت واحد', 'مبلغ'],
        cols: const [Col.center, Col.text, Col.center, Col.number, Col.number],
        flex: const [0.6, 3.6, 1.4, 1.8, 2],
        rows: [
          for (var i = 0; i < o.items.length; i++)
            [faDigits('${i + 1}'), o.items[i].title, '${_q(o.items[i].qty)} ${units[o.items[i].productId] ?? ''}'.trim(), money(o.items[i].unitPrice), money(o.items[i].total)],
        ],
        totals: ['', 'جمع', '', '', money(o.total)],
      ),
      if (!draft && cheques.isNotEmpty)
        ReportTable(
          heading: 'چک‌های پیش‌دریافت',
          headers: const ['سررسید', 'شمارهٔ چک', 'بانک', 'وضعیت', 'مبلغ'],
          cols: const [Col.center, Col.center, Col.text, Col.center, Col.number],
          flex: const [1.5, 1.5, 2, 1.4, 1.8],
          rows: [
            for (final c in cheques)
              [jalaliText(c.dueDate), faDigits(c.number), c.bank, switch (c.status) { 'cleared' => 'وصول شده', 'bounced' => 'برگشتی', _ => 'در انتظار' }, money(c.amount)],
          ],
        ),
    ],
    footnote: [
      if (draft && draftFooter.trim().isNotEmpty) draftFooter.trim(),
      if (o.note.isNotEmpty) 'توضیحات: ${o.note}',
    ].join('\n'),
  );
}
