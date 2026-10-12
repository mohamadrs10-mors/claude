import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/repo.dart';
import '../print/report_builders.dart';
import '../util/format.dart';
import 'common.dart';
import 'print_dialog.dart';
import 'products_page.dart';

/// Report: total sales of one product, split by the people who bought it.
class ProductBuyersTab extends StatefulWidget {
  const ProductBuyersTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<ProductBuyersTab> createState() => _ProductBuyersTabState();
}

enum _Period { all, year, month }

class _ProductBuyersTabState extends State<ProductBuyersTab> {
  final now = Jalali.now();
  late int year = now.year, month = now.month;
  _Period period = _Period.all;
  String? productId;
  List<Product> products = [];
  bool loaded = false;

  Repo get repo => widget.repo;
  Product? get product => products.where((p) => p.id == productId).firstOrNull;

  @override
  void initState() {
    super.initState();
    repo.products().then((p) {
      if (!mounted) return;
      setState(() {
        products = p;
        loaded = true;
      });
    });
  }

  (String?, String?) get _range => switch (period) {
        _Period.all => (null, null),
        _Period.year => jalaliYearRange(year),
        _Period.month => jalaliMonthRange(year, month),
      };

  String get _periodLabel => switch (period) {
        _Period.all => 'کل دوران',
        _Period.year => 'سال ${faDigits('$year')}',
        _Period.month => '${monthNames[month - 1]} ${faDigits('$year')}',
      };

  void _shift(int d) => setState(() {
        if (period == _Period.year) {
          year += d;
        } else {
          month += d;
          if (month > 12) { month = 1; year++; }
          if (month < 1) { month = 12; year--; }
        }
      });

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    final theme = Theme.of(context);
    final (from, to) = _range;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
      DropdownMenu<String>(
        width: double.infinity,
        enableFilter: true,
        requestFocusOnTap: true,
        label: const Text('کالا را انتخاب کنید (برای جستجو تایپ کنید)'),
        initialSelection: productId,
        dropdownMenuEntries: [for (final p in products) DropdownMenuEntry(value: p.id, label: p.name)],
        onSelected: (v) => setState(() => productId = v),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SegmentedButton<_Period>(
          segments: const [
            ButtonSegment(value: _Period.all, label: Text('کل دوران')),
            ButtonSegment(value: _Period.year, label: Text('سال')),
            ButtonSegment(value: _Period.month, label: Text('ماه')),
          ],
          selected: {period},
          onSelectionChanged: (s) => setState(() => period = s.first),
        ),
        if (period != _Period.all)
          Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_right)),
            SizedBox(width: 130, child: Center(child: Text(_periodLabel, style: theme.textTheme.titleSmall))),
            IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_left)),
          ]),
      ]),
      const SizedBox(height: 12),
      if (productId == null)
        emptyState('یک کالا انتخاب کنید تا فروش آن به تفکیک اشخاص نمایش داده شود.')
      else
        RepoBuilder<List<PartySales>>(
          key: ValueKey('$productId$period$year$month'),
          repo: repo,
          load: () => repo.productSalesByParty(productId!, from: from, toExclusive: to),
          builder: (c, rows) => _result(c, rows, from, to),
        ),
    ]);
  }

  Widget _result(BuildContext c, List<PartySales> rows, String? from, String? to) {
    final p = product!;
    final totalRevenue = rows.fold<int>(0, (a, r) => a + r.revenue);
    final totalQty = rows.fold<double>(0, (a, r) => a + r.qty);
    final maxRevenue = rows.fold<int>(0, (m, r) => r.revenue > m ? r.revenue : m);
    final scheme = Theme.of(c).colorScheme;
    if (rows.isEmpty) return emptyState('در این بازه فروشی برای «${p.name}» ثبت نشده است.');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: StatCard(title: 'کل فروش', value: moneyC(totalRevenue), icon: Icons.point_of_sale, color: Colors.green.shade700)),
        const SizedBox(width: 12),
        Expanded(child: StatCard(title: 'تعداد فروخته‌شده', value: '${qtyText(totalQty)} ${p.unit}', icon: Icons.inventory_2_outlined, color: Colors.indigo)),
        const SizedBox(width: 12),
        Expanded(child: StatCard(title: 'تعداد خریداران', value: faDigits('${rows.length}'), icon: Icons.groups_outlined, color: scheme.primary)),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: Text('خریداران «${p.name}» • $_periodLabel', style: Theme.of(c).textTheme.titleSmall)),
        PrintButton(repo: repo, doc: () => buyersDoc(p, rows, _periodLabel)),
      ]),
      const SizedBox(height: 4),
      Card(
        child: Column(children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(),
            ListTile(
              onTap: () => _showLines(c, p, rows[i], from, to),
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: Text(faDigits('${i + 1}'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
              title: Text(rows[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: maxRevenue <= 0 ? 0 : (rows[i].revenue / maxRevenue).clamp(0.0, 1.0), minHeight: 6),
                  ),
                  const SizedBox(height: 4),
                  Text('${qtyText(rows[i].qty)} ${p.unit} • ${faDigits('${rows[i].invoices}')} فاکتور'
                      '${totalRevenue > 0 ? ' • ${numText(rows[i].revenue * 100 / totalRevenue, 1)}٪ از کل' : ''}'),
                ]),
              ),
              trailing: Text(moneyC(rows[i].revenue), style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 8),
      Text('مبلغ‌ها جمع ردیف‌های فاکتور (تعداد × قیمت) است و فاکتورهای «برگشت از فروش» کم می‌شود. تخفیف و مالیات کل فاکتور در آن نیست.',
          style: Theme.of(c).textTheme.bodySmall),
    ]);
  }

  Future<void> _showLines(BuildContext c, Product p, PartySales row, String? from, String? to) async {
    final lines = await repo.productSaleLines(p.id, row.partyId, from: from, toExclusive: to);
    if (!c.mounted) return;
    await showModalBottomSheet<void>(
      context: c,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (bc) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(bc).height * 0.7),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
          Text('فروش «${p.name}» به ${row.name}', style: Theme.of(bc).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('${qtyText(row.qty)} ${p.unit} • ${moneyC(row.revenue)}'),
          const Divider(height: 24),
          for (final l in lines)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(l.kind == 'sale' ? Icons.south_west : Icons.undo, color: l.kind == 'sale' ? Colors.green : Colors.redAccent),
              title: Text('${l.kind == 'sale' ? 'فروش' : 'برگشت از فروش'} • فاکتور ${faDigits('${l.number}')}'),
              subtitle: Text('${jalaliText(l.date)} • ${qtyText(l.qty)} × ${money(l.unitPrice)}'),
              trailing: Text(l.kind == 'sale' ? money(l.total) : '(${money(l.total)})', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
        ]),
      ),
    );
  }
}
