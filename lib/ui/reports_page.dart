import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/repo.dart';
import '../print/report_builders.dart';
import '../util/format.dart';
import 'common.dart';
import 'product_buyers_tab.dart';
import 'finance_reports.dart';
import 'print_dialog.dart';
import 'products_page.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> with SingleTickerProviderStateMixin {
  final now = Jalali.now();
  late int year = now.year, month = now.month;
  late final TabController tabs = TabController(length: 10, vsync: this);

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  void _shift(int d) => setState(() {
        month += d;
        if (month > 12) { month = 1; year++; }
        if (month < 1) { month = 12; year--; }
      });

  @override
  Widget build(BuildContext context) {
    final (from, to) = jalaliMonthRange(year, month);
    return Constrained(
      child: Column(children: [
        TabBar(controller: tabs, isScrollable: true, tabAlignment: TabAlignment.start, tabs: const [
          Tab(text: 'درآمد و هزینه'),
          Tab(text: 'سود و زیان'),
          Tab(text: 'وضعیت مالی'),
          Tab(text: 'مالیات'),
          Tab(text: 'فروش کالا'),
          Tab(text: 'فروش کالا به تفکیک شخص'),
          Tab(text: 'سن مطالبات'),
          Tab(text: 'گردش حساب'),
          Tab(text: 'کاردکس کالا'),
          Tab(text: 'بدهکاران و بستانکاران'),
        ]),
        Expanded(
          child: TabBarView(controller: tabs, children: [
            _monthPicker(_cashReport(from, to)),
            ProfitLossTab(repo: widget.repo),
            FinancialPositionTab(repo: widget.repo),
            VatTab(repo: widget.repo),
            _monthPicker(_productReport(from, to)),
            ProductBuyersTab(repo: widget.repo),
            AgeingTab(repo: widget.repo),
            LedgerTab(repo: widget.repo, product: false),
            LedgerTab(repo: widget.repo, product: true),
            _partyReport(),
          ]),
        ),
      ]),
    );
  }

  Widget _monthPicker(Widget body) => Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_right)),
            SizedBox(width: 160, child: Center(child: Text('${monthNames[month - 1]} ${faDigits('$year')}', style: Theme.of(context).textTheme.titleMedium))),
            IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_left)),
          ]),
        ),
        Expanded(child: body),
      ]);

  Widget _cashReport(String from, String to) => RepoBuilder<MonthReport>(
        key: ValueKey('c$year-$month'),
        repo: widget.repo,
        load: () => widget.repo.report(from, to),
        builder: (c, r) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: PrintButton(repo: widget.repo, doc: () => monthlyDoc(r, '${monthNames[month - 1]} ${faDigits('$year')}')),
          ),
          Row(children: [
            Expanded(child: StatCard(title: 'دریافتی‌ها', value: moneyC(r.income), icon: Icons.south_west, color: Colors.green.shade700)),
            const SizedBox(width: 12),
            Expanded(child: StatCard(title: 'پرداختی‌ها', value: moneyC(r.expense), icon: Icons.north_east, color: Theme.of(c).colorScheme.error)),
          ]),
          const SizedBox(height: 12),
          StatCard(title: 'خالص ماه', value: moneyC(r.net), icon: Icons.balance, color: amountColor(c, r.net)),
          const SizedBox(height: 16),
          Section(
            title: 'به تفکیک دسته‌بندی',
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: r.byCategory.isEmpty
                ? const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('در این ماه تراکنشی ثبت نشده است.'))
                : Column(children: [
                    for (final (name, kind, total) in r.byCategory)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: Icon(kind == 'receipt' ? Icons.south_west : Icons.north_east,
                            color: kind == 'receipt' ? Colors.green : Colors.redAccent),
                        title: Text(name),
                        trailing: Text(money(total), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                  ]),
          ),
        ]),
      );

  Widget _productReport(String from, String to) => RepoBuilder<(List<ProductSales>, List<Product>)>(
        key: ValueKey('p$year-$month'),
        repo: widget.repo,
        load: () async => (await widget.repo.productSales(from, to), await widget.repo.products()),
        builder: (c, d) {
          final (sales, products) = d;
          final revenue = sales.fold<int>(0, (a, s) => a + s.revenue);
          final stockValue = products.fold<double>(0, (a, p) => a + (p.stock > 0 ? p.stock * p.buyPrice : 0));
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: PrintButton(repo: widget.repo, doc: () => productSalesDoc(sales, products, '${monthNames[month - 1]} ${faDigits('$year')}')),
            ),
            Row(children: [
              Expanded(child: StatCard(title: 'فروش خالص ماه', value: moneyC(revenue), icon: Icons.point_of_sale, color: Colors.green.shade700)),
              const SizedBox(width: 12),
              Expanded(child: StatCard(title: 'ارزش فعلی انبار', value: moneyC(stockValue.round()), icon: Icons.warehouse_outlined, color: Colors.indigo)),
            ]),
            const SizedBox(height: 16),
            Section(
              title: 'پرفروش‌ترین‌ها',
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: sales.isEmpty
                  ? const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('در این ماه فروشی ثبت نشده است.'))
                  : Column(children: [
                      for (final s in sales)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(s.name),
                          subtitle: Text('${qtyText(s.qty)} ${s.unit}'.trim()),
                          trailing: Text(money(s.revenue), style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                    ]),
            ),
          ]);
        },
      );

  Widget _partyReport() => RepoBuilder<List<Party>>(
        repo: widget.repo,
        load: widget.repo.parties,
        builder: (c, parties) {
          final debtors = parties.where((p) => p.balance > 0).toList()..sort((a, b) => b.balance.compareTo(a.balance));
          final creditors = parties.where((p) => p.balance < 0).toList()..sort((a, b) => a.balance.compareTo(b.balance));
          Widget group(String title, List<Party> list, Color color) => Section(
                title: '$title • ${moneyC(list.fold<int>(0, (a, p) => a + p.balance.abs()))}',
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: list.isEmpty
                    ? const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('موردی نیست.'))
                    : Column(children: [
                        for (final p in list)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(p.name),
                            subtitle: p.phone.isEmpty ? null : Text(faDigits(p.phone)),
                            trailing: Text(money(p.balance.abs()), style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                            onTap: () => showStatementPrint(c, widget.repo, p),
                          ),
                      ]),
              );
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: PrintButton(repo: widget.repo, doc: () => partyBalancesDoc(parties)),
            ),
            group('بدهکاران (طلب شما)', debtors, Colors.green.shade700),
            const SizedBox(height: 16),
            group('بستانکاران (بدهی شما)', creditors, Theme.of(c).colorScheme.error),
            const SizedBox(height: 8),
            Text('با لمس هر نام، صورت‌حساب همان شخص چاپ می‌شود.', style: Theme.of(c).textTheme.bodySmall),
          ]);
        },
      );
}
