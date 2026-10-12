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

/// Character that separates every three digits of an amount: `.` or `,`
/// (a synced setting).
String thousandsSep = '.';

final _num = NumberFormat('#,###', 'en');

/// Groups a string of Latin digits in threes from the right.
String groupDigits(String digits) => _num.format(int.tryParse(digits) ?? 0).replaceAll(',', thousandsSep);

String money(num v) => faDigits('${v < 0 ? '-' : ''}${_num.format(v.abs()).replaceAll(',', thousandsSep)}');

/// A number typed into a money field, e.g. "۱.۲۵۰.۵" -> 1250.5. Which character
/// is the thousands separator depends on [thousandsSep]; `٫` and `/` are
/// always decimal marks.
double parseMoneyNum(String s) {
  var t = enDigits(s).replaceAll(RegExp(r'\s'), '').replaceAll('٬', '');
  t = t.replaceAll(thousandsSep == '.' ? RegExp(r'[.,]') : RegExp(','), '');
  return double.tryParse(t.replaceAll('٫', '.').replaceAll('/', '.')) ?? 0;
}

/// Text to put into a money field: grouped, Persian digits, `٫` for decimals.
String inputNum(num v, {int decimals = 4}) {
  final neg = v < 0;
  var fixed = v.abs().toStringAsFixed(decimals);
  if (fixed.contains('.')) fixed = fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  final parts = fixed.split('.');
  return faDigits('${neg ? '-' : ''}${groupDigits(parts[0])}${parts.length > 1 ? '٫${parts[1]}' : ''}');
}

/// A plain number for fields that hold quantities or percentages: no
/// grouping, `.` as the decimal mark ("12.5").
String plainNum(num v, {int decimals = 4}) {
  var fixed = v.toStringAsFixed(decimals);
  if (fixed.contains('.')) fixed = fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return fixed;
}

/// Amount with the currency name, e.g. "۱.۲۰۰ تومان".
String moneyC(num v) => '${money(v)} $currencyLabel';

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
String numText(num v, [int digits = 2]) => inputNum(v, decimals: digits);

/// ISO range [start, endExclusive) of a Jalali year.
(String, String) jalaliYearRange(int year) =>
    (isoOf(Jalali(year, 1, 1).toDateTime()), isoOf(Jalali(year + 1, 1, 1).toDateTime()));
