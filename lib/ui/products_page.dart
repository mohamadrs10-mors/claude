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
                    if (AccessScope.of(c).canEdit('products')) ...[
                      const SizedBox(width: 8),
                      ActionChip(avatar: const Icon(Icons.percent, size: 18), label: const Text('تغییر درصدی قیمت‌ها'), onPressed: () => showPercentDialog(c, widget.repo, shown: list)),
                      const SizedBox(width: 8),
                      ActionChip(avatar: const Icon(Icons.attach_money, size: 18), label: Text(widget.repo.usdRate == 0 ? 'نرخ دلار' : 'نرخ دلار: ${inputNum(widget.repo.usdRate)}'), onPressed: () => showRateDialog(c, widget.repo)),
                    ],
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
  // Dollar prices: the price in the current currency follows the dollar rate.
  final usdSale = TextEditingController(text: p == null || p.usdSale == 0 ? '' : inputNum(p.usdSale));
  final usdBuy = TextEditingController(text: p == null || p.usdBuy == 0 ? '' : inputNum(p.usdBuy));
  final startRate = repo.usdRate;
  final rate = TextEditingController(text: startRate == 0 ? '' : inputNum(startRate));
  final pct = TextEditingController();
  var pctTarget = 'both';
  void reprice() {
    final r = parseMoneyNum(rate.text);
    if (r <= 0) return;
    final us = parseMoneyNum(usdSale.text), ub = parseMoneyNum(usdBuy.text);
    if (us > 0) sale.text = inputNum(Repo.fromUsd(us, r), decimals: 0);
    if (ub > 0) buy.text = inputNum(Repo.fromUsd(ub, r), decimals: 0);
  }

  for (final ctl in [usdSale, usdBuy, rate]) {
    ctl.addListener(reprice);
  }

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
              gap(8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(border: Border.all(color: Theme.of(dc).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('افزایش / کاهش درصدی قیمت', style: Theme.of(dc).textTheme.titleSmall),
                  gap(8),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: 110,
                      child: TextFormField(
                        controller: pct,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(labelText: 'درصد', suffixText: '٪', helperText: 'منفی = کاهش'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'both', label: Text('هر دو')),
                          ButtonSegment(value: 'sale', label: Text('فروش')),
                          ButtonSegment(value: 'buy', label: Text('خرید')),
                        ],
                        selected: {pctTarget},
                        onSelectionChanged: (v) => set(() => pctTarget = v.first),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () {
                        final v = parseQty(pct.text.replaceAll('−', '-'));
                        if (v == 0 || v <= -100) return toast(dc, 'درصد را وارد کنید (مثلاً ۱۰ یا -۵).');
                        final f = 1 + v / 100;
                        if (pctTarget != 'buy') {
                          sale.text = inputNum(Repo.changeByPercent(parseAmount(sale.text), v), decimals: 0);
                          final u = parseMoneyNum(usdSale.text);
                          if (u > 0) usdSale.text = inputNum(u * f);
                        }
                        if (pctTarget != 'sale') {
                          buy.text = inputNum(Repo.changeByPercent(parseAmount(buy.text), v), decimals: 0);
                          final u = parseMoneyNum(usdBuy.text);
                          if (u > 0) usdBuy.text = inputNum(u * f);
                        }
                        pct.clear();
                        set(() {});
                      },
                      child: const Text('اعمال'),
                    ),
                  ]),
                ]),
              ),
              gap(8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(border: Border.all(color: Theme.of(dc).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('قیمت ارزی (دلار)', style: Theme.of(dc).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text('اگر قیمت دلاری بدهید، قیمت فروش/خرید همیشه برابر «قیمت دلاری × نرخ دلار» است و با عوض کردن نرخ همین‌جا فوراً تغییر می‌کند.', style: Theme.of(dc).textTheme.bodySmall),
                  gap(8),
                  Row(children: [
                    Expanded(child: AmountField(controller: usdSale, label: 'فروش (دلار)', decimal: true, suffix: '\$')),
                    const SizedBox(width: 12),
                    Expanded(child: AmountField(controller: usdBuy, label: 'خرید (دلار)', decimal: true, suffix: '\$')),
                  ]),
                  gap(),
                  AmountField(controller: rate, label: 'نرخ هر دلار', decimal: true, helper: 'با ذخیره، قیمت بقیهٔ کالاهای دلاری هم با این نرخ به‌روز می‌شود'),
                ]),
              ),
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
            final newRate = parseMoneyNum(rate.text);
            final rateChanged = newRate > 0 && (newRate - startRate).abs() > 1e-9;
            // Changing the rate here changes every dollar-priced product; ask when others are affected.
            var applyRate = rateChanged;
            if (rateChanged) {
              final others = (await repo.products()).where((x) => x.id != p?.id && (x.usdSale > 0 || x.usdBuy > 0)).length;
              if (others > 0 && dc.mounted) {
                applyRate = await confirm(dc, 'نرخ دلار از ${inputNum(startRate)} به ${inputNum(newRate)} تغییر کرد. قیمت ${faDigits('$others')} کالای دلاری دیگر هم با نرخ تازه به‌روز شود؟ (اگر «خیر» بزنید فقط همین کالا عوض می‌شود و نرخ سراسری همان قبلی می‌ماند.)');
              }
            }
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
              usdSale: parseMoneyNum(usdSale.text),
              usdBuy: parseMoneyNum(usdBuy.text),
            );
            if (applyRate) await repo.applyUsdRate(newRate);
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

