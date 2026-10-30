import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/costing.dart';
import '../data/payroll.dart';
import '../data/payroll_repo.dart';
import '../data/repo.dart';
import '../print/payroll_docs.dart';
import '../util/format.dart';
import 'auth.dart';
import 'common.dart';
import 'print_dialog.dart';

String _msg(Object e) => e is StateError ? e.message : '$e';

/// Year and month of the Jalali calendar the screens work on.
class YearMonth {
  YearMonth(this.year, this.month);
  factory YearMonth.now() {
    final n = Jalali.now();
    return YearMonth(n.year, n.month);
  }
  final int year, month;
  YearMonth shift(int d) {
    var y = year, m = month + d;
    while (m > 12) {
      m -= 12;
      y++;
    }
    while (m < 1) {
      m += 12;
      y--;
    }
    return YearMonth(y, m);
  }

  String get label => monthTitle(year, month);
}

class MonthBar extends StatelessWidget {
  const MonthBar({super.key, required this.value, required this.onChanged});
  final YearMonth value;
  final ValueChanged<YearMonth> onChanged;

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(tooltip: 'ماه قبل', onPressed: () => onChanged(value.shift(-1)), icon: const Icon(Icons.chevron_right)),
        SizedBox(width: 150, child: Text(value.label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
        IconButton(tooltip: 'ماه بعد', onPressed: () => onChanged(value.shift(1)), icon: const Icon(Icons.chevron_left)),
      ]);
}

/// Payroll (حقوق و دستمزد): people, time clock and monthly payslips.
class PayrollPage extends StatelessWidget {
  const PayrollPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Column(children: [
          const TabBar(tabs: [Tab(text: 'حقوق و فیش‌ها'), Tab(text: 'حضور و غیاب'), Tab(text: 'کارکنان')]),
          Expanded(child: TabBarView(children: [PayslipsTab(repo: repo), AttendanceTab(repo: repo), EmployeesTab(repo: repo)])),
        ]),
      );
}

// ---- employees ---------------------------------------------------------------

const _weekdays = <(int, String)>[(6, 'شنبه'), (7, 'یکشنبه'), (1, 'دوشنبه'), (2, 'سه‌شنبه'), (3, 'چهارشنبه'), (4, 'پنجشنبه'), (5, 'جمعه')];

class EmployeesTab extends StatelessWidget {
  const EmployeesTab({super.key, required this.repo});
  final Repo repo;

  Future<void> _merge(BuildContext context, List<Employee> group, Map<String, int> counts) async {
    // Keep the one with the most time-clock entries by default.
    var keep = ([...group]..sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0))).first.id;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text('ادغام «${group.first.name}»'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('این نام چند بار ثبت شده (مثلاً یک بار روی هر دستگاه). ساعت‌های ورود و خروج، فیش‌ها و مساعده‌های بقیه به نفری که نگه می‌دارید منتقل می‌شود و تکراری‌ها حذف می‌شوند.', style: Theme.of(dc).textTheme.bodySmall),
              gap(),
              RadioGroup<String>(
                groupValue: keep,
                onChanged: (v) => set(() => keep = v ?? keep),
                child: Column(children: [
                  for (final e in group)
                    RadioListTile<String>(value: e.id, title: Text(e.name), subtitle: Text('${e.payText} • ${faDigits('${counts[e.id] ?? 0}')} ردیف حضور')),
                ]),
              ),
              if (error != null) Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                try {
                  for (final e in group) {
                    if (e.id != keep) await repo.mergeEmployees(keep, e.id);
                  }
                  if (dc.mounted) Navigator.pop(dc);
                } catch (err) {
                  set(() => error = _msg(err));
                }
              },
              child: const Text('ادغام'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('payroll');
    return RepoBuilder<(List<Employee>, Map<String, int>, List<List<Employee>>)>(
      repo: repo,
      load: () async => (await repo.employees(), await repo.attendanceCounts(), await repo.duplicateEmployees()),
      builder: (c, data) {
        final (list, counts, dups) = data;
        return Scaffold(
          body: Constrained(
            child: list.isEmpty
                ? emptyState('هنوز کسی ثبت نشده است.\nبا «کارمند جدید» شروع کنید؛ برای هر نفر شیوهٔ پرداخت جداگانه تعیین می‌شود (ماهانه، ساعتی، قراردادی یا فرمول دلخواه).')
                : ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
                    for (final g in dups)
                      Card(
                        color: Theme.of(c).colorScheme.tertiaryContainer,
                        child: ListTile(
                          leading: const Icon(Icons.merge_type),
                          title: Text('«${g.first.name}» ${faDigits('${g.length}')} بار ثبت شده است'),
                          subtitle: const Text('ساعت‌های حضور ممکن است زیر نفر دیگری باشند؛ با ادغام همه یکی می‌شوند.'),
                          trailing: !canEdit ? null : TextButton(onPressed: () => _merge(c, g, counts), child: const Text('ادغام')),
                        ),
                      ),
                    Card(
                      child: Column(children: [
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            leading: CircleAvatar(child: Text(list[i].name.characters.first)),
                            title: Text(list[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${list[i].payText} • ${faDigits('${counts[list[i].id] ?? 0}')} ردیف حضور'),
                            trailing: list[i].active ? null : StatusChip('غیرفعال', Colors.grey),
                            onTap: !canEdit ? null : () => editEmployee(c, repo, list[i]),
                          ),
                        ],
                      ]),
                    ),
                  ]),
          ),
          floatingActionButton: !canEdit ? null : FloatingActionButton.extended(onPressed: () => editEmployee(c, repo, null), icon: const Icon(Icons.person_add_alt), label: const Text('کارمند جدید')),
        );
      },
    );
  }
}

