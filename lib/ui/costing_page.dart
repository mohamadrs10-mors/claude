import 'package:flutter/material.dart';

import '../data/costing.dart';
import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'thousands_formatter.dart';

class _LineCtl {
  _LineCtl({String name = '', this.type = 'amount', double value = 0, double rate = 1, this.perUnit = false})
      : name = TextEditingController(text: name),
        value = TextEditingController(text: value == 0 ? '' : (type == 'percent' ? plainNum(value) : inputNum(value))),
        rate = TextEditingController(text: rate == 1 ? '' : inputNum(rate));

  final TextEditingController name, value, rate;
  String type;
  bool perUnit;

  CostLine toLine() => CostLine(
        name: name.text.trim(),
        type: type,
        value: type == 'percent' ? parseNum(value.text) : parseMoneyNum(value.text),
        rate: rate.text.trim().isEmpty ? 1 : parseMoneyNum(rate.text),
        perUnit: perUnit,
      );

  void dispose() {
    name.dispose();
    value.dispose();
    rate.dispose();
  }
}

/// Calculates the final cost of one unit of a product (قیمت تمام‌شده) from its
/// cost components, then helps to turn that cost into a selling price with
/// several ready-made formulas and your own formulas.
class CostingPage extends StatefulWidget {
  const CostingPage({super.key, required this.repo, this.productId, this.embedded = false});
  final Repo repo;
  final String? productId;

  /// Inside the main navigation (no own app bar).
  final bool embedded;

  @override
  State<CostingPage> createState() => _CostingPageState();
}

class _CostingPageState extends State<CostingPage> {
  List<Product> products = [];
  Product? product;
  final batch = TextEditingController(text: '1');
  final waste = TextEditingController();
  final manualCost = TextEditingController();
  final lines = <_LineCtl>[];
  List<SavedFormula> saved = [];
  double roundStep = 0;
  bool loaded = false;
  bool hasSavedSheet = false;

  Repo get repo => widget.repo;

