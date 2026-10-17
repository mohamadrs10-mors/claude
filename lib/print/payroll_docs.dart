import '../data/payroll.dart';
import '../data/payroll_repo.dart';
import '../util/format.dart';
import 'report_doc.dart';

String hoursText(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  return faDigits(m == 0 ? '$h' : '$h:${m.toString().padLeft(2, '0')}');
}

String monthTitle(int year, int month) => '${monthNames[month - 1]} ${faDigits('$year')}';

/// The payslip of one person (فیش حقوقی): hours, every amount and the net.
ReportDoc payslipDoc(Employee e, int year, int month, PayCalc c, List<PayItem> items, {int paid = 0, bool isFinal = false}) {
  final adds = items.where((i) => i.isAdd).toList();
  final deds = items.where((i) => !i.isAdd).toList();
  return ReportDoc(
    title: 'فیش حقوقی ${e.name}',
    subtitle: '${monthTitle(year, month)} • ${payTypeLabel(e.payType)}${isFinal ? '' : ' • پیش‌نویس'}',
    summary: [
      ('خالص پرداختی', moneyC(c.net)),
      ('پرداخت‌شده', moneyC(paid)),
      ('باقی‌مانده', moneyC(c.net - paid)),
    ],
    tables: [
      ReportTable(
        heading: 'ساعت‌ها',
        headers: const ['شرح', 'مقدار'],
        cols: const [Col.text, Col.number],
        flex: const [3, 1.5],
        rows: [
          ['ساعت حضور', hoursText(c.workedMin)],
          ['اضافه‌کار', hoursText(c.overtimeMin)],
          if (c.leaveMin > 0) ['مرخصی با حقوق', hoursText(c.leaveMin)],
          if (c.requiredMin > 0) ['موظفی ماه', hoursText(c.requiredMin)],
          if (c.daysPresent > 0) ['روزهای حضور', faDigits('${c.daysPresent}')],
        ],
      ),
      ReportTable(
        heading: 'محاسبه',
        headers: const ['شرح', 'مبلغ'],
        cols: const [Col.text, Col.number],
        flex: const [3, 1.5],
        rows: [
          [switch (e.payType) { 'hourly' => 'حقوق ساعتی', 'contract' => 'مبلغ این دوره از قرارداد', 'formula' => 'حقوق (بر اساس فرمول)', _ => 'حقوق پایه' }, money(c.basePay)],
          if (c.shortfall > 0) ['کسر کار (ساعت‌های حضور کمتر از موظفی)', '-${money(c.shortfall)}'],
          if (c.overtimePay > 0) ['اضافه‌کار', money(c.overtimePay)],
          for (final i in adds) [i.title, money(i.amount)],
          if (c.insurance > 0) ['کسر بیمه و مالیات (${faDigits(plainNum(e.insurancePercent))}٪)', '-${money(c.insurance)}'],
          for (final i in deds) [i.title, '-${money(i.amount)}'],
        ],
        totals: ['خالص پرداختی', money(c.net)],
      ),
    ],
  );
}

/// All payslips of a month in one list.
ReportDoc payrollListDoc(int year, int month, List<(Employee, PayCalc, int paid, String status)> rows) {
  final net = rows.fold<int>(0, (a, r) => a + r.$2.net);
  final paid = rows.fold<int>(0, (a, r) => a + r.$3);
  return ReportDoc(
    title: 'لیست حقوق ${monthTitle(year, month)}',
    summary: [('جمع خالص', moneyC(net)), ('پرداخت‌شده', moneyC(paid)), ('باقی‌مانده', moneyC(net - paid))],
    tables: [
      ReportTable(
        headers: const ['نام', 'نوع', 'ساعت حضور', 'اضافه‌کار', 'ناخالص', 'کسورات', 'خالص', 'پرداخت‌شده'],
        cols: const [Col.text, Col.text, Col.center, Col.center, Col.number, Col.number, Col.number, Col.number],
        flex: const [2.2, 1.4, 1.1, 1.1, 1.6, 1.4, 1.7, 1.6],
        rows: [
          for (final (e, c, p, _) in rows)
            [e.name, payTypeLabel(e.payType), hoursText(c.workedMin), hoursText(c.overtimeMin), money(c.gross), money(c.deductions), money(c.net), money(p)]
        ],
        totals: ['جمع', '', '', '', money(rows.fold<int>(0, (a, r) => a + r.$2.gross)), money(rows.fold<int>(0, (a, r) => a + r.$2.deductions)), money(net), money(paid)],
      ),
    ],
  );
}

/// The time clock of one person for a month.
ReportDoc attendanceDoc(Employee e, int year, int month, List<AttendanceEntry> list, PayCalc c) => ReportDoc(
      title: 'حضور و غیاب ${e.name}',
      subtitle: monthTitle(year, month),
      summary: [
        ('ساعت حضور', hoursText(c.workedMin)),
        ('اضافه‌کار', hoursText(c.overtimeMin)),
        ('مرخصی', hoursText(c.leaveMin)),
        ('موظفی ماه', hoursText(c.requiredMin)),
      ],
      tables: [
        ReportTable(
          headers: const ['تاریخ', 'ورود', 'خروج', 'مدت', 'توضیح'],
          cols: const [Col.center, Col.center, Col.center, Col.center, Col.text],
          flex: const [1.6, 1, 1, 1, 3],
          rows: [
            for (final a in list)
              [jalaliText(a.date), a.leave ? 'مرخصی' : faDigits(a.inTime), a.leave ? '' : (a.open ? '—' : faDigits(a.outTime)), hoursText(a.minutes), a.note]
          ],
        ),
      ],
    );
