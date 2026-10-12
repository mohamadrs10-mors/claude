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

/// Display name of the currency (changeable in settings).
String currencyLabel = 'تومان';

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

/// Parses a decimal number typed in Persian or Latin digits, ignoring
/// thousands separators ("۱٬۲۵۰٫۵" -> 1250.5). Returns 0 for empty/invalid text.
double parseNum(String s) {
  final t = enDigits(s).replaceAll(RegExp(r'[,٬\s]'), '').replaceAll('٫', '.');
  return double.tryParse(t) ?? 0;
}

/// Number for display: whole numbers without decimals, otherwise up to
/// [digits] decimals, with Persian digits and thousands separators.
String numText(num v, [int digits = 2]) {
  if (v == v.roundToDouble()) return money(v.round());
  final s = v.toStringAsFixed(digits).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  final parts = s.split('.');
  return faDigits('${money(int.parse(parts[0]))}${parts.length > 1 ? '٫${parts[1]}' : ''}');
}