Future<void> editEmployee(BuildContext context, Repo repo, Employee? e) async {
  final name = TextEditingController(text: e?.name);
  final phone = TextEditingController(text: e?.phone);
  final base = TextEditingController(text: e == null || e.base == 0 ? '' : inputNum(e.base, decimals: 0));
  final daily = TextEditingController(text: plainNum(e?.dailyHours ?? 8));
  final ot = TextEditingController(text: e == null || e.overtimeRate == 0 ? '' : plainNum(e.overtimeRate));
  final ins = TextEditingController(text: e == null || e.insurancePercent == 0 ? '' : plainNum(e.insurancePercent));
  final formula = TextEditingController(text: e?.formula);
  final months = TextEditingController(text: e == null || e.contractMonths == 0 ? '' : '${e.contractMonths}');
  final note = TextEditingController(text: e?.note);
  var type = e?.payType ?? 'monthly';
  var attendance = e?.attendanceBased ?? true;
  var active = e?.active ?? true;
  var off = {...(e?.offDays ?? {5})};
  String start = e?.startDate ?? '';
  String? error;

  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: Text(e == null ? 'کارمند جدید' : 'ویرایش ${e.name}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: name, autofocus: e == null, decoration: const InputDecoration(labelText: 'نام')),
              gap(),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'تلفن (اختیاری)')),
              gap(),
              const Text('شیوهٔ پرداخت'),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 6, children: [
                for (final (id, title) in payTypes) ChoiceChip(label: Text(title), selected: type == id, onSelected: (_) => set(() => type = id)),
              ]),
              gap(),
              AmountField(
                controller: base,
                label: switch (type) { 'hourly' => 'مبلغ هر ساعت', 'contract' => 'کل مبلغ قرارداد', 'formula' => 'مبلغ پایه (متغیر base در فرمول)', _ => 'حقوق ماهانه' },
              ),
              if (type == 'monthly') ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('حقوق بر اساس ساعت حضور'),
                  subtitle: const Text('روشن: هر ساعتی که کمتر از موظفی کار کند، متناسب کم می‌شود. خاموش: حقوق ثابت است.'),
                  value: attendance,
                  onChanged: (v) => set(() => attendance = v),
                ),
              ],
              if (type == 'contract') ...[
                gap(),
                TextField(controller: months, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'تعداد ماه یا قسط قرارداد', helperText: 'هر فیش به‌طور پیش‌فرض یک قسط برابر است؛ مبلغ هر فیش را می‌توانید دستی عوض کنید')),
              ],
              if (type == 'formula') ...[
                gap(),
                TextField(
                  controller: formula,
                  minLines: 2,
                  maxLines: 4,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(labelText: 'فرمول حقوق', hintText: 'min(hours,160)*base + max(hours-160,0)*base*1.5'),
                ),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final (v, d) in formulaVariables)
                    Tooltip(
                      message: d,
                      child: ActionChip(
                        label: Text(v, textDirection: TextDirection.ltr),
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          formula.text = '${formula.text}${formula.text.isEmpty || formula.text.endsWith(' ') ? '' : ' '}$v';
                          set(() {});
                        },
                      ),
                    ),
                ]),
                const SizedBox(height: 4),
                Text('جمع، تفریق، ضرب، تقسیم، توان (^)، درصد (10%)، پرانتز و توابع round ceil floor abs sqrt min max و if(شرط، اگر درست، اگر نادرست) با مقایسهٔ > < >= <= == !=؛ مثلاً if(ratio >= 1, 500000, 0) پاداش حضور کامل.', style: Theme.of(dc).textTheme.bodySmall),
              ],
              gap(),
              Row(children: [
                Expanded(child: TextField(controller: daily, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'ساعت کار روزانه'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: ot, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'ضریب اضافه‌کار', helperText: 'خالی = بدون اضافه‌کار (مثلاً ۱٫۴)'))),
              ]),
              gap(),
              TextField(controller: ins, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'کسر بیمه و مالیات (درصد، اختیاری)', suffixText: '٪')),
              gap(),
              const Text('روزهای تعطیل هفتگی'),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                for (final (d, t) in _weekdays)
                  FilterChip(label: Text(t), selected: off.contains(d), onSelected: (v) => set(() => v ? off.add(d) : off.remove(d))),
              ]),
              gap(),
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(start.isEmpty ? 'تاریخ شروع کار (اختیاری)' : 'شروع کار: ${faDigits(jalaliText(start))}'),
                  onPressed: () async {
                    final r = await showDialog<String>(context: dc, builder: (_) => JalaliPickerDialog(start.isEmpty ? todayIso() : start));
                    if (r != null) set(() => start = r);
                  },
                ),
                if (start.isNotEmpty) IconButton(tooltip: 'حذف', icon: const Icon(Icons.close), onPressed: () => set(() => start = '')),
              ]),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فعال'), value: active, onChanged: (v) => set(() => active = v)),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات')),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
        ),
        actions: [
          if (e != null)
            TextButton(
              onPressed: () async {
                if (!await confirm(dc, 'این شخص حذف شود؟ اگر فیش حقوقی دارد فقط غیرفعال می‌شود.')) return;
                final msg = await repo.deleteEmployee(e.id);
                if (dc.mounted) Navigator.pop(dc);
                if (msg != null && context.mounted) toast(context, msg);
              },
              child: const Text('حذف'),
            ),
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              try {
                await repo.saveEmployee(
                  id: e?.id,
                  name: name.text,
                  phone: enDigits(phone.text.trim()),
                  payType: type,
                  base: parseAmount(base.text),
                  attendanceBased: attendance,
                  dailyHours: parseNum(daily.text),
                  overtimeRate: parseNum(ot.text),
                  insurancePercent: parseNum(ins.text),
                  formula: formula.text,
                  contractMonths: int.tryParse(enDigits(months.text.trim())) ?? 0,
                  offDays: off,
                  startDate: start,
                  active: active,
                  note: note.text.trim(),
                );
                if (dc.mounted) Navigator.pop(dc);
              } catch (err) {
                set(() => error = _msg(err));
              }
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    ),
  );
}

