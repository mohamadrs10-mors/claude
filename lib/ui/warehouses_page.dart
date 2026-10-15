import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/report_doc.dart';
import '../util/format.dart';
import 'auth.dart';
import 'common.dart';
import 'print_dialog.dart';
import 'products_page.dart' show qtyText;

/// Warehouses (انبارها): stock of each product in each warehouse, transfers
/// between warehouses, count corrections, and the warehouses themselves.
class WarehousesPage extends StatelessWidget {
  const WarehousesPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Column(children: [
          const TabBar(tabs: [Tab(text: 'موجودی هر انبار'), Tab(text: 'انتقال و شمارش'), Tab(text: 'انبارها')]),
          Expanded(child: TabBarView(children: [_StockTab(repo: repo), _MovesTab(repo: repo), _ListTab(repo: repo)])),
        ]),
      );
}

typedef _StockData = (List<Product>, List<Warehouse>, Map<String, Map<String, double>>);

Future<_StockData> _loadStock(Repo repo) async => (await repo.products(), await repo.warehouses(), await repo.stockByWarehouse());

class _StockTab extends StatefulWidget {
  const _StockTab({required this.repo});
  final Repo repo;
  @override
  State<_StockTab> createState() => _StockTabState();
}

class _StockTabState extends State<_StockTab> {
  String q = '';

  @override
  Widget build(BuildContext context) => RepoBuilder<_StockData>(
        repo: widget.repo,
        load: () => _loadStock(widget.repo),
        builder: (c, data) {
          final (products, whs, stock) = data;
          final list = products.where((p) => q.isEmpty || p.name.contains(q) || p.code.contains(q)).toList();
          double at(Product p, Warehouse w) => stock[p.id]?[w.id] ?? 0;
          String cell(double v) => v == 0 ? '—' : qtyText(v);
          return Constrained(
            maxWidth: 1100,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(child: SearchBox(onChanged: (v) => setState(() => q = v), hint: 'جستجوی کالا...')),
                const SizedBox(width: 8),
                PrintButton(
                  repo: widget.repo,
                  label: 'چاپ',
                  doc: () => ReportDoc(
                    title: 'موجودی کالا در انبارها',
                    subtitle: 'تا امروز',
                    tables: [
                      ReportTable(
                        headers: ['کالا', for (final w in whs) w.name, 'جمع'],
                        cols: [Col.text, for (final _ in whs) Col.number, Col.number],
                        flex: [3, for (final _ in whs) 1.4, 1.4],
                        rows: [
                          for (final p in list) [p.name, for (final w in whs) cell(at(p, w)), qtyText(whs.fold<double>(0, (a, w) => a + at(p, w)))]
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              if (list.isEmpty)
                emptyState('کالایی پیدا نشد.')
              else
                Card(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: [
                        const DataColumn(label: Text('کالا')),
                        for (final w in whs) DataColumn(label: Text(w.name), numeric: true),
                        const DataColumn(label: Text('جمع'), numeric: true),
                      ],
                      rows: [
                        for (final p in list)
                          DataRow(cells: [
                            DataCell(Text(p.name)),
                            for (final w in whs) DataCell(Text(cell(at(p, w)))),
                            DataCell(Text(qtyText(whs.fold<double>(0, (a, w) => a + at(p, w))), style: const TextStyle(fontWeight: FontWeight.w700))),
                          ]),
                      ],
                    ),
                  ),
                ),
            ]),
          );
        },
      );
}

class _MovesTab extends StatelessWidget {
  const _MovesTab({required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('products');
    return RepoBuilder<(List<StockMove>, List<Product>, List<Warehouse>)>(
      repo: repo,
      load: () async => (await repo.stockMoves(), await repo.products(), await repo.warehouses()),
      builder: (c, data) {
        final (moves, products, whs) = data;
        final pn = {for (final p in products) p.id: p};
        final wn = {for (final w in whs) w.id: w.name};
        return Scaffold(
          body: Constrained(
            child: moves.isEmpty
                ? emptyState('هنوز انتقال یا شمارشی ثبت نشده است.\nانتقال کالا بین انبارها و اصلاح موجودی بعد از انبارگردانی اینجا ثبت می‌شود.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                    itemCount: moves.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final m = moves[i];
                      final p = pn[m.productId];
                      return ListTile(
                        leading: Icon(m.isTransfer ? Icons.swap_horiz : Icons.fact_check_outlined),
                        title: Text(m.isTransfer
                            ? '${p?.name ?? '؟'} • ${qtyText(m.qty)} ${p?.unit ?? ''} از «${wn[m.warehouseId] ?? '؟'}» به «${wn[m.toWarehouseId] ?? '؟'}»'
                            : '${p?.name ?? '؟'} • تعدیل ${m.qty > 0 ? '+' : ''}${qtyText(m.qty)} ${p?.unit ?? ''} در «${wn[m.warehouseId] ?? '؟'}»'),
                        subtitle: Text('${faDigits(jalaliText(m.date))}${m.note.isEmpty ? '' : ' • ${m.note}'}'),
                        trailing: !canEdit
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  if (await confirm(c, 'این مورد حذف شود؟')) await repo.deleteStockMove(m.id);
                                },
                              ),
                      );
                    },
                  ),
          ),
          floatingActionButton: !canEdit
              ? null
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  FloatingActionButton.extended(
                    heroTag: 'adj',
                    onPressed: () => _moveDialog(c, repo, products, whs, transfer: false),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('شمارش و تعدیل'),
                  ),
                  const SizedBox(height: 10),
                  FloatingActionButton.extended(
                    heroTag: 'tr',
                    onPressed: whs.length < 2 ? () => toast(c, 'اول از تب «انبارها» یک انبار دیگر بسازید.') : () => _moveDialog(c, repo, products, whs, transfer: true),
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('انتقال بین انبارها'),
                  ),
                ]),
        );
      },
    );
  }
}

