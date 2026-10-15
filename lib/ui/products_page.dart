import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import '../print/report_builders.dart';
import 'auth.dart';
import 'common.dart';
import 'print_dialog.dart';
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

  /// null = every group, '' = products without a group, otherwise a group id.
  String? groupFilter;

  @override
  Widget build(BuildContext context) => RepoBuilder<(List<Product>, List<ProductGroup>)>(
        repo: widget.repo,
        load: () async => (await widget.repo.products(), await widget.repo.productGroups()),
        builder: (c, data) {
          final (all, groups) = data;
          final gid = groups.any((g) => g.id == groupFilter) || groupFilter == '' ? groupFilter : null;
          final list = all
              .where((p) => (q.isEmpty || p.name.contains(q) || p.code.contains(q)) &&
                  (gid == null || (gid == '' ? p.groupId == null || !groups.any((g) => g.id == p.groupId) : p.groupId == gid)))
              .toList();
          final names = {for (final g in groups) g.id: g.name};
          final stockValue = all.fold<double>(0, (a, p) => a + (p.stock > 0 ? p.stock * p.buyPrice : 0));
          final low = all.where((p) => p.low).length;
          // Sections: one per group (in name order), then the products without a group.
          final sections = <(ProductGroup?, List<Product>)>[
            for (final g in groups) (g, [for (final p in list) if (p.groupId == g.id) p]),
            (null, [for (final p in list) if (p.groupId == null || !names.containsKey(p.groupId)) p]),
          ].where((s) => s.$2.isNotEmpty || (s.$1 != null && q.isEmpty && (gid == null || gid == s.$1!.id))).toList();
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
                Row(children: [
                  Expanded(child: SearchBox(onChanged: (v) => setState(() => q = v), hint: 'جستجوی نام یا کد کالا...')),
                  const SizedBox(width: 8),
                  PrintButton(repo: widget.repo, label: 'چاپ موجودی', doc: () => stockDoc(list, groups: names)),
                ]),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    ChoiceChip(label: const Text('همه'), selected: gid == null, onSelected: (_) => setState(() => groupFilter = null)),
                    for (final g in groups) ...[
                      const SizedBox(width: 8),
                      ChoiceChip(label: Text('${g.name} (${faDigits('${g.count}')})'), selected: gid == g.id, onSelected: (_) => setState(() => groupFilter = g.id)),
                    ],
                    if (groups.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ChoiceChip(label: const Text('بدون گروه'), selected: gid == '', onSelected: (_) => setState(() => groupFilter = '')),
                    ],
                    const SizedBox(width: 8),
                    ActionChip(avatar: const Icon(Icons.folder_outlined, size: 18), label: const Text('مدیریت گروه‌ها'), onPressed: () => showGroupsDialog(c, widget.repo)),
                  ]),
                ),
                const SizedBox(height: 12),
                if (all.isEmpty && groups.isEmpty)
                  emptyState('هنوز کالایی تعریف نشده است.\nبا دکمهٔ «کالای جدید» شروع کنید؛ اگر کالاها گروه‌بندی دارند، اول از «مدیریت گروه‌ها» گروه بسازید.')
                else if (sections.isEmpty)
                  emptyState('کالایی پیدا نشد.')
                else
                  for (final (g, items) in sections) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                      child: Row(children: [
                        Icon(g == null ? Icons.folder_off_outlined : Icons.folder_outlined, size: 20, color: Theme.of(c).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(child: Text('${g?.name ?? 'بدون گروه'} (${faDigits('${items.length}')})', style: Theme.of(c).textTheme.titleSmall)),
                        TextButton.icon(
                          onPressed: () => editProduct(c, widget.repo, presetGroup: g?.id),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(g == null ? 'کالای جدید' : 'کالا در این گروه'),
                        ),
                      ]),
                    ),
                    if (items.isEmpty)
                      const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 12), child: Text('هنوز کالایی در این گروه نیست.'))
                    else
                      Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Column(children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const Divider(),
                            _tile(c, items[i]),
                          ],
                        ]),
                      ),
                  ],
              ]),
            ),
            floatingActionButton: !AccessScope.of(context).canEdit('products') ? null : FloatingActionButton.extended(
              onPressed: () => editProduct(c, widget.repo, presetGroup: gid == '' ? null : gid),
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
      onTap: () => editProduct(c, widget.repo, product: p),
    );
  }
}