// ---- time clock ----------------------------------------------------------------

class AttendanceTab extends StatefulWidget {
  const AttendanceTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<AttendanceTab> createState() => _AttendanceTabState();
}

class _AttendanceTabState extends State<AttendanceTab> {
  String? employeeId;
  YearMonth ym = YearMonth.now();

  Repo get repo => widget.repo;

  Future<void> _run(Future<void> Function() job) async {
    try {
      await job();
    } catch (e) {
      if (mounted) toast(context, _msg(e));
    }
  }

  Future<(List<AttendanceEntry>, PayCalc)> _attendanceData(Employee e, String from, String to) async {
    final list = await repo.attendanceOf(e.id, from: from, toExclusive: to);
    return (list, await repo.calcPayslip(e, ym.year, ym.month));
  }

  Future<void> _manual(Employee e) async {
    var date = todayIso(), kind = 'work';
    final inT = TextEditingController(), outT = TextEditingController(), note = TextEditingController(), leaveH = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text('ثبت حضور ${e.name}'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                JalaliDateField(iso: date, onChanged: (v) => set(() => date = v)),
                gap(),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: 'work', label: Text('حضور')), ButtonSegment(value: 'leave', label: Text('مرخصی با حقوق'))],
                  selected: {kind},
                  onSelectionChanged: (v) => set(() => kind = v.first),
                ),
                gap(),
                if (kind == 'work')
                  Row(children: [
                    Expanded(child: TextField(controller: inT, textDirection: TextDirection.ltr, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'ورود', hintText: '08:30'))),
                    const SizedBox(width: 12),
                    Expanded(child: TextField(controller: outT, textDirection: TextDirection.ltr, keyboardType: TextInputType.datetime, decoration: const InputDecoration(labelText: 'خروج', hintText: '17:00', helperText: 'خالی = هنوز در محل'))),
                  ])
                else
                  TextField(controller: leaveH, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'ساعت مرخصی', helperText: 'خالی = یک روز کامل (${faDigits(plainNum(e.dailyHours))} ساعت)')),
                gap(),
                TextField(controller: note, decoration: const InputDecoration(labelText: 'توضیح (اختیاری)')),
                if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                try {
                  await repo.saveAttendance(
                    employeeId: e.id,
                    date: date,
                    kind: kind,
                    inTime: inT.text,
                    outTime: outT.text,
                    leaveMinutes: leaveH.text.trim().isEmpty ? null : (parseNum(leaveH.text) * 60).round(),
                    note: note.text.trim(),
                  );
                  if (dc.mounted) Navigator.pop(dc);
                } catch (err) {
                  set(() => error = _msg(err));
                }
              },
              child: const Text('ثبت'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _holidays() async {
    var set0 = repo.payrollHolidays;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: const Text('تعطیلات رسمی'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('روزهای تعطیل رسمی برای همهٔ کارکنان از موظفی ماه کم می‌شود و کار در این روزها اضافه‌کار حساب می‌شود (اگر ضریب اضافه‌کار داشته باشد).', style: Theme.of(dc).textTheme.bodySmall),
              gap(),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final d in (set0.toList()..sort()))
                  InputChip(
                    label: Text(faDigits(jalaliText(d))),
                    onDeleted: () async {
                      set0 = {...set0}..remove(d);
                      await repo.setPayrollHolidays(set0);
                      set(() {});
                    },
                  ),
              ]),
              gap(),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('افزودن روز تعطیل'),
                onPressed: () async {
                  final r = await showDialog<String>(context: dc, builder: (_) => JalaliPickerDialog(todayIso()));
                  if (r == null) return;
                  set0 = {...set0, r};
                  await repo.setPayrollHolidays(set0);
                  set(() {});
                },
              ),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('بستن'))],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('payroll');
    return RepoBuilder<List<Employee>>(
      repo: repo,
      load: () => repo.employees(onlyActive: true),
      builder: (c, people) {
        if (people.isEmpty) return emptyState('اول از تب «کارکنان» یک نفر اضافه کنید.');
        final e = people.firstWhere((p) => p.id == employeeId, orElse: () => people.first);
        final (from, to) = jalaliMonthRange(ym.year, ym.month);
        return Constrained(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                isExpanded: true,
                  key: ValueKey(e.id),
                  initialValue: e.id,
                  decoration: const InputDecoration(labelText: 'شخص', isDense: true),
                  items: [for (final p in people) DropdownMenuItem(value: p.id, child: Text(p.name))],
                  onChanged: (v) => setState(() => employeeId = v),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(tooltip: 'تعطیلات رسمی', onPressed: _holidays, icon: const Icon(Icons.event_busy_outlined)),
            ]),
            MonthBar(value: ym, onChanged: (v) => setState(() => ym = v)),
            FutureBuilder<(List<AttendanceEntry>, PayCalc)>(
              future: _attendanceData(e, from, to),
              builder: (c, snap) {
                final data = snap.data;
                if (data == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
                final (list, calc) = data;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: StatCard(title: 'ساعت حضور', value: hoursText(calc.workedMin), icon: Icons.schedule, color: Theme.of(c).colorScheme.primary)),
                    const SizedBox(width: 10),
                    Expanded(child: StatCard(title: 'موظفی ماه', value: hoursText(calc.requiredMin), icon: Icons.flag_outlined, color: Colors.indigo)),
                    const SizedBox(width: 10),
                    Expanded(child: StatCard(title: 'اضافه‌کار', value: hoursText(calc.overtimeMin), icon: Icons.more_time, color: Colors.orange)),
                  ]),
                  gap(),
                  if (canEdit)
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      FilledButton.icon(onPressed: () => _run(() => repo.clockIn(e.id)), icon: const Icon(Icons.login), label: const Text('ورود الان')),
                      FilledButton.tonalIcon(
                        onPressed: () => _run(() async {
                          final done = await repo.clockOut(e.id);
                          if (!done && mounted) toast(this.context, 'ورودِ بدون خروجی برای این شخص نیست.');
                        }),
                        icon: const Icon(Icons.logout),
                        label: const Text('خروج الان'),
                      ),
                      OutlinedButton.icon(onPressed: () => _manual(e), icon: const Icon(Icons.edit_calendar_outlined), label: const Text('ثبت دستی')),
                      PrintButton(repo: repo, label: 'چاپ', doc: () => attendanceDoc(e, ym.year, ym.month, list, calc)),
                    ]),
                  gap(),
                  if (list.isEmpty)
                    emptyState('در این ماه حضوری ثبت نشده است.')
                  else
                    Card(
                      child: Column(children: [
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            dense: true,
                            leading: Icon(list[i].leave ? Icons.beach_access_outlined : (list[i].open ? Icons.timelapse : Icons.schedule)),
                            title: Text(faDigits(jalaliText(list[i].date))),
                            subtitle: Text(list[i].leave
                                ? 'مرخصی با حقوق • ${hoursText(list[i].minutes)} ساعت'
                                : '${faDigits(list[i].inTime)} تا ${list[i].open ? 'هنوز در محل' : faDigits(list[i].outTime)}${list[i].note.isEmpty ? '' : ' • ${list[i].note}'}'),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('${hoursText(list[i].minutes)} ساعت', style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (canEdit)
                                IconButton(
                                  tooltip: 'حذف',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _run(() async {
                                    if (await confirm(c, 'این ردیف حذف شود؟')) await repo.deleteAttendance(list[i].id);
                                  }),
                                ),
                            ]),
                          ),
                        ],
                      ]),
                    ),
                ]);
              },
            ),
          ]),
        );
      },
    );
  }
}