/// Raises or lowers the prices of many products by a percent: all of them or
/// only those on screen (the search / group filter).
Future<void> showPercentDialog(BuildContext context, Repo repo, {required List<Product> shown}) async {
  final pct = TextEditingController();
  var target = 'both', scope = 'shown', round = 1;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: const Text('تغییر درصدی قیمت‌ها'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: pct,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(labelText: 'درصد تغییر', suffixText: '٪', helperText: 'عدد مثبت = افزایش، عدد منفی = کاهش (مثلاً ۱۰ یا -۵)'),
              ),
              gap(),
              const Text('کدام قیمت'),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: 'both', label: Text('هر دو')), ButtonSegment(value: 'sale', label: Text('فروش')), ButtonSegment(value: 'buy', label: Text('خرید'))],
                selected: {target},
                onSelectionChanged: (v) => set(() => target = v.first),
              ),
              gap(),
              const Text('روی کدام کالاها'),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'shown', label: Text('نمایش‌داده‌شده (${faDigits('${shown.length}')})')),
                  const ButtonSegment(value: 'all', label: Text('همهٔ کالاها')),
                ],
                selected: {scope},
                onSelectionChanged: (v) => set(() => scope = v.first),
              ),
              gap(),
              DropdownButtonFormField<int>(
                initialValue: round,
                decoration: const InputDecoration(labelText: 'گرد کردن قیمت جدید'),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('بدون گرد کردن')),
                  DropdownMenuItem(value: 100, child: Text('به ۱۰۰')),
                  DropdownMenuItem(value: 1000, child: Text('به ۱٬۰۰۰')),
                  DropdownMenuItem(value: 10000, child: Text('به ۱۰٬۰۰۰')),
                ],
                onChanged: (v) => round = v ?? 1,
              ),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              final v = parseQty(pct.text.replaceAll('−', '-'));
              if (v == 0) return set(() => error = 'درصد را وارد کنید.');
              try {
                final n = await repo.adjustPrices(v, sale: target != 'buy', buy: target != 'sale', ids: scope == 'all' ? null : {for (final p in shown) p.id}, roundTo: round);
                if (dc.mounted) Navigator.pop(dc);
                if (context.mounted) toast(context, 'قیمت ${faDigits('$n')} کالا ${v > 0 ? 'افزایش' : 'کاهش'} یافت.');
              } catch (e) {
                set(() => error = e is StateError ? e.message : '$e');
              }
            },
            child: const Text('اعمال'),
          ),
        ],
      ),
    ),
  );
}

/// Sets the dollar rate for the whole company; every dollar-priced product follows.
Future<void> showRateDialog(BuildContext context, Repo repo) async {
  final rate = TextEditingController(text: repo.usdRate == 0 ? '' : inputNum(repo.usdRate));
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: const Text('نرخ دلار'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('قیمت کالاهایی که «قیمت ارزی (دلار)» دارند، با نرخ تازه دوباره حساب می‌شود (قیمت = دلار × نرخ).', style: Theme.of(dc).textTheme.bodySmall),
          gap(),
          AmountField(controller: rate, label: 'نرخ هر دلار', decimal: true),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              try {
                final n = await repo.applyUsdRate(parseMoneyNum(rate.text));
                if (dc.mounted) Navigator.pop(dc);
                if (context.mounted) toast(context, 'نرخ دلار ثبت شد؛ قیمت ${faDigits('$n')} کالا به‌روز شد.');
              } catch (e) {
                set(() => error = e is StateError ? e.message : '$e');
              }
            },
            child: const Text('ثبت و به‌روزرسانی قیمت‌ها'),
          ),
        ],
      ),
    ),
  );
}
