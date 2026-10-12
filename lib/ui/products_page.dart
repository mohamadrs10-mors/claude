import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'costing_page.dart';

const commonUnits = ['عدد', 'کیلوگرم', 'گرم', 'متر', 'لیتر', 'بسته', 'کارتن', 'جعبه', 'دست', 'جفت', 'ساعت', 'خدمت'];

String qtyText(double q) => faDigits(q == q.roundToDouble() ? '${q.round()}' : q.toStringAsFixed(2));

double parseQty(String s) => double.tryParse(enDigits(s).replaceAll('٫', '.').replaceAll(',', '.')) ?? 0;

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  String q = '';

  @override
  Widget build(BuildContext context) => RepoBuilder<List<Product>>(
        repo: widget.repo,
        load: widget.repo.products,
        builder: (c, all) {
          final list = all.where((p) => q.isEmpty || p.name.contains(q) || p.code.contains(q)).toList();
          final stockValue = all.fold<double>(0, (a, p) => a + (p.stock > 0 ? p.stock * p.buyPrice : 0));
          final low = all.where((p) => p.low).length;
          return Scaffold(
            body: Constrained(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                Row(children: [
                  Expanded(child: StatCard(title: 'تعداد کالا', value: faDigits('${all.length}'), icon: Icons.inventory_2_outlined, color: Theme.of(c).colorScheme.primary)),
                  const SizedBox(width: 12),
                  Expanded(child: StatCard(title: 'ارزش انبار (قیمت خرید)', value: moneyC(stockValue.round()), icon: Icons.warehouse_outlined, color: Colors.indigo)),
                  const SizedBox(width: 12),
                  Expanded(child: StatCard(title: 'کمبود موجودی', value: faDigits('$low'), icon: Icons.warning_amber_rounded, color: low > 0 ? Colors.orange : Colors.green)),
                ]),
                const SizedBox(height: 12),
                SearchBox(onChanged: (v) => setState(() => q = v), hint: 'جستجوی نام یا کد کالا...'),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  emptyState(all.isEmpty ? 'هنوز کالایی تعریف نشده است.\nبا دکمهٔ «کالای جدید» شروع کنید.' : 'کالایی پیدا نشد.')
                else
                  Card(
                    child: Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(),
                        _tile(c, list[i]),
                      ],
                    ]),
                  ),
              ]),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => editProduct(c, widget.repo),
              icon: const Icon(Icons.add),
              label: const Text('کالای جدید'),
            ),
          );
        },
      );

  Widget _tile(BuildContext c, Product p) {
    final color = p.stock <= 0 ? Theme.of(c).colorScheme.error : (p.low ? Colors.orange.shade800 : Colors.green.shade700);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(c).colorScheme.primaryContainer,
        child: Icon(Icons.inventory_2_outlined, color: Theme.of(c).colorScheme.onPrimaryContainer),
      ),
      title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([
        if (p.code.isNotEmpty) 'کد ${faDigits(p.code)}',
        'فروش ${money(p.salePrice)}',
        if (p.buyPrice > 0) 'خرید ${money(p.buyPrice)}',
        if (p.costPrice > 0) 'تمام‌شده ${money(p.costPrice)}',
      ].join(' • ')),
      trailing: StatusChip('${qtyText(p.stock)} ${p.unit}', color),
      onTap: () => editProduct(c, widget.repo, p),
    );
  }
}

Future<void> editProduct(BuildContext c, Repo repo, [Product? p]) async {
  final name = TextEditingController(text: p?.name);
  final code = TextEditingController(text: p?.code);
  final unit = TextEditingController(text: p?.unit ?? 'عدد');
  final sale = TextEditingController(text: p == null || p.salePrice == 0 ? '' : '${p.salePrice}');
  final buy = TextEditingController(text: p == null || p.buyPrice == 0 ? '' : '${p.buyPrice}');
  final opening = TextEditingController(text: p == null || p.openingStock == 0 ? '' : qtyText(p.openingStock));
  final minStock = TextEditingController(text: p == null || p.minStock == 0 ? '' : qtyText(p.minStock));
  final note = TextEditingController(text: p?.note);
  final key = GlobalKey<FormState>();

  await showDialog(
    context: c,
    builder: (dc) => AlertDialog(
      title: Text(p == null ? 'کالای جدید' : 'ویرایش کالا'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'نام کالا یا خدمت'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'نام را وارد کنید' : null,
              ),
              gap(),
              Row(children: [
                Expanded(child: TextFormField(controller: code, decoration: const InputDecoration(labelText: 'کد / بارکد'))),
                const SizedBox(width: 12),
                Expanded(
                  child: RawAutocomplete<String>(
                    textEditingController: unit,
                    focusNode: FocusNode(),
                    optionsBuilder: (v) => commonUnits.where((u) => u.contains(v.text)),
                    fieldViewBuilder: (c, ctl, fn, _) => TextFormField(
                      controller: ctl,
                      focusNode: fn,
                      decoration: const InputDecoration(labelText: 'واحد', suffixIcon: Icon(Icons.arrow_drop_down)),
                    ),
                    optionsViewBuilder: (c, onSel, opts) => Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Material(
                        elevation: 4,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220, maxWidth: 200),
                          child: ListView(
                            shrinkWrap: true,
                            children: [for (final o in opts) ListTile(dense: true, title: Text(o), onTap: () => onSel(o))],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
              gap(),
              Row(children: [
                Expanded(child: AmountField(controller: sale, label: 'قیمت فروش')),
                const SizedBox(width: 12),
                Expanded(child: AmountField(controller: buy, label: 'قیمت خرید')),
              ]),
              gap(),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: opening,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'موجودی اولیه'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: minStock,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'حداقل موجودی (هشدار)'),
                  ),
                ),
              ]),
              gap(),
              TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات')),
              if (p != null) ...[
                gap(),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text('موجودی فعلی: ${qtyText(p.stock)} ${p.unit}', style: Theme.of(dc).textTheme.bodySmall),
                ),
              ],
            ]),
          ),
        ),
      ),
      actions: [
        if (p != null)
          TextButton.icon(
            onPressed: () {
              Navigator.pop(dc);
              if (c.mounted) {
                Navigator.push(c, MaterialPageRoute(builder: (_) => CostingPage(repo: repo, productId: p.id)));
              }
            },
            icon: const Icon(Icons.calculate_outlined),
            label: const Text('قیمت تمام‌شده'),
          ),
        if (p != null)
          TextButton(
            onPressed: () async {
              if (!await confirm(dc, 'این کالا حذف شود؟ فاکتورهای قبلی حفظ می‌شوند.')) return;
              await repo.deleteProduct(p.id);
              if (dc.mounted) Navigator.pop(dc);
            },
            child: const Text('حذف'),
          ),
        TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
        FilledButton(
          onPressed: () async {
            if (!key.currentState!.validate()) return;
            await repo.saveProduct(
              id: p?.id,
              name: name.text.trim(),
              code: enDigits(code.text.trim()),
              unit: unit.text.trim().isEmpty ? 'عدد' : unit.text.trim(),
              salePrice: parseAmount(sale.text),
              buyPrice: parseAmount(buy.text),
              openingStock: parseQty(opening.text),
              minStock: parseQty(minStock.text),
              note: note.text.trim(),
            );
            if (dc.mounted) Navigator.pop(dc);
          },
          child: const Text('ذخیره'),
        ),
      ],
    ),
  );
}
