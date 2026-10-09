import 'package:intl/intl.dart';
import 'package:shamsi_date/shamsi_date.dart';

const _fa = '۰۱۲۳۴۵۶۷۸۹';

String faDigits(String s) =>
    s.replaceAllMapped(RegExp(r'\d'), (m) => _fa[int.parse(m[0]!)]);

/// Parses Persian/Arabic/Latin digits typed by the user.
String enDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final c in s.split('')) {
    final i = _fa.indexOf(c);
    final j = ar.indexOf(c);
    b.write(i >= 0 ? '$i' : (j >= 0 ? '$j' : c));
  }
  return b.toString();
}

int parseAmount(String s) =>
    int.tryParse(enDigits(s).replaceAll(RegExp(r'[^\d-]'), '')) ?? 0;

final _num = NumberFormat('#,###', 'en');

String money(num v) => faDigits('${v < 0 ? '-' : ''}${_num.format(v.abs())}');

const monthNames = [
  'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور',
  'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند',
];

String isoOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String todayIso() => isoOf(DateTime.now());

/// "2024-03-20" -> "۱۴۰۳/۰۱/۰۱"
String jalaliText(String iso) {
  final d = DateTime.parse(iso);
  final j = Jalali.fromDateTime(d);
  return faDigits(
      '${j.year}/${j.month.toString().padLeft(2, '0')}/${j.day.toString().padLeft(2, '0')}');
}

/// ISO range [start, endExclusive) of a Jalali month.
(String, String) jalaliMonthRange(int year, int month) {
  final s = Jalali(year, month, 1);
  final e = month == 12 ? Jalali(year + 1, 1, 1) : Jalali(year, month + 1, 1);
  return (isoOf(s.toDateTime()), isoOf(e.toDateTime()));
}