/// [presetGroup] is the group a new product starts in (when added from inside a group).
Future<void> editProduct(BuildContext c, Repo repo, {Product? product, String? presetGroup}) async {
  final p = product;
  var groups = await repo.productGroups();
  String? group = p?.groupId ?? presetGroup;
  if (!c.mounted) return;
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
    builder: (dc) => StatefulBuilder(builder: (dc, set) => AlertDialog(
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
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: ValueKey('$group${groups.length}'),
                    initialValue: groups.any((g) => g.id == group) ? group : null,
                    decoration: const InputDecoration(labelText: 'گروه کالایی'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('— بدون گروه —')),
                      for (final g in groups) DropdownMenuItem(value: g.id, child: Text(g.name)),
                    ],
                    onChanged: (v) => group = v,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'گروه جدید',
                  icon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: () async {
                    final name = await askGroupName(dc);
                    if (name == null) return;
                    final id = await repo.groupIdByName(name);
                    groups = await repo.productGroups();
                    set(() => group = id);
                  },
                ),
              ]),
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
              groupId: group,
              clearGroup: group == null,
            );
            if (dc.mounted) Navigator.pop(dc);
          },
          child: const Text('ذخیره'),
        ),
      ],
    )),
  );
}

/// Asks for the name of a new product group; null when cancelled.
Future<String?> askGroupName(BuildContext c, {String initial = '', String title = 'گروه کالایی جدید'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (dc) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'نام گروه (مثلاً چوب، پارچه، یراق)')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
        FilledButton(
          onPressed: () {
            final t = ctl.text.trim();
            if (t.isNotEmpty) Navigator.pop(dc, t);
          },
          child: const Text('ذخیره'),
        ),
      ],
    ),
  );
}

/// Add, rename and delete product groups. Deleting a group keeps its products.
Future<void> showGroupsDialog(BuildContext c, Repo repo) async {
  await showDialog<void>(
    context: c,
    builder: (dc) => RepoBuilder<List<ProductGroup>>(
      repo: repo,
      load: repo.productGroups,
      builder: (_, groups) => AlertDialog(
        title: const Text('گروه‌های کالایی'),
        content: SizedBox(
          width: 420,
          child: groups.isEmpty
              ? const Text('هنوز گروهی ندارید. مثلاً «چوب»، «پارچه» یا «یراق‌آلات» بسازید و کالاها را داخل آن تعریف کنید.')
              : ListView(shrinkWrap: true, children: [
                  for (final g in groups)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(g.name),
                      subtitle: Text('${faDigits('${g.count}')} کالا'),
                      onTap: () async {
                        final n = await askGroupName(dc, initial: g.name, title: 'تغییر نام گروه');
                        if (n != null) await repo.saveProductGroup(id: g.id, name: n);
                      },
                      trailing: IconButton(
                        tooltip: 'حذف گروه',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final msg = g.count > 0 ? 'گروه حذف شود؟ ${faDigits('${g.count}')} کالای آن حفظ می‌شود و بدون گروه می‌ماند.' : 'این گروه حذف شود؟';
                          if (await confirm(dc, msg)) await repo.deleteProductGroup(g.id);
                        },
                      ),
                    ),
                ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('بستن')),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('گروه جدید'),
            onPressed: () async {
              final n = await askGroupName(dc);
              if (n != null) await repo.saveProductGroup(name: n);
            },
          ),
        ],
      ),
    ),
  );
}