  static const _presets = [
    ('مواد اولیه / خرید', 'amount', false),
    ('دستمزد', 'amount', false),
    ('سربار', 'percent', false),
    ('بسته‌بندی', 'amount', true),
    ('حمل و نقل', 'amount', false),
    ('گمرک و عوارض', 'percent', false),
    ('خرید ارزی', 'fx', false),
    ('هزینهٔ دیگر', 'amount', false),
  ];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    batch.dispose();
    waste.dispose();
    manualCost.dispose();
    for (final l in lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    products = await repo.products();
    saved = await repo.formulas();
    final id = widget.productId;
    product = id == null ? null : products.where((p) => p.id == id).firstOrNull;
    await _loadSheet();
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _loadSheet() async {
    for (final l in lines) {
      l.dispose();
    }
    lines.clear();
    hasSavedSheet = false;
    final sheet = product == null ? null : await repo.costSheet(product!.id);
    if (sheet != null) {
      hasSavedSheet = true;
      batch.text = plainNum(sheet.batchQty);
      waste.text = sheet.wastePercent == 0 ? '' : plainNum(sheet.wastePercent);
      for (final l in sheet.lines) {
        lines.add(_LineCtl(name: l.name, type: l.type, value: l.value, rate: l.rate, perUnit: l.perUnit));
      }
    } else {
      batch.text = '1';
      waste.text = '';
      lines.add(_LineCtl(name: 'مواد اولیه / خرید', value: (product?.buyPrice ?? 0).toDouble()));
    }
    manualCost.text = '';
  }

  CostSheet get _sheet => CostSheet(
        batchQty: parseNum(batch.text),
        wastePercent: parseNum(waste.text),
        lines: [for (final l in lines) l.toLine()],
      );

  List<Listenable> get _all => [batch, waste, manualCost, for (final l in lines) ...[l.name, l.value, l.rate]];

  @override
  Widget build(BuildContext context) {
    final body = !loaded
        ? const Center(child: CircularProgressIndicator())
        : Constrained(
            maxWidth: 920,
            child: ListenableBuilder(
              listenable: Listenable.merge(_all),
              builder: (context, _) => _content(context),
            ),
          );
    if (widget.embedded) return Scaffold(body: body);
    return Scaffold(appBar: AppBar(title: const Text('قیمت تمام‌شده و قیمت‌گذاری')), body: body);
  }

  Widget _content(BuildContext c) {
    final res = computeCost(_sheet);
    final cost = res.valid && res.unitCost > 0 ? res.unitCost : parseMoneyNum(manualCost.text);
    final scheme = Theme.of(c).colorScheme;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 48), children: [
      Section(
        title: 'کالا',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<String?>(
            key: ValueKey('p${product?.id}'),
            initialValue: product?.id,
            decoration: const InputDecoration(labelText: 'کالای مورد نظر (برای ذخیره و ثبت قیمت)'),
            items: [
              const DropdownMenuItem(value: null, child: Text('بدون کالا — محاسبهٔ آزاد')),
              for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (v) async {
              product = v == null ? null : products.firstWhere((p) => p.id == v);
              await _loadSheet();
              if (mounted) setState(() {});
            },
          ),
          if (product != null) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              StatusChip('قیمت فروش: ${money(product!.salePrice)}', scheme.primary),
              StatusChip('قیمت خرید: ${money(product!.buyPrice)}', Colors.indigo),
              if (product!.costPrice > 0) StatusChip('تمام‌شدهٔ ذخیره‌شده: ${money(product!.costPrice)}', Colors.teal),
              StatusChip('موجودی: ${numText(product!.stock)} ${product!.unit}', Colors.orange.shade800),
            ]),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      Section(
        title: 'اجزای هزینه',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: batch,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'تعداد تولید / خرید در این دسته${product == null ? '' : ' (${product!.unit})'}'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: waste,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'ضایعات (درصد)', helperText: 'مثلاً ۵ یعنی ۵٪ خراب می‌شود'),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          for (var i = 0; i < lines.length; i++) _lineRow(c, i, res),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (name, type, perUnit) in _presets)
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: Text(name),
                onPressed: () => setState(() => lines.add(_LineCtl(name: name, type: type, perUnit: perUnit))),
              ),
          ]),
          const Divider(height: 28),
          _sumRow('جمع هزینه‌های مبلغی و ارزی', res.fixedTotal),
          if (res.percentTotal > 0) _sumRow('جمع هزینه‌های درصدی', res.percentTotal),
          _sumRow('کل هزینهٔ دسته', res.batchTotal, bold: true),
          if (parseNum(waste.text) > 0) _sumRow('تعداد سالم پس از ضایعات', res.goodQty, money: false),
          const SizedBox(height: 12),
          StatCard(
            title: 'قیمت تمام‌شدهٔ هر واحد',
            value: res.valid ? moneyC(res.unitCost.round()) : 'تعداد را درست وارد کنید',
            subtitle: res.valid && res.unitCost != res.unitCost.roundToDouble() ? '≈ ${numText(res.unitCost)} دقیق' : null,
            icon: Icons.calculate_outlined,
            color: scheme.primary,
          ),
          if (res.unitCost == 0) ...[
            const SizedBox(height: 12),
            AmountField(
              controller: manualCost,
              decimal: true,
              label: 'یا قیمت تمام‌شده را مستقیم وارد کنید',
              helper: 'اگر اجزای هزینه خالی است، فرمول‌های پایین از این عدد استفاده می‌کنند',
            ),
          ],
          if (product != null) ...[
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 10, children: [
              FilledButton.icon(
                onPressed: res.valid
                    ? () async {
                        await repo.saveCostSheet(product!.id, _sheet);
                        hasSavedSheet = true;
                        products = await repo.products();
                        product = products.firstWhere((p) => p.id == product!.id);
                        if (c.mounted) toast(c, 'برگهٔ هزینه ذخیره شد.');
                        if (mounted) setState(() {});
                      }
                    : null,
                icon: const Icon(Icons.save_outlined),
                label: const Text('ذخیرهٔ برگهٔ هزینه'),
              ),
              OutlinedButton.icon(
                onPressed: res.unitCost > 0 ? () => _apply(c, buy: res.unitCost) : null,
                icon: const Icon(Icons.shopping_cart_outlined),
                label: const Text('ثبت به‌عنوان قیمت خرید کالا'),
              ),
              if (hasSavedSheet)
                TextButton.icon(
                  onPressed: () async {
                    if (!await confirm(c, 'برگهٔ هزینهٔ ذخیره‌شدهٔ این کالا حذف شود؟')) return;
                    await repo.deleteCostSheet(product!.id);
                    products = await repo.products();
                    product = products.firstWhere((p) => p.id == product!.id);
                    await _loadSheet();
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف برگهٔ ذخیره‌شده'),
                ),
            ]),
          ],
        ]),
      ),
      const SizedBox(height: 16),
      Section(
        title: 'قیمت‌گذاری با فرمول‌های آماده',
        trailing: SizedBox(
          width: 170,
          child: DropdownButtonFormField<double>(
            initialValue: roundStep,
            isDense: true,
            decoration: const InputDecoration(labelText: 'گرد کردن به بالا'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('بدون گرد')),
              DropdownMenuItem(value: 100, child: Text('۱۰۰')),
              DropdownMenuItem(value: 1000, child: Text('۱٬۰۰۰')),
              DropdownMenuItem(value: 10000, child: Text('۱۰٬۰۰۰')),
              DropdownMenuItem(value: 100000, child: Text('۱۰۰٬۰۰۰')),
            ],
            onChanged: (v) => setState(() => roundStep = v ?? 0),
          ),
        ),
        child: cost <= 0
            ? const Text('ابتدا اجزای هزینه را وارد کنید تا قیمت تمام‌شده محاسبه شود.')
            : Column(children: [
                _FormulaCard(
                  key: ValueKey('markup${product?.id}'),
                  title: 'سود درصدی روی قیمت تمام‌شده',
                  help: 'قیمت فروش = قیمت تمام‌شده × (۱ + درصد سود)',
                  fields: const [_F('درصد سود', '25', '٪')],
                  compute: (v) {
                    final price = Pricing.markup(cost, v[0]);
                    return _priceOutputs(cost, price);
                  },
                  step: roundStep,
                  onApply: product == null ? null : (p) => _apply(c, sale: p),
                ),
                _FormulaCard(
                  key: ValueKey('margin${product?.id}'),
                  title: 'حاشیهٔ سود از قیمت فروش',
                  help: 'قیمت فروش = قیمت تمام‌شده ÷ (۱ − حاشیه سود). سود این‌قدر درصد از خود قیمت فروش می‌شود.',
                  fields: const [_F('حاشیهٔ سود', '20', '٪')],
                  compute: (v) {
                    final price = Pricing.margin(cost, v[0]);
                    return price == null ? null : _priceOutputs(cost, price);
                  },
                  step: roundStep,
                  onApply: product == null ? null : (p) => _apply(c, sale: p),
                ),
                _FormulaCard(
                  key: ValueKey('fixed${product?.id}'),
                  title: 'مبلغ سود ثابت',
                  help: 'قیمت فروش = قیمت تمام‌شده + سود ثابت برای هر واحد',
                  fields: [_F('سود هر واحد', '${(cost * 0.2).round()}', currencyLabel)],
                  compute: (v) => _priceOutputs(cost, Pricing.fixedProfit(cost, v[0])),
                  step: roundStep,
                  onApply: product == null ? null : (p) => _apply(c, sale: p),
                ),
                _FormulaCard(
                  key: ValueKey('target${product?.id}'),
                  title: 'تحلیل یک قیمت دلخواه',
                  help: 'یک قیمت فروش بنویسید تا سود و درصدهای آن را ببینید.',
                  fields: [_F('قیمت فروش', product != null && product!.salePrice > 0 ? '${product!.salePrice}' : '${(cost * 1.3).round()}', currencyLabel)],
                  compute: (v) => _priceOutputs(cost, v[0], showPrice: false),
                  step: 0,
                ),
                _FormulaCard(
                  key: ValueKey('discount${product?.id}'),
                  title: 'تخفیف و مالیات',
                  help: 'قیمتی را پیدا می‌کند که بعد از دادن تخفیف به مشتری هم سود دلخواه بماند و مالیات را نشان می‌دهد.',
                  fields: [
                    const _F('درصد سود بعد از تخفیف', '25', '٪'),
                    const _F('تخفیف به مشتری', '10', '٪'),
                    _F('مالیات', repo.setting('default_tax', '10'), '٪'),
                  ],
                  compute: (v) {
                    final list = Pricing.listPrice(cost, v[0], v[1]);
                    if (list == null) return null;
                    final after = list * (1 - v[1] / 100);
                    return [
                      _Out('قیمت اعلامی (قبل از تخفیف)', list, price: true),
                      _Out('قیمت پس از تخفیف', after),
                      _Out('قیمت نهایی با مالیات', Pricing.addVat(after, v[2])),
                      _Out('سود هر واحد پس از تخفیف', after - cost),
                    ];
                  },
                  step: roundStep,
                  onApply: product == null ? null : (p) => _apply(c, sale: p),
                ),
                _FormulaCard(
                  key: ValueKey('vat${product?.id}'),
                  title: 'قیمت با مالیات / بدون مالیات',
                  help: 'یک قیمت بنویسید: هم با افزودن مالیات و هم با جدا کردن مالیات از آن نمایش داده می‌شود.',
                  fields: [
                    _F('قیمت', product != null && product!.salePrice > 0 ? '${product!.salePrice}' : '${(cost * 1.25).round()}', currencyLabel),
                    _F('مالیات', repo.setting('default_tax', '10'), '٪'),
                  ],
                  compute: (v) {
                    final without = Pricing.removeVat(v[0], v[1]);
                    return [
                      _Out('اگر مالیات به قیمت اضافه شود', Pricing.addVat(v[0], v[1])),
                      if (without != null) _Out('اگر قیمت شامل مالیات باشد: قیمت بدون مالیات', without),
                      if (without != null) _Out('مبلغ مالیات داخل قیمت', v[0] - without),
                    ];
                  },
                  step: 0,
                ),
                _FormulaCard(
                  key: ValueKey('be${product?.id}'),
                  title: 'نقطهٔ سر به سر',
                  help: 'چند واحد باید فروخت تا هزینه‌های ثابت (اجاره، حقوق...) جبران شود؟ تعداد = هزینهٔ ثابت ÷ (قیمت فروش − قیمت تمام‌شده)',
                  fields: [
                    _F('هزینه‌های ثابت دوره', '10000000', currencyLabel),
                    _F('قیمت فروش', product != null && product!.salePrice > 0 ? '${product!.salePrice}' : '${(cost * 1.3).round()}', currencyLabel),
                  ],
                  compute: (v) {
                    final q = Pricing.breakEvenQty(v[0], v[1], cost);
                    if (q == null) return [const _Out('قیمت فروش کمتر از قیمت تمام‌شده است؛ سر به سر نمی‌شود.', null)];
                    return [
                      _Out('تعداد لازم', q.ceilToDouble(), money: false),
                      _Out('مبلغ فروش لازم', q.ceilToDouble() * v[1]),
                    ];
                  },
                  step: 0,
                ),
                _FormulaCard(
                  key: ValueKey('avg${product?.id}'),
                  title: 'میانگین موزون قیمت (خرید جدید)',
                  help: 'وقتی کالا را با قیمت جدید می‌خرید، میانگین قیمت تمام‌شدهٔ انبار چقدر می‌شود؟ قیمت دسته‌ٔ جدید همین قیمت تمام‌شدهٔ بالاست.',
                  fields: [
                    _F('موجودی فعلی', plainNum((product?.stock ?? 0) < 0 ? 0 : (product?.stock ?? 0)), product?.unit ?? 'واحد'),
                    _F('قیمت تمام‌شدهٔ فعلی', '${product != null ? (product!.costPrice > 0 ? product!.costPrice : product!.buyPrice) : 0}', currencyLabel),
                    _F('تعداد خرید جدید', plainNum(parseNum(batch.text)), product?.unit ?? 'واحد'),
                  ],
                  compute: (v) {
                    final avg = Pricing.weightedAverage(v[0], v[1], v[2], cost);
                    return avg == null ? null : [_Out('میانگین موزون جدید', avg, price: true, applyAsBuy: true)];
                  },
                  step: 0,
                  onApply: product == null ? null : (p) => _apply(c, buy: p),
                ),
              ]),
      ),
      const SizedBox(height: 16),
      _customSection(c, cost, res),
    ]);
  }

  List<_Out> _priceOutputs(double cost, double price, {bool showPrice = true}) {
    final a = Pricing.analyze(cost, price);
    return [
      if (showPrice) _Out('قیمت فروش پیشنهادی', price, price: true),
      _Out('سود هر واحد', a.profit),
      if (a.margin != null) _Out('حاشیهٔ سود از فروش', a.margin, percent: true),
      if (a.markup != null) _Out('درصد سود روی تمام‌شده', a.markup, percent: true),
    ];
  }

  Future<void> _apply(BuildContext c, {double? sale, double? buy}) async {
    final p = product;
    if (p == null) return;
    await repo.setProductPrice(p.id, salePrice: sale?.round(), buyPrice: buy?.round());
    products = await repo.products();
    product = products.firstWhere((x) => x.id == p.id);
    if (c.mounted) {
      toast(c, sale != null ? 'قیمت فروش «${p.name}» روی ${moneyC(sale.round())} تنظیم شد.' : 'قیمت خرید «${p.name}» روی ${moneyC(buy!.round())} تنظیم شد.');
    }
    if (mounted) setState(() {});
  }

  Map<String, double> _vars(double cost, CostResult res) => {
        'cost': cost,
        'buy': (product?.buyPrice ?? 0).toDouble(),
        'sale': (product?.salePrice ?? 0).toDouble(),
        'qty': parseNum(batch.text),
        'stock': product?.stock ?? 0,
        'vat': parseNum(repo.setting('default_tax', '0')),
        'waste': parseNum(waste.text),
      };

  Widget _customSection(BuildContext c, double cost, CostResult res) {
    final vars = _vars(cost, res);
    return Section(
      title: 'فرمول‌های دلخواه من',
      trailing: FilledButton.tonalIcon(
        onPressed: () => _editFormula(c, vars),
        icon: const Icon(Icons.add),
        label: const Text('فرمول جدید'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'هر فرمولی بنویسید؛ مثلاً  cost * (1 + 30%) + 5000  یا  ceil(cost / (1 - 0.2), 1000)',
          style: Theme.of(c).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (saved.isEmpty) const Text('هنوز فرمولی ذخیره نکرده‌اید.'),
        for (final f in saved) _savedTile(c, f, vars),
      ]),
    );
  }

  Widget _savedTile(BuildContext c, SavedFormula f, Map<String, double> vars) {
    double? value;
    String? error;
    try {
      value = Pricing.roundUp(Expr.evaluate(f.expression, vars), roundStep);
    } on FormatException catch (e) {
      error = e.message;
    }
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        title: Text(f.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(error ?? f.expression, textDirection: error == null ? TextDirection.ltr : null, style: error == null ? null : TextStyle(color: Theme.of(c).colorScheme.error)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (value != null) Text(moneyC(value.round()), style: const TextStyle(fontWeight: FontWeight.w700)),
          if (value != null && product != null)
            IconButton(tooltip: 'ثبت به‌عنوان قیمت فروش', icon: const Icon(Icons.check_circle_outline), onPressed: () => _apply(c, sale: value)),
          IconButton(tooltip: 'ویرایش', icon: const Icon(Icons.edit_outlined), onPressed: () => _editFormula(c, vars, f)),
        ]),
      ),
    );
  }

  Future<void> _editFormula(BuildContext c, Map<String, double> vars, [SavedFormula? f]) async {
    final name = TextEditingController(text: f?.name);
    final expr = TextEditingController(text: f?.expression ?? 'cost * (1 + 25%)');
    await showDialog(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) {
          String preview;
          var ok = true;
          try {
            preview = '= ${moneyC(Pricing.roundUp(Expr.evaluate(expr.text, vars), roundStep).round())}';
          } on FormatException catch (e) {
            preview = e.message;
            ok = false;
          }
          return AlertDialog(
            title: Text(f == null ? 'فرمول جدید' : 'ویرایش فرمول'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'نام فرمول')),
                  const SizedBox(height: 12),
                  TextField(
                    controller: expr,
                    textDirection: TextDirection.ltr,
                    onChanged: (_) => set(() {}),
                    decoration: const InputDecoration(labelText: 'فرمول'),
                  ),
                  const SizedBox(height: 8),
                  Text(preview, style: TextStyle(fontWeight: FontWeight.w700, color: ok ? Theme.of(dc).colorScheme.primary : Theme.of(dc).colorScheme.error)),
                  const SizedBox(height: 14),
                  Text('متغیرها (با مقدار فعلی):', style: Theme.of(dc).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final (k, label) in const [
                      ('cost', 'قیمت تمام‌شده'),
                      ('buy', 'قیمت خرید'),
                      ('sale', 'قیمت فروش'),
                      ('qty', 'تعداد دسته'),
                      ('stock', 'موجودی'),
                      ('vat', 'مالیات٪'),
                      ('waste', 'ضایعات٪'),
                    ])
                      ActionChip(
                        label: Text('$k = ${numText(vars[k] ?? 0)}  ($label)', textDirection: TextDirection.ltr),
                        onPressed: () {
                          final t = expr.text, sel = expr.selection;
                          final at = sel.isValid ? sel.end : t.length;
                          expr.text = t.substring(0, at) + k + t.substring(at);
                          expr.selection = TextSelection.collapsed(offset: at + k.length);
                          set(() {});
                        },
                      ),
                  ]),
                  const SizedBox(height: 10),
                  Text(
                    'عملگرها: + - * / ^ و پرانتز. درصد: 25% یعنی ۰٫۲۵.\n'
                    'توابع: round  ceil  floor (با گام، مثلاً ceil(x, 1000))، abs، sqrt، min، max.',
                    style: Theme.of(dc).textTheme.bodySmall,
                  ),
                ]),
              ),
            ),
            actions: [
              if (f != null)
                TextButton(
                  onPressed: () async {
                    if (!await confirm(dc, 'این فرمول حذف شود؟')) return;
                    await repo.deleteFormula(f.id);
                    if (dc.mounted) Navigator.pop(dc);
                  },
                  child: const Text('حذف'),
                ),
              TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
              FilledButton(
                onPressed: ok && name.text.trim().isNotEmpty
                    ? () async {
                        await repo.saveFormula(id: f?.id, name: name.text.trim(), expression: expr.text.trim());
                        if (dc.mounted) Navigator.pop(dc);
                      }
                    : null,
                child: const Text('ذخیره'),
              ),
            ],
          );
        },
      ),
    );
    saved = await repo.formulas();
    if (mounted) setState(() {});
  }

  Widget _sumRow(String l, double v, {bool bold = false, bool money = true}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(l, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
          const Spacer(),
          Text(money ? moneyC(v.round()) : numText(v), style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
        ]),
      );

  Widget _lineRow(BuildContext c, int i, CostResult res) {
    final l = lines[i];
    final total = i < res.lineTotals.length ? res.lineTotals[i] : 0.0;
    final theme = Theme.of(c);
    const typeLabels = {'amount': 'مبلغ ثابت', 'percent': 'درصد از جمع', 'fx': 'ارزی'};
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(14)),
      child: Column(children: [
        Row(children: [
          Expanded(child: TextField(controller: l.name, decoration: const InputDecoration(labelText: 'عنوان هزینه', isDense: true))),
          IconButton(
            tooltip: 'حذف ردیف',
            onPressed: lines.length == 1 ? null : () => setState(() => lines.removeAt(i).dispose()),
            icon: const Icon(Icons.close),
          ),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<String>(
              initialValue: l.type,
              isDense: true,
              decoration: const InputDecoration(labelText: 'نوع'),
              items: [for (final e in typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) => setState(() => l.type = v!),
            ),
          ),
          SizedBox(
            width: 170,
            child: l.type == 'percent'
                ? TextField(
                    controller: l.value,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'درصد', suffixText: '٪', isDense: true),
                  )
                : AmountField(
                    controller: l.value,
                    label: l.type == 'fx' ? 'مبلغ به ارز' : 'مبلغ',
                    suffix: l.type == 'fx' ? '' : null,
                    decimal: true,
                    dense: true,
                  ),
          ),
          if (l.type == 'fx')
            SizedBox(
              width: 170,
              child: AmountField(controller: l.rate, label: 'نرخ هر واحد ارز', decimal: true, dense: true),
            ),
          if (l.type != 'percent')
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<bool>(
                initialValue: l.perUnit,
                isDense: true,
                decoration: const InputDecoration(labelText: 'محاسبه برای'),
                items: const [
                  DropdownMenuItem(value: false, child: Text('کل دسته')),
                  DropdownMenuItem(value: true, child: Text('هر واحد')),
                ],
                onChanged: (v) => setState(() => l.perUnit = v!),
              ),
            ),
          Text('= ${moneyC(total.round())}', style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }
}

class _F {
  const _F(this.label, this.initial, this.suffix);
  final String label, initial, suffix;

  /// Amount fields (suffix is the currency) get thousands separators.
  bool get money => suffix == currencyLabel;
}

class _Out {
  const _Out(this.label, this.value, {this.price = false, this.percent = false, this.money = true, this.applyAsBuy = false});
  final String label;
  final double? value;

  /// A selling (or buying) price that can be rounded and applied to the product.
  final bool price;
  final bool percent;
  final bool money;
  final bool applyAsBuy;
}

/// One ready-made formula: a few number fields and the results computed live.
class _FormulaCard extends StatefulWidget {
  const _FormulaCard({
    super.key,
    required this.title,
    required this.help,
    required this.fields,
    required this.compute,
    required this.step,
    this.onApply,
  });

  final String title, help;
  final List<_F> fields;
  final List<_Out>? Function(List<double> values) compute;
  final double step;
  final void Function(double price)? onApply;

  @override
  State<_FormulaCard> createState() => _FormulaCardState();
}

class _FormulaCardState extends State<_FormulaCard> {
  late final List<TextEditingController> ctl = [
    for (final f in widget.fields) TextEditingController(text: f.money ? inputNum(double.tryParse(f.initial) ?? 0) : f.initial),
  ];

  @override
  void dispose() {
    for (final c in ctl) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(widget.help, style: theme.textTheme.bodySmall),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (var i = 0; i < ctl.length; i++)
            SizedBox(
              width: 190,
              child: TextField(
                controller: ctl[i],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: widget.fields[i].money ? [ThousandsFormatter(decimal: true)] : null,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: widget.fields[i].label, suffixText: widget.fields[i].suffix, isDense: true),
              ),
            ),
        ]),
        const SizedBox(height: 10),
        ..._results(context),
      ]),
    );
  }

  List<Widget> _results(BuildContext context) {
    final outs = widget.compute([for (var i = 0; i < ctl.length; i++) widget.fields[i].money ? parseMoneyNum(ctl[i].text) : parseNum(ctl[i].text)]);
    if (outs == null) return [Text('با این مقدارها قابل محاسبه نیست.', style: TextStyle(color: Theme.of(context).colorScheme.error))];
    return [
      for (final o in outs)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(o.label)),
            if (o.value != null)
              Text(
                o.percent ? '${numText(o.value!, 1)}٪' : (o.money ? moneyC(Pricing.roundUp(o.value!, o.price ? widget.step : 0).round()) : numText(o.value!)),
                style: TextStyle(fontWeight: o.price ? FontWeight.w800 : FontWeight.w600, color: o.value! < 0 && !o.price ? Theme.of(context).colorScheme.error : null),
              ),
            if (o.price && o.value != null && widget.onApply != null)
              IconButton(
                tooltip: o.applyAsBuy ? 'ثبت به‌عنوان قیمت خرید کالا' : 'ثبت به‌عنوان قیمت فروش کالا',
                icon: const Icon(Icons.check_circle_outline),
                onPressed: () => widget.onApply!(Pricing.roundUp(o.value!, widget.step)),
              ),
          ]),
        ),
    ];
  }
}