// ---- payslips --------------------------------------------------------------------

class PayslipsTab extends StatefulWidget {
  const PayslipsTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<PayslipsTab> createState() => _PayslipsTabState();
}

typedef _Row = (Employee, PayCalc, int paid, String status);

class _PayslipsTabState extends State<PayslipsTab> {
  YearMonth ym = YearMonth.now();
  Repo get repo => widget.repo;

  Future<List<_Row>> _load() async {
    final out = <_Row>[];
    for (final e in await repo.employees(onlyActive: true)) {
      final s = await repo.payslipOf(e.id, ym.year, ym.month);
      if (s != null) {
        out.add((e, s.isFinal ? s.calc : await _live(e, s), s.paid, s.status));
      } else {
        try {
          out.add((e, await repo.calcPayslip(e, ym.year, ym.month), 0, 'none'));
        } on FormatException {
          out.add((e, PayCalc(workedMin: 0, leaveMin: 0, overtimeMin: 0, requiredMin: 0, daysPresent: 0, basePay: 0, overtimePay: 0, additions: 0, manualDeductions: 0, insurance: 0, net: 0, shortfall: 0, ratio: 0), 0, 'error'));
        }
      }
    }
    return out;
  }

  /// A draft follows the time clock as it is now.
  Future<PayCalc> _live(Employee e, Payslip s) => repo.calcPayslip(e, s.year, s.month, manualBase: s.manualBase, items: s.items);

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('payroll');
    return RepoBuilder<List<_Row>>(
      repo: repo,
      load: _load,
      builder: (c, rows) {
        final net = rows.fold<int>(0, (a, r) => a + r.$2.net);
        final paid = rows.fold<int>(0, (a, r) => a + r.$3);
        return Constrained(
          child: ListView(padding: const EdgeInsets.all(16), children: [
            MonthBar(value: ym, onChanged: (v) => setState(() => ym = v)),
            Row(children: [
              Expanded(child: StatCard(title: 'جمع خالص حقوق', value: moneyC(net), icon: Icons.payments_outlined, color: Theme.of(c).colorScheme.primary)),
              const SizedBox(width: 10),
              Expanded(child: StatCard(title: 'پرداخت‌شده', value: moneyC(paid), icon: Icons.check_circle_outline, color: Colors.green)),
              const SizedBox(width: 10),
              Expanded(child: StatCard(title: 'باقی‌مانده', value: moneyC(net - paid), icon: Icons.hourglass_bottom, color: net - paid > 0 ? Colors.orange : Colors.green)),
            ]),
            gap(),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (canEdit)
                OutlinedButton.icon(
                  icon: const Icon(Icons.auto_fix_high),
                  label: const Text('ساخت فیش همه (پیش‌نویس)'),
                  onPressed: () async {
                    var made = 0;
                    for (final (e, _, _, status) in rows) {
                      if (status == 'none') {
                        try {
                          await repo.savePayslip(e, ym.year, ym.month);
                          made++;
                        } catch (_) {}
                      }
                    }
                    if (c.mounted) toast(c, made == 0 ? 'فیش تازه‌ای برای ساخت نبود.' : 'فیش ${faDigits('$made')} نفر ساخته شد.');
                  },
                ),
              PrintButton(repo: repo, label: 'چاپ لیست حقوق', doc: () => payrollListDoc(ym.year, ym.month, rows)),
            ]),
            gap(),
            if (rows.isEmpty)
              emptyState('کارمند فعالی نیست. از تب «کارکنان» اضافه کنید.')
            else
              Card(
                child: Column(children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      leading: CircleAvatar(child: Text(rows[i].$1.name.characters.first)),
                      title: Text(rows[i].$1.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${payTypeLabel(rows[i].$1.payType)} • ${hoursText(rows[i].$2.workedMin)} ساعت حضور${rows[i].$2.overtimeMin > 0 ? ' • ${hoursText(rows[i].$2.overtimeMin)} اضافه‌کار' : ''}'),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(money(rows[i].$2.net), style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        switch (rows[i].$4) {
                          'final' => rows[i].$3 >= rows[i].$2.net && rows[i].$2.net > 0 ? StatusChip('پرداخت شد', Colors.green.shade700) : StatusChip('نهایی', Colors.blue.shade700),
                          'draft' => StatusChip('پیش‌نویس', Colors.orange.shade800),
                          'error' => StatusChip('فرمول خطا دارد', Colors.red.shade700),
                          _ => StatusChip('فیش نشده', Colors.grey),
                        },
                      ]),
                      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => PayslipPage(repo: repo, employeeId: rows[i].$1.id, year: ym.year, month: ym.month))),
                    ),
                  ],
                ]),
              ),
          ]),
        );
      },
    );
  }
}

