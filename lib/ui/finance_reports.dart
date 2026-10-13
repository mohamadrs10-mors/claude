import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/report_builders.dart';
import '../util/format.dart';
import 'common.dart';
import 'period.dart';
import 'print_dialog.dart';

Widget _pad(List<Widget> children) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: children);

Widget _line(BuildContext c, String label, num value, {bool bold = false, Color? color, bool sub = false, String suffix = ''}) => Padding(
      padding: EdgeInsets.symmetric(vertical: 4, horizontal: sub ? 12 : 0),
      child: Row(children: [
        Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null, color: sub ? Theme.of(c).hintColor : null))),
        Text(suffix.isEmpty ? moneyC(value.round()) : '${numText(value)} $suffix',
            style: TextStyle(fontWeight: bold ? FontWeight.w700 : null, color: color ?? (value < 0 ? Theme.of(c).colorScheme.error : null))),
      ]),
    );

/// Profit and loss for a period.
class ProfitLossTab extends StatefulWidget {
  const ProfitLossTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<ProfitLossTab> createState() => _ProfitLossTabState();
}

class _ProfitLossTabState extends State<ProfitLossTab> {
  final period = PeriodController();

  @override
  void dispose() {
    period.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: period,
        builder: (context, _) => RepoBuilder<ProfitLoss>(
          key: ValueKey('pl${period.key}'),
          repo: widget.repo,
          load: () {
            final (a, b) = period.bounds;
            return widget.repo.profitLoss(a, b);
          },
          builder: (c, p) => _pad([
            PeriodBar(controller: period),
            const SizedBox(height: 8),
            Align(alignment: AlignmentDirectional.centerEnd, child: PrintButton(repo: widget.repo, doc: () => profitLossDoc(p, period.label))),
            Row(children: [
              Expanded(child: StatCard(title: 'سود ناخالص', value: moneyC(p.grossProfit), icon: Icons.stacked_line_chart, color: p.grossProfit >= 0 ? Colors.green.shade700 : Theme.of(c).colorScheme.error)),
              const SizedBox(width: 12),
              Expanded(child: StatCard(title: 'سود (زیان) خالص', value: moneyC(p.netProfit), icon: Icons.account_balance_outlined, color: p.netProfit >= 0 ? Colors.green.shade700 : Theme.of(c).colorScheme.error)),
            ]),
            const SizedBox(height: 12),
            Section(title: 'محاسبه', child: Column(children: [
              _line(c, 'فروش خالص (بدون مالیات)', p.sales),
              _line(c, 'بهای تمام‌شدهٔ کالای فروش‌رفته', -p.cogs),
              const Divider(),
              _line(c, 'سود ناخالص', p.grossProfit, bold: true),
              for (final (n, v) in p.otherIncomeByCategory) _line(c, 'درآمد: $n', v, sub: true),
              for (final (n, v) in p.expensesByCategory) _line(c, 'هزینه: $n', -v, sub: true),
              const Divider(),
              _line(c, 'سود (زیان) خالص', p.netProfit, bold: true),
            ])),
            const SizedBox(height: 8),
            Text(
              'بهای کالا با قیمت تمام‌شدهٔ برگهٔ هزینه (اگر دارید) یا میانگین موزون خرید حساب می‌شود. '
              'هزینه و درآمدِ متفرقه فقط از تراکنش‌هایی می‌آید که دسته‌بندی دارند و به شخص یا فاکتور وصل نیستند.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
            if (p.unlinkedSales != 0) Text('• فروش ${moneyC(p.unlinkedSales)} از اقلامی است که به کالا وصل نبوده و بهای تمام‌شده ندارد.', style: Theme.of(c).textTheme.bodySmall),
            if (p.uncategorized != 0) Text('• ${moneyC(p.uncategorized)} پرداخت بدون شخص و دسته‌بندی در این گزارش نیامده؛ برای دیده شدن، دسته‌بندی کنید.', style: Theme.of(c).textTheme.bodySmall),
          ]),
        ),
      );
}

/// Assets, liabilities and equity as of today.
class FinancialPositionTab extends StatelessWidget {
  const FinancialPositionTab({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<FinancialPosition>(
        repo: repo,
        load: repo.financialPosition,
        builder: (c, f) => _pad([
          Align(alignment: AlignmentDirectional.centerEnd, child: PrintButton(repo: repo, doc: () => financialPositionDoc(f))),
          Row(children: [
            Expanded(child: StatCard(title: 'جمع دارایی‌ها', value: moneyC(f.assets), icon: Icons.account_balance_wallet_outlined, color: Colors.green.shade700)),
            const SizedBox(width: 12),
            Expanded(child: StatCard(title: 'جمع بدهی‌ها', value: moneyC(f.liabilities), icon: Icons.money_off, color: Theme.of(c).colorScheme.error)),
          ]),
          const SizedBox(height: 12),
          StatCard(title: 'حقوق صاحبان سرمایه (دارایی − بدهی)', value: moneyC(f.equity), icon: Icons.balance, color: f.equity >= 0 ? Theme.of(c).colorScheme.primary : Theme.of(c).colorScheme.error),
          const SizedBox(height: 12),
          Section(title: 'دارایی‌ها', child: Column(children: [
            for (final (n, v) in f.accounts.where((a) => a.$2 > 0)) _line(c, 'موجودی $n', v),
            _line(c, 'طلب از اشخاص', f.receivables),
            _line(c, 'موجودی کالا', f.inventory),
            _line(c, 'چک‌های دریافتی در انتظار', f.chequesReceived),
            const Divider(),
            _line(c, 'جمع دارایی‌ها', f.assets, bold: true),
          ])),
          const SizedBox(height: 12),
          Section(title: 'بدهی‌ها', child: Column(children: [
            _line(c, 'بدهی به اشخاص', f.payables),
            _line(c, 'چک‌های پرداختی در انتظار', f.chequesIssued),
            for (final (n, v) in f.accounts.where((a) => a.$2 < 0)) _line(c, 'برداشت بیش از موجودی $n', -v),
            const Divider(),
            _line(c, 'جمع بدهی‌ها', f.liabilities, bold: true),
          ])),
          const SizedBox(height: 8),
          Text('دارایی ثابت و استهلاک در این گزارش نیست؛ موجودی کالا با قیمت تمام‌شده یا میانگین خرید ارزش‌گذاری شده است.', style: Theme.of(c).textTheme.bodySmall),
        ]),
      );
}

/// VAT collected and paid in a period.
class VatTab extends StatefulWidget {
  const VatTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<VatTab> createState() => _VatTabState();
}

class _VatTabState extends State<VatTab> {
  final period = PeriodController();

  @override
  void dispose() {
    period.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: period,
        builder: (context, _) => RepoBuilder<VatReport>(
          key: ValueKey('vat${period.key}'),
          repo: widget.repo,
          load: () {
            final (a, b) = period.bounds;
            return widget.repo.vatReport(a, b);
          },
          builder: (c, v) => _pad([
            PeriodBar(controller: period),
            const SizedBox(height: 8),
            Align(alignment: AlignmentDirectional.centerEnd, child: PrintButton(repo: widget.repo, doc: () => vatDoc(v, period.label))),
            Row(children: [
              Expanded(child: StatCard(title: 'مالیات فروش', value: moneyC(v.outputTax), icon: Icons.south_west, color: Colors.green.shade700)),
              const SizedBox(width: 12),
              Expanded(child: StatCard(title: 'مالیات خرید', value: moneyC(v.inputTax), icon: Icons.north_east, color: Theme.of(c).colorScheme.error)),
            ]),
            const SizedBox(height: 12),
            StatCard(
              title: v.payable >= 0 ? 'مالیات قابل پرداخت' : 'مالیات قابل استرداد',
              value: moneyC(v.payable.abs()),
              icon: Icons.receipt_long_outlined,
              color: v.payable >= 0 ? Colors.orange.shade800 : Colors.teal,
            ),
            const SizedBox(height: 12),
            Section(
              title: 'اسناد دارای مالیات',
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: v.lines.isEmpty
                  ? const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('سندی در این بازه نیست.'))
                  : Column(children: [
                      for (final l in v.lines)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('${invoiceKind(l.kind).label} ${faDigits('${l.number}')} • ${l.party}'),
                          subtitle: Text('${jalaliText(l.date)} • مبنا ${money(l.base)}'),
                          trailing: Text(money(l.tax), style: TextStyle(fontWeight: FontWeight.w600, color: l.tax < 0 ? Theme.of(c).colorScheme.error : null)),
                        ),
                    ]),
            ),
            const SizedBox(height: 8),
            Text('برگشتی‌ها منفی‌اند. این گزارش کمکی است و جایگزین اظهارنامهٔ رسمی نیست.', style: Theme.of(c).textTheme.bodySmall),
          ]),
        ),
      );
}

/// Receivables by age.
class AgeingTab extends StatelessWidget {
  const AgeingTab({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<List<AgeingRow>>(
        repo: repo,
        load: repo.ageing,
        builder: (c, rows) {
          final labels = ['۰ تا ۳۰ روز', '۳۱ تا ۶۰', '۶۱ تا ۹۰', 'بیش از ۹۰'];
          final colors = [Colors.green.shade700, Colors.amber.shade800, Colors.deepOrange, Theme.of(c).colorScheme.error];
          return _pad([
            Align(alignment: AlignmentDirectional.centerEnd, child: PrintButton(repo: repo, doc: () => ageingDoc(rows))),
            if (rows.isEmpty) emptyState('هیچ‌کس به شما بدهکار نیست.')
            else ...[
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (var i = 0; i < 4; i++)
                  SizedBox(width: 200, child: StatCard(title: labels[i], value: moneyC(rows.fold(0, (a, r) => a + r.buckets[i])), icon: Icons.schedule, color: colors[i])),
              ]),
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      title: Text(rows[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Wrap(spacing: 10, children: [
                        for (var b = 0; b < 4; b++)
                          if (rows[i].buckets[b] > 0) Text('${labels[b]}: ${money(rows[i].buckets[b])}', style: TextStyle(color: colors[b], fontSize: 12)),
                      ]),
                      trailing: Text(money(rows[i].total), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
              ),
              const SizedBox(height: 8),
              Text('پرداخت‌ها به قدیمی‌ترین فاکتورها اختصاص می‌یابد؛ مانده اول دوره در «بیش از ۹۰ روز» می‌آید.', style: Theme.of(c).textTheme.bodySmall),
            ],
          ]);
        },
      );
}

/// Account ledger (گردش حساب) or product card (کاردکس کالا): pick the item and
/// the period, get every movement with a running balance.
class LedgerTab extends StatefulWidget {
  const LedgerTab({super.key, required this.repo, required this.product});
  final Repo repo;

  /// true: stock movements of a product, false: money movements of an account.
  final bool product;
  @override
  State<LedgerTab> createState() => _LedgerTabState();
}

class _LedgerTabState extends State<LedgerTab> {
  final period = PeriodController(kind: PeriodKind.all);
  List<(String, String, String)> items = []; // id, name, unit
  String? selected;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    () async {
      final list = widget.product
          ? [for (final p in await widget.repo.products()) (p.id, p.name, p.unit)]
          : [for (final a in await widget.repo.accounts()) (a.id, a.name, '')];
      if (!mounted) return;
      setState(() {
        items = list;
        selected = list.isEmpty ? null : list.first.$1;
        loaded = true;
      });
    }();
  }

  @override
  void dispose() {
    period.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return emptyState(widget.product ? 'کالایی تعریف نشده است.' : 'حسابی تعریف نشده است.');
    final item = items.firstWhere((i) => i.$1 == selected, orElse: () => items.first);
    return ListenableBuilder(
      listenable: period,
      builder: (context, _) => RepoBuilder<Ledger>(
        key: ValueKey('ledger${widget.product}$selected${period.key}'),
        repo: widget.repo,
        load: () {
          final (a, b) = period.range;
          return widget.product
              ? widget.repo.productCard(item.$1, from: a, toExclusive: b)
              : widget.repo.accountLedger(item.$1, from: a, toExclusive: b);
        },
        builder: (c, l) {
          final unit = item.$3;
          String q(num v) => unit.isEmpty ? money(v.round()) : numText(v);
          return _pad([
            DropdownButtonFormField<String>(
              key: ValueKey(selected),
              initialValue: item.$1,
              decoration: InputDecoration(labelText: widget.product ? 'کالا' : 'حساب'),
              items: [for (final i in items) DropdownMenuItem(value: i.$1, child: Text(i.$2))],
              onChanged: (v) => setState(() => selected = v),
            ),
            const SizedBox(height: 10),
            PeriodBar(controller: period),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: PrintButton(
                repo: widget.repo,
                doc: () => ledgerDoc(
                  title: widget.product ? 'کاردکس کالا: ${item.$2}' : 'گردش حساب: ${item.$2}',
                  subtitle: period.label,
                  ledger: l,
                  unit: unit.isEmpty ? '' : unit,
                ),
              ),
            ),
            Row(children: [
              Expanded(child: StatCard(title: 'مانده ابتدا', value: unit.isEmpty ? moneyC(l.opening.round()) : '${q(l.opening)} $unit', icon: Icons.first_page, color: Colors.blueGrey)),
              const SizedBox(width: 12),
              Expanded(child: StatCard(title: 'مانده پایان', value: unit.isEmpty ? moneyC(l.closing.round()) : '${q(l.closing)} $unit', icon: Icons.last_page, color: Theme.of(c).colorScheme.primary)),
            ]),
            const SizedBox(height: 12),
            if (l.lines.isEmpty)
              emptyState('در این بازه گردشی نیست.')
            else
              Card(
                child: Column(children: [
                  for (var i = 0; i < l.lines.length; i++) ...[
                    if (i > 0) const Divider(),
                    ListTile(
                      dense: true,
                      leading: Icon(l.lines[i].inAmount != 0 ? Icons.south_west : Icons.north_east, color: l.lines[i].inAmount != 0 ? Colors.green : Colors.redAccent),
                      title: Text(l.lines[i].description),
                      subtitle: Text(jalaliText(l.lines[i].date)),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${l.lines[i].inAmount != 0 ? '+' : '−'}${q(l.lines[i].inAmount != 0 ? l.lines[i].inAmount : l.lines[i].outAmount)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text('مانده ${q(l.lines[i].balance)}', style: Theme.of(c).textTheme.bodySmall),
                      ]),
                    ),
                  ],
                ]),
              ),
          ]);
        },
      ),
    );
  }
}