Future<void> _moveDialog(BuildContext context, Repo repo, List<Product> products, List<Warehouse> whs, {required bool transfer}) async {
  final stock = await repo.stockByWarehouse();
  if (!context.mounted) return;
  String date = todayIso();
  String? productId, from = whs.first.id, to = whs.length > 1 ? whs[1].id : null;
  final qty = TextEditingController();
  final note = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(builder: (dc, setS) {
      final have = productId == null ? null : (stock[productId]?[from] ?? 0);
      return AlertDialog(
        title: Text(transfer ? 'انتقال بین انبارها' : 'شمارش و تعدیل موجودی'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              JalaliDateField(iso: date, onChanged: (v) => setS(() => date = v)),
              gap(),
              DropdownMenu<String>(
                width: 420,
                label: const Text('کالا'),
                enableFilter: true,
                requestFocusOnTap: true,
                dropdownMenuEntries: [for (final p in products) DropdownMenuEntry(value: p.id, label: p.name)],
                onSelected: (v) => setS(() => productId = v),
              ),
              gap(),
              DropdownButtonFormField<String>(
                initialValue: from,
                decoration: InputDecoration(labelText: transfer ? 'از انبار' : 'انبار'),
                items: [for (final w in whs) DropdownMenuItem(value: w.id, child: Text(w.name))],
                onChanged: (v) => setS(() => from = v),
              ),
              if (transfer) ...[
                gap(),
                DropdownButtonFormField<String>(
                  initialValue: to,
                  decoration: const InputDecoration(labelText: 'به انبار'),
                  items: [for (final w in whs) DropdownMenuItem(value: w.id, child: Text(w.name))],
                  onChanged: (v) => setS(() => to = v),
                ),
              ],
              if (have != null) Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: AlignmentDirectional.centerStart, child: Text('موجودی فعلی در این انبار: ${qtyText(have)}', style: Theme.of(dc).textTheme.bodySmall))),
              gap(),
              AmountField(controller: qty, label: transfer ? 'مقدار انتقال' : 'مقدار شمارش‌شده', decimal: true, suffix: ''),
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
                if (productId == null || from == null) throw StateError('کالا و انبار را انتخاب کنید.');
                final v = double.tryParse(enDigits(qty.text.replaceAll(',', '').replaceAll('٬', ''))) ?? 0;
                if (transfer) {
                  await repo.saveStockMove(kind: 'transfer', date: date, productId: productId!, warehouseId: from!, toWarehouseId: to, qty: v, note: note.text);
                } else {
                  // The count is what is on the shelf; the correction is the difference.
                  final diff = v - (stock[productId]?[from] ?? 0);
                  if (diff == 0) throw StateError('شمارش با موجودی ثبت‌شده برابر است؛ چیزی برای اصلاح نیست.');
                  await repo.saveStockMove(kind: 'adjust', date: date, productId: productId!, warehouseId: from!, qty: diff, note: note.text);
                }
                if (dc.mounted) Navigator.pop(dc);
              } catch (e) {
                setS(() => error = e is StateError ? e.message : '$e');
              }
            },
            child: const Text('ثبت'),
          ),
        ],
      );
    }),
  );
}