/// One person's payslip for a month: what it is made of, additions and
/// deductions, saving, finalising, paying and printing.
class PayslipPage extends StatefulWidget {
  const PayslipPage({super.key, required this.repo, required this.employeeId, required this.year, required this.month});
  final Repo repo;
  final String employeeId;
  final int year, month;
  @override
  State<PayslipPage> createState() => _PayslipPageState();
}

class _PayslipPageState extends State<PayslipPage> {
  Employee? e;
  Payslip? saved;
  List<PayItem> items = [];
  int? manualBase;
  PayCalc? calc;
  String? problem;
  var loaded = false;
  List<(String, String, int, String)> advances = [];
  ({int total, int accrued, int remaining})? contract;

  Repo get repo => widget.repo;
  bool get isFinal => saved?.isFinal ?? false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool keepEdits = false}) async {
    final emp = await repo.employee(widget.employeeId);
    if (emp == null) return;
    final s = await repo.payslipOf(emp.id, widget.year, widget.month);
    if (!keepEdits && s != null) {
      items = [...s.items];
      manualBase = s.manualBase;
    }
    e = emp;
    saved = s;
    advances = await repo.outstandingAdvances(emp.id);
    if (emp.payType == 'contract') contract = await repo.contractSummary(emp);
    await _recalc();
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _recalc() async {
    final emp = e!;
    if (isFinal) {
      calc = saved!.calc;
      problem = null;
      return;
    }
    try {
      calc = await repo.calcPayslip(emp, widget.year, widget.month, manualBase: manualBase, items: items);
      problem = null;
    } on FormatException catch (err) {
      problem = 'فرمول جواب نداد: ${err.message}';
      calc = null;
    }
  }

  Future<void> _change(void Function() f) async {
    f();
    await _recalc();
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() job) async {
    try {
      await job();
    } catch (err) {
      if (mounted) toast(context, _msg(err));
    }
  }

  Future<void> _addItem(bool add) async {
    final title = TextEditingController(), amount = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text(add ? 'افزودن (پاداش، حق مسکن، ...)' : 'کسر (جریمه، وام، ...)'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'عنوان')),
          gap(),
          AmountField(controller: amount, label: 'مبلغ'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('افزودن')),
        ],
      ),
    );
    if (ok != true) return;
    final v = parseAmount(amount.text);
    if (v <= 0 || title.text.trim().isEmpty) return;
    await _change(() => items = [...items, PayItem(kind: add ? 'add' : 'deduct', title: title.text.trim(), amount: v)]);
  }

  Future<void> _manualBase() async {
    final c = TextEditingController(text: manualBase == null ? '' : inputNum(manualBase!, decimals: 0));
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('تغییر دستی مبلغ پایه'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('مبلغی که اینجا بنویسید جای مبلغ محاسبه‌شده را می‌گیرد. خالی = محاسبهٔ خودکار.', style: Theme.of(dc).textTheme.bodySmall),
          gap(),
          AmountField(controller: c, label: 'مبلغ پایه'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('تأیید')),
        ],
      ),
    );
    if (ok != true) return;
    await _change(() => manualBase = c.text.trim().isEmpty ? null : parseAmount(c.text));
  }

  Future<void> _save({String status = 'draft'}) => _run(() async {
        await repo.savePayslip(e!, widget.year, widget.month, manualBase: manualBase, items: items, status: status, note: saved?.note ?? '');
        await _load(keepEdits: true);
        if (mounted) toast(context, status == 'final' ? 'فیش نهایی شد.' : 'فیش ذخیره شد.');
      });

  Future<void> _pay() async {
    final s = saved;
    if (s == null) return;
    final accounts = await repo.accounts();
    if (!mounted) return;
    if (accounts.isEmpty) return toast(context, 'اول یک حساب (صندوق یا بانک) تعریف کنید.');
    String account = accounts.first.id, date = todayIso();
    final amount = TextEditingController(text: inputNum(s.remaining, decimals: 0));
    final note = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: const Text('پرداخت حقوق'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('باقی‌ماندهٔ فیش: ${moneyC(s.remaining)}', style: Theme.of(dc).textTheme.bodySmall),
              gap(),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: account,
                decoration: const InputDecoration(labelText: 'از حساب'),
                items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text('${a.name} • ${moneyC(a.balance)}'))],
                onChanged: (v) => account = v ?? account,
              ),
              gap(),
              AmountField(controller: amount, label: 'مبلغ پرداخت'),
              gap(),
              JalaliDateField(iso: date, onChanged: (v) => set(() => date = v)),
              gap(),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'توضیح (اختیاری)')),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                try {
                  await repo.payPayslip(payslipId: s.id, accountId: account, amount: parseAmount(amount.text), date: date, note: note.text.trim());
                  if (dc.mounted) Navigator.pop(dc);
                } catch (err) {
                  set(() => error = _msg(err));
                }
              },
              child: const Text('ثبت پرداخت'),
            ),
          ],
        ),
      ),
    );
    await _load(keepEdits: true);
  }

  Future<void> _advance() async {
    final accounts = await repo.accounts();
    if (!mounted) return;
    if (accounts.isEmpty) return toast(context, 'اول یک حساب (صندوق یا بانک) تعریف کنید.');
    String account = accounts.first.id, date = todayIso();
    final amount = TextEditingController();
    final note = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text('پرداخت مساعده به ${e!.name}'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: account,
                decoration: const InputDecoration(labelText: 'از حساب'),
                items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => account = v ?? account,
              ),
              gap(),
              AmountField(controller: amount, label: 'مبلغ مساعده'),
              gap(),
              JalaliDateField(iso: date, onChanged: (v) => set(() => date = v)),
              gap(),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'توضیح (اختیاری)')),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                try {
                  await repo.payAdvance(employeeId: e!.id, accountId: account, amount: parseAmount(amount.text), date: date, note: note.text.trim());
                  if (dc.mounted) Navigator.pop(dc);
                } catch (err) {
                  set(() => error = _msg(err));
                }
              },
              child: const Text('ثبت'),
            ),
          ],
        ),
      ),
    );
    await _load(keepEdits: true);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('payroll');
    final emp = e;
    if (!loaded || emp == null) return Scaffold(appBar: AppBar(title: const Text('فیش حقوقی')), body: const Center(child: CircularProgressIndicator()));
    final c = calc;
    final editable = canEdit && !isFinal;
    final open = advances.where((a) => !items.any((i) => i.txId == a.$1)).toList();
    Widget line(String t, String v, {bool bold = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(t, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null))),
            Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null, color: color)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: Text('فیش ${emp.name} • ${monthTitle(widget.year, widget.month)}')),
      body: Constrained(
        maxWidth: 760,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Expanded(child: Text(emp.payText, style: Theme.of(context).textTheme.bodyMedium)),
            StatusChip(isFinal ? 'نهایی' : (saved == null ? 'ذخیره‌نشده' : 'پیش‌نویس'), isFinal ? Colors.blue.shade700 : Colors.orange.shade800),
          ]),
          gap(),
          if (problem != null) Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(12), child: Text(problem!))),
          if (c != null) ...[
            Section(
              title: 'ساعت‌ها',
              child: Column(children: [
                line('ساعت حضور', hoursText(c.workedMin)),
                line('اضافه‌کار', hoursText(c.overtimeMin)),
                if (c.leaveMin > 0) line('مرخصی با حقوق', hoursText(c.leaveMin)),
                line('موظفی ماه', hoursText(c.requiredMin)),
                if (c.daysPresent > 0) line('روزهای حضور', faDigits('${c.daysPresent}')),
              ]),
            ),
            gap(),
            Section(
              title: 'محاسبه',
              child: Column(children: [
                line(switch (emp.payType) { 'hourly' => 'حقوق ساعتی', 'contract' => 'مبلغ این دوره از قرارداد', 'formula' => 'حقوق (فرمول)', _ => 'حقوق پایه' }, moneyC(c.basePay) + (manualBase != null ? ' (دستی)' : '')),
                if (c.shortfall > 0) line('  کسر کار (کمبود ساعت)', '-${moneyC(c.shortfall)}', color: Theme.of(context).colorScheme.error),
                if (c.overtimePay > 0) line('اضافه‌کار', moneyC(c.overtimePay)),
                for (final i in items)
                  Row(children: [
                    Expanded(child: Text(i.title)),
                    Text('${i.isAdd ? '' : '-'}${moneyC(i.amount)}', style: TextStyle(color: i.isAdd ? Colors.green.shade700 : Theme.of(context).colorScheme.error)),
                    if (editable) IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: () => _change(() => items = [...items]..remove(i))),
                  ]),
                if (c.insurance > 0) line('کسر بیمه و مالیات (${faDigits(plainNum(emp.insurancePercent))}٪)', '-${moneyC(c.insurance)}', color: Theme.of(context).colorScheme.error),
                const Divider(),
                line('خالص پرداختی', moneyC(c.net), bold: true),
                if (saved != null) ...[
                  line('پرداخت‌شده', moneyC(saved!.paid), color: Colors.green.shade700),
                  line('باقی‌مانده', moneyC(c.net - saved!.paid), bold: true),
                ],
              ]),
            ),
          ],
          if (contract != null) ...[
            gap(),
            Section(
              title: 'قرارداد',
              child: Column(children: [
                line('کل قرارداد', moneyC(contract!.total)),
                line('مجموع فیش‌های صادرشده (با این فیش اگر ذخیره باشد)', moneyC(contract!.accrued)),
                line('باقی‌ماندهٔ قرارداد', moneyC(contract!.remaining), bold: true),
              ]),
            ),
          ],
          gap(),
          if (editable)
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(onPressed: () => _addItem(true), icon: const Icon(Icons.add), label: const Text('افزودن (پاداش...)')),
              OutlinedButton.icon(onPressed: () => _addItem(false), icon: const Icon(Icons.remove), label: const Text('کسر (جریمه...)')),
              OutlinedButton.icon(onPressed: _manualBase, icon: const Icon(Icons.edit_outlined), label: const Text('مبلغ پایه دستی')),
              if (open.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _change(() => items = [...items, for (final a in open) PayItem(kind: 'deduct', title: 'کسر مساعده ${jalaliText(a.$2)}', amount: a.$3, txId: a.$1)]),
                  icon: const Icon(Icons.undo),
                  label: Text('کسر مساعده‌ها (${faDigits('${open.length}')})'),
                ),
              if (saved != null) OutlinedButton.icon(onPressed: () => _load(), icon: const Icon(Icons.refresh), label: const Text('بازگشت به فیش ذخیره‌شده')),
            ]),
          gap(),
          if (canEdit)
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (!isFinal) FilledButton.icon(onPressed: c == null ? null : () => _save(), icon: const Icon(Icons.save_outlined), label: const Text('ذخیرهٔ فیش')),
              if (!isFinal) FilledButton.tonalIcon(onPressed: c == null ? null : () => _save(status: 'final'), icon: const Icon(Icons.lock_outline), label: const Text('نهایی کردن')),
              if (isFinal) OutlinedButton.icon(onPressed: () => _run(() async {
                    await repo.setPayslipStatus(saved!.id, 'draft');
                    await _load();
                  }), icon: const Icon(Icons.lock_open), label: const Text('باز کردن فیش')),
              if (saved != null) FilledButton.icon(onPressed: saved!.remaining <= 0 ? null : _pay, icon: const Icon(Icons.payments_outlined), label: const Text('پرداخت')),
              OutlinedButton.icon(onPressed: _advance, icon: const Icon(Icons.request_quote_outlined), label: const Text('پرداخت مساعده')),
              if (saved != null)
                TextButton.icon(
                  onPressed: () => _run(() async {
                    if (!await confirm(context, 'این فیش حذف شود؟')) return;
                    final err = await repo.deletePayslip(saved!.id);
                    if (!mounted) return;
                    if (err != null) {
                      toast(this.context, err);
                      return;
                    }
                    Navigator.pop(this.context);
                  }),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف فیش'),
                ),
            ]),
          if (c != null) ...[
            gap(),
            PrintButton(repo: repo, label: 'چاپ فیش', doc: () => payslipDoc(emp, widget.year, widget.month, c, items, paid: saved?.paid ?? 0, isFinal: isFinal)),
          ],
          gap(24),
          Text('اگر ساعت حضور یا تنظیمات این شخص بعد از ذخیرهٔ فیش عوض شود، فیشِ پیش‌نویس هنگام باز شدن دوباره محاسبه می‌شود؛ فیش نهایی ثابت می‌ماند.', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// Checks a formula typed in the employee form (used by tests and previews).
String? checkPayFormula(String formula) {
  try {
    Expr.evaluate(formula, {for (final (v, _) in formulaVariables) v: 1});
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}
