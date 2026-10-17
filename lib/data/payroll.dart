import 'dart:math' as math;

import 'costing.dart';

/// How a person is paid.
///
/// - [monthly]: a fixed monthly salary; with attendance-based pay it is cut in
///   proportion to the hours that were not worked (one hour less = less pay);
/// - [hourly]: rate x hours present;
/// - [contract]: a contract amount paid in instalments (per payslip);
/// - [formula]: your own formula over the hours and amounts below.
const payTypes = <(String, String)>[
  ('monthly', 'حقوق ماهانه'),
  ('hourly', 'ساعتی'),
  ('contract', 'قراردادی'),
  ('formula', 'فرمول دلخواه'),
];

String payTypeLabel(String t) => payTypes.firstWhere((x) => x.$1 == t, orElse: () => payTypes.first).$2;

/// Variables a pay formula can use (name, meaning).
const formulaVariables = <(String, String)>[
  ('base', 'مبلغ پایه (حقوق ماهانه / نرخ ساعتی / مبلغ قرارداد)'),
  ('hours', 'ساعت کار عادی + مرخصی با حقوق'),
  ('worked', 'کل ساعت حضور'),
  ('overtime', 'ساعت اضافه‌کار'),
  ('leave', 'ساعت مرخصی با حقوق'),
  ('required', 'ساعت موظفی ماه'),
  ('days', 'تعداد روزهای حضور'),
  ('workdays', 'تعداد روزهای کاری ماه'),
  ('monthdays', 'تعداد روزهای ماه'),
  ('daily', 'ساعت کار روزانه'),
  ('ratio', 'نسبت حضور به موظفی (۰ تا ۱)'),
  ('otrate', 'ضریب اضافه‌کار'),
];

/// One time-clock entry as the calculation sees it.
class WorkEntry {
  WorkEntry(this.date, this.minutes, {this.leave = false});

  /// ISO date.
  final String date;
  final int minutes;

  /// Paid leave: counts as present for the minutes given.
  final bool leave;
}

/// What a payslip is calculated from.
class PayInput {
  PayInput({
    required this.payType,
    required this.base,
    this.attendanceBased = false,
    this.dailyHours = 8,
    this.overtimeRate = 0,
    this.insurancePercent = 0,
    this.formula = '',
    this.contractMonths = 0,
    this.manualBase,
    required this.entries,
    required this.workdays,
    required this.offDates,
    required this.monthDays,
    this.additions = 0,
    this.manualDeductions = 0,
  });

  final String payType;
  final int base;
  final bool attendanceBased;
  final double dailyHours, overtimeRate, insurancePercent;
  final String formula;
  final int contractMonths;

  /// A hand-typed amount that replaces the calculated base pay.
  final int? manualBase;
  final List<WorkEntry> entries;

  /// Working days of the month (not days off, not holidays, not before the start date).
  final int workdays;

  /// Dates of the month that are days off or holidays: work on them is overtime.
  final Set<String> offDates;
  final int monthDays;
  final int additions, manualDeductions;
}

/// The result of a payslip calculation.
class PayCalc {
  PayCalc({
    required this.workedMin,
    required this.leaveMin,
    required this.overtimeMin,
    required this.requiredMin,
    required this.daysPresent,
    required this.basePay,
    required this.overtimePay,
    required this.additions,
    required this.manualDeductions,
    required this.insurance,
    required this.net,
    required this.shortfall,
    required this.ratio,
  });

  final int workedMin, leaveMin, overtimeMin, requiredMin, daysPresent;
  final int basePay, overtimePay, additions, manualDeductions, insurance, net;

  /// What the base pay lost because of missing hours (monthly, attendance-based).
  final int shortfall;
  final double ratio;

  int get normalMin => workedMin - overtimeMin;
  int get gross => basePay + overtimePay + additions;
  int get deductions => insurance + manualDeductions;
}

class Payroll {
  /// Minutes between two `HH:MM` times; an exit at or before the entry means
  /// the next day (night shift).
  static int minutesBetween(String from, String to) {
    final a = parseClock(from), b = parseClock(to);
    if (a == null || b == null) return 0;
    var d = b - a;
    if (d <= 0) d += 24 * 60;
    return d;
  }

