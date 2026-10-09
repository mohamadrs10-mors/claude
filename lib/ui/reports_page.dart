import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  final now = Jalali.now();
  late int year = now.year, month = now.month;

  void _shift(int d) => setState(() {
        month += d;
        if (month > 12) { month = 1; year++; }
        if (month < 1) { month = 12; year--; }
      });

  @override
  Widget build(BuildContext context) {
    final (from, to) = jalaliMonthRange(year, month);
    return RepoBuilder<(MonthReport, List<Party>)>(
      key: ValueKey('$year-$month'),
      repo: widget.repo,
      load: () async => (await widget.repo.report(from, to), await widget.repo.parties()),
      builder: (c, d) {
        final (r, parties) = d;
        final debtors = parties.where((p) => p.balance > 0).fold<int>(0, (a, p) => a + p.balance);
        final creditors = parties.where((p) => p.balance < 0).fold<int>(0, (a, p) => a - p.balance);
        return ListView(padding: const EdgeInsets.all(16), children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_right)),
            Text('${monthNames[month - 1]} ${faDigits('$year')}', style: Theme.of(c).textTheme.titleLarge),
            IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_left)),
          ]),
          gap(),
          _tile(c, 'کل دریافتی‌ها', r.income, Colors.green.shade700),
          _tile(c, 'کل پرداختی‌ها', r.expense, Theme.of(c).colorScheme.error),
          _tile(c, 'خالص ماه', r.net, amountColor(c, r.net), bold: true),
          const Divider(height: 32),
          Text('به تفکیک دسته‌بندی', style: Theme.of(c).textTheme.titleMedium),
          if (r.byCategory.isEmpty) emptyState('در این ماه تراکنشی ثبت نشده است.'),
          for (final (name, kind, total) in r.byCategory)
            ListTile(
              dense: true,
              leading: Icon(kind == 'receipt' ? Icons.south_west : Icons.north_east,
                  color: kind == 'receipt' ? Colors.green : Colors.redAccent),
              title: Text(name),
              trailing: Text(money(total)),
            ),
          const Divider(height: 32),
          Text('وضعیت حساب با اشخاص (تا امروز)', style: Theme.of(c).textTheme.titleMedium),
          _tile(c, 'مجموع طلب شما', debtors, Colors.green.shade700),
          _tile(c, 'مجموع بدهی شما', creditors, Theme.of(c).colorScheme.error),
        ]);
      },
    );
  }

  Widget _tile(BuildContext c, String l, int v, Color color, {bool bold = false}) => ListTile(
        title: Text(l, style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
        trailing: Text('${money(v)} تومان', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      );
}