class _ListTab extends StatelessWidget {
  const _ListTab({required this.repo});
  final Repo repo;

  Future<void> _edit(BuildContext context, Warehouse? w) async {
    final name = TextEditingController(text: w?.name ?? '');
    final note = TextEditingController(text: w?.note ?? '');
    String? error;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setS) => AlertDialog(
          title: Text(w == null ? 'انبار جدید' : 'ویرایش انبار'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'نام انبار')),
            gap(),
            TextField(controller: note, decoration: const InputDecoration(labelText: 'توضیح (آدرس، مسئول...)')),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                try {
                  await repo.saveWarehouse(id: w?.id, name: name.text, note: note.text);
                  if (dc.mounted) Navigator.pop(dc);
                } catch (e) {
                  setS(() => error = e is StateError ? e.message : '$e');
                }
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('products');
    return RepoBuilder<List<Warehouse>>(
      repo: repo,
      load: repo.warehouses,
      builder: (c, list) => Scaffold(
        body: Constrained(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
            Card(
              child: Column(children: [
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) const Divider(),
                  ListTile(
                    leading: Icon(list[i].isMain ? Icons.home_work_outlined : Icons.warehouse_outlined),
                    title: Text(list[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: list[i].note.isEmpty ? (list[i].isMain ? const Text('انبار پیش‌فرض (فاکتورهای بدون انبار و موجودی اولیه کالاها)') : null) : Text(list[i].note),
                    onTap: !canEdit ? null : () => _edit(c, list[i]),
                    trailing: !canEdit || list[i].isMain
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (!await confirm(c, 'انبار «${list[i].name}» حذف شود؟')) return;
                              final err = await repo.deleteWarehouse(list[i].id);
                              if (err != null && c.mounted) toast(c, err);
                            },
                          ),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: 12),
            Text(
              'موجودی اولیهٔ کالاها در «انبار اصلی» حساب می‌شود. هر فاکتور (فروش، خرید و برگشت‌ها) برای یک انبار صادر می‌شود و موجودی همان انبار را تغییر می‌دهد. برای جابه‌جایی کالا از «انتقال»، و برای اصلاح موجودی بعد از انبارگردانی از «شمارش و تعدیل» استفاده کنید.',
              style: Theme.of(c).textTheme.bodySmall,
            ),
          ]),
        ),
        floatingActionButton: !canEdit ? null : FloatingActionButton.extended(onPressed: () => _edit(c, null), icon: const Icon(Icons.add), label: const Text('انبار جدید')),
      ),
    );
  }
}