  /// `HH:MM` (also `H:M`, Persian digits are expected to be converted by the caller) -> minutes after midnight.
  static int? parseClock(String s) {
    final m = RegExp(r'^\s*(\d{1,2})\s*[:٫.]\s*(\d{1,2})\s*$').firstMatch(s);
    if (m == null) return null;
    final h = int.parse(m[1]!), min = int.parse(m[2]!);
    if (h > 23 || min > 59) return null;
    return h * 60 + min;
  }

  static String clockText(int minutes) {
    final m = minutes % (24 * 60);
    return '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
  }

  static int _round(double v) => v.isNaN || v.isInfinite ? 0 : v.round();

  /// Calculates one payslip.
  static PayCalc calculate(PayInput x) {
    final dailyMin = (x.dailyHours * 60).round();
    final requiredMin = x.workdays * dailyMin;

    // Per day: total work minutes; overtime is what exceeds the daily hours
    // (all of it on a day off), only when an overtime rate is set.
    final work = <String, int>{};
    var leave = 0;
    for (final e in x.entries) {
      if (e.leave) {
        leave += e.minutes;
      } else {
        work[e.date] = (work[e.date] ?? 0) + e.minutes;
      }
    }
    final workedMin = work.values.fold<int>(0, (a, b) => a + b);
    var overtime = 0;
    if (x.overtimeRate > 0) {
      work.forEach((date, m) {
        overtime += x.offDates.contains(date) ? m : math.max(0, m - dailyMin);
      });
    }
    final normal = workedMin - overtime;
    final present = normal + leave;
    final ratio = requiredMin > 0 ? math.min(1.0, present / requiredMin) : 1.0;
    final days = work.values.where((m) => m > 0).length;

    // The hourly value of one hour, used for overtime.
    final hourly = x.payType == 'hourly' ? x.base.toDouble() : (requiredMin > 0 ? x.base / (requiredMin / 60) : 0.0);

    var basePay = 0;
    var shortfall = 0;
    switch (x.payType) {
      case 'hourly':
        basePay = _round(x.base * present / 60);
      case 'contract':
        basePay = x.contractMonths > 0 ? _round(x.base / x.contractMonths) : x.base;
      case 'formula':
        basePay = _round(Expr.evaluate(x.formula, {
          'base': x.base.toDouble(),
          'hours': present / 60,
          'worked': workedMin / 60,
          'overtime': overtime / 60,
          'leave': leave / 60,
          'required': requiredMin / 60,
          'days': days.toDouble(),
          'workdays': x.workdays.toDouble(),
          'monthdays': x.monthDays.toDouble(),
          'daily': x.dailyHours,
          'ratio': ratio,
          'otrate': x.overtimeRate,
        }));
      default: // monthly
        if (x.attendanceBased) {
          basePay = _round(x.base * ratio);
          shortfall = x.base - basePay;
        } else {
          basePay = x.base;
        }
    }
    if (x.manualBase != null) {
      basePay = x.manualBase!;
      shortfall = 0;
    }
    final otPay = x.overtimeRate > 0 && x.payType != 'contract' && x.payType != 'formula' ? _round(hourly * x.overtimeRate * overtime / 60) : 0;
    final insurance = _round((basePay + otPay) * x.insurancePercent / 100);
    final net = basePay + otPay + x.additions - insurance - x.manualDeductions;
    return PayCalc(
      workedMin: workedMin,
      leaveMin: leave,
      overtimeMin: overtime,
      requiredMin: requiredMin,
      daysPresent: days,
      basePay: basePay,
      overtimePay: otPay,
      additions: x.additions,
      manualDeductions: x.manualDeductions,
      insurance: insurance,
      net: net,
      shortfall: shortfall,
      ratio: ratio,
    );
  }

  /// Working days of the Gregorian date range [from, toExclusive): every day
  /// that is not one of [offWeekdays] (DateTime.weekday, Monday = 1) and not
  /// in [holidays] (ISO dates), from [start] on when given.
  static ({int workdays, Set<String> offDates, int monthDays}) monthDays(DateTime from, DateTime toExclusive, Set<int> offWeekdays, Set<String> holidays, {String? start}) {
    var work = 0, total = 0;
    final off = <String>{};
    for (var d = from; d.isBefore(toExclusive); d = DateTime(d.year, d.month, d.day + 1)) {
      total++;
      final iso = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final isOff = offWeekdays.contains(d.weekday) || holidays.contains(iso);
      if (isOff) off.add(iso);
      if (!isOff && (start == null || start.isEmpty || iso.compareTo(start) >= 0)) work++;
    }
    return (workdays: work, offDates: off, monthDays: total);
  }
}
