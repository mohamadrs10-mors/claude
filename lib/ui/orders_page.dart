import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'invoices_page.dart';
import 'parties_page.dart';
import 'products_page.dart';

/// Orders with an advance payment: the customer orders a quantity of a
/// product and pays part of it up front; every sale invoice made for the
/// order counts that percent as already paid.
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<(List<Order>, Map<String, String>)>(
        repo: repo,
        load: () async => (await repo.orders(), {for (final p in await repo.parties()) p.id: p.name}),
        builder: (c, d) {
          final (list, names) = d;
          final held = list.fold<int>(0, (a, o) => a + o.available);
          return Scaffold(
            body: Constrained(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                StatCard(title: 'پیش‌دریافت‌های هنوز کسرنشده', value: moneyC(held), icon: Icons.savings_outlined, color: Colors.orange.shade800),
                const SizedBox(height: 8),
                Text(
                  'مشتری سفارش یک کالا را می‌دهد و بخشی از مبلغ را پیش‌پرداخت می‌کند. این پول به حساب شما می‌رود ولی مشتری بستانکار نمی‌شود. '
                  'روی هر فاکتور فروشی که برای این سفارش بزنید، همان درصد پیش‌دریافت از جمع فاکتور پرداخت‌شده حساب می‌شود و مشتری فقط بدهکار مانده است.',
                  style: Theme.of(c).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  emptyState('سفارشی ثبت نشده است.')
                else
                  Card(
                    child: Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(),
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(c).colorScheme.primaryContainer,
                            foregroundColor: Theme.of(c).colorScheme.onPrimaryContainer,
                            child: Text(faDigits('${list[i].number}'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          ),
                          title: Text('${names[list[i].partyId] ?? '؟'} • ${list[i].title}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('تحویل‌شده ${qtyText(list[i].invoicedQty)} از ${qtyText(list[i].qty)} • پیش‌دریافت ${faDigits(qtyText(list[i].percent))}٪'),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(list[i].total), style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            StatusChip(list[i].open ? 'باز' : 'بسته‌شده', list[i].open ? Colors.green.shade700 : Colors.blueGrey),
                          ]),
                          onTap: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => OrderViewPage(repo: repo, orderId: list[i].id))),
                        ),
                      ],
                    ]),
                  ),
              ]),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => openOrderEditor(c, repo),
              icon: const Icon(Icons.add),
              label: const Text('سفارش جدید'),
            ),
          );
        },
      );
}

Future<void> openOrderEditor(BuildContext c, Repo repo, {String? id}) =>
    Navigator.push(c, MaterialPageRoute<void>(builder: (_) => OrderEditPage(repo: repo, orderId: id)));

class OrderViewPage extends StatelessWidget {
  const OrderViewPage({super.key, required this.repo, required this.orderId});
  final Repo repo;
  final String orderId;

  @override
  Widget build(BuildContext context) => RepoBuilder<(Order?, Party?, List<Invoice>, String)>(
        repo: repo,
        load: () async {
          final o = (await repo.orders()).where((x) => x.id == orderId).firstOrNull;
          if (o == null) return (null, null, <Invoice>[], '');
          final party = (await repo.parties()).where((p) => p.id == o.partyId).firstOrNull;
          final unit = (await repo.products()).where((p) => p.id == o.productId).firstOrNull?.unit ?? '';
          return (o, party, (await repo.invoices()).where((i) => i.orderId == o.id).toList(), unit);
        },
        builder: (c, d) {
          final (o, party, invoices, unit) = d;
          if (o == null) return const Scaffold(body: Center(child: Text('این سفارش حذف شد.')));
          Widget row(String l, String v, {bool bold = false}) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Text(l, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
                  const Spacer(),
                  Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
                ]),
              );
          return Scaffold(
            appBar: AppBar(
              title: Text('سفارش ${faDigits('${o.number}')}'),
              actions: [
                IconButton(tooltip: 'ویرایش', icon: const Icon(Icons.edit_outlined), onPressed: () => openOrderEditor(c, repo, id: o.id)),
                IconButton(
                  tooltip: 'حذف',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (!await confirm(c, 'این سفارش و دریافت پیش‌دریافتش حذف شود؟')) return;
                    final err = await repo.deleteOrder(o.id);
                    if (!c.mounted) return;
                    if (err != null) {
                      toast(c, err);
                    } else {
                      Navigator.pop(c);
                    }
                  },
                ),
              ],
            ),
            body: Constrained(
              maxWidth: 820,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(party?.name ?? '؟', style: Theme.of(c).textTheme.titleMedium)),
                        StatusChip(o.open ? 'باز' : 'بسته‌شده', o.open ? Colors.green.shade700 : Colors.blueGrey),
                      ]),
                      Text('تاریخ: ${jalaliText(o.date)}'),
                      if (o.note.isNotEmpty) Text('توضیحات: ${o.note}'),
                      const Divider(height: 24),
                      row('کالا', o.title),
                      row('تعداد سفارش', '${qtyText(o.qty)} $unit'.trim()),
                      row('قیمت واحد', money(o.unitPrice)),
                      row('جمع سفارش', moneyC(o.total), bold: true),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: o.qty <= 0 ? 0 : (o.invoicedQty / o.qty).clamp(0, 1).toDouble()),
                      const SizedBox(height: 4),
                      Text('فاکتورشده ${qtyText(o.invoicedQty)} از ${qtyText(o.qty)} (مانده ${qtyText(o.remainingQty < 0 ? 0 : o.remainingQty)})', style: Theme.of(c).textTheme.bodySmall),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      row('درصد پیش‌دریافت', '${faDigits(qtyText(o.percent))}٪'),
                      row('پیش‌دریافت دریافت‌شده', moneyC(o.advance), bold: true),
                      row('کسرشده روی فاکتورها', moneyC(o.applied)),
                      if (o.released > 0) row('تبدیل‌شده به اعتبار مشتری', moneyC(o.released)),
                      row('باقی‌ماندهٔ قابل کسر', moneyC(o.available), bold: true),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  if (o.open)
                    FilledButton.icon(
                      onPressed: () => openInvoiceEditor(c, repo, partyId: o.partyId, orderId: o.id),
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('صدور فاکتور برای این سفارش'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final msg = o.open
                          ? (o.available > 0
                              ? 'سفارش بسته شود؟ ${moneyC(o.available)} از پیش‌دریافت که روی فاکتوری نرفته به‌عنوان اعتبار (بستانکاری) مشتری ثبت می‌شود.'
                              : 'سفارش بسته شود؟')
                          : 'سفارش دوباره باز شود؟ اعتبار ثبت‌شده برای مشتری برگردانده می‌شود.';
                      if (await confirm(c, msg)) await repo.setOrderOpen(o.id, !o.open);
                    },
                    icon: Icon(o.open ? Icons.lock_outline : Icons.lock_open),
                    label: Text(o.open ? 'بستن سفارش' : 'بازکردن دوباره'),
                  ),
                ]),
                const SizedBox(height: 16),
                Text('فاکتورهای این سفارش', style: Theme.of(c).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (invoices.isEmpty)
                  const Padding(padding: EdgeInsets.all(12), child: Text('هنوز فاکتوری برای این سفارش صادر نشده است.'))
                else
                  Card(
                    child: Column(children: [
                      for (final i in invoices)
                        ListTile(
                          dense: true,
                          title: Text('${i.info.label} ${faDigits('${i.number}')} • ${jalaliText(i.date)}'),
                          subtitle: Text('جمع ${money(i.total)} • از پیش‌دریافت ${money(i.prepaid)} • مانده ${money(i.remaining)}'),
                          onTap: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => InvoiceViewPage(repo: repo, invoiceId: i.id))),
                        ),
                    ]),
                  ),
              ]),
            ),
          );
        },
      );
}

class OrderEditPage extends StatefulWidget {
  const OrderEditPage({super.key, required this.repo, this.orderId});
  final Repo repo;
  final String? orderId;
  @override
  State<OrderEditPage> createState() => _OrderEditPageState();
}

class _OrderEditPageState extends State<OrderEditPage> {
  final key = GlobalKey<FormState>();
  final number = TextEditingController();
  final title = TextEditingController();
  final qty = TextEditingController(text: '1');
  final price = TextEditingController();
  final percent = TextEditingController(text: '50');
  final advance = TextEditingController();
  final note = TextEditingController();
  final focus = FocusNode();
  List<Party> parties = [];
  List<Product> products = [];
  List<Account> accounts = [];
  String date = todayIso();
  String? partyId, productId, accountId;
  bool loaded = false;
  bool advanceTouched = false;
  String _autoText = '';

  Repo get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    for (final c in [qty, price, percent]) {
      c.addListener(_syncAdvance);
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [number, title, qty, price, percent, advance, note]) {
      c.dispose();
    }
    focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    parties = await repo.parties();
    products = await repo.products();
    accounts = await repo.accounts();
    if (widget.orderId != null) {
      final o = (await repo.orders()).firstWhere((x) => x.id == widget.orderId);
      number.text = '${o.number}';
      date = o.date;
      partyId = o.partyId;
      productId = o.productId;
      title.text = o.title;
      qty.text = qtyText(o.qty);
      price.text = money(o.unitPrice);
      percent.text = qtyText(o.percent);
      advance.text = money(o.advance);
      advanceTouched = true;
      accountId = o.accountId;
      note.text = o.note;
    } else {
      number.text = '${await repo.nextOrderNumber()}';
      accountId = accounts.firstOrNull?.id;
    }
    if (mounted) setState(() => loaded = true);
  }

  double get _qty => parseQty(qty.text);
  double get _pct => parseQty(percent.text).clamp(0, 100).toDouble();
  int get _total => (_qty * parseAmount(price.text)).round();

  /// The advance follows qty x price x percent until it is typed by hand.
  void _syncAdvance() {
    if (advanceTouched || !loaded) return;
    final v = (_total * _pct / 100).round();
    _autoText = v == 0 ? '' : money(v);
    advance.text = _autoText;
  }

  void _pick(Product p) {
    productId = p.id;
    title.text = p.name;
    if (p.salePrice > 0) price.text = money(p.salePrice);
    setState(() {});
  }

  Future<void> _save() async {
    if (!key.currentState!.validate()) return;
    try {
      await repo.saveOrder(
        id: widget.orderId,
        number: parseAmount(number.text),
        date: date,
        partyId: partyId!,
        productId: productId,
        title: title.text.trim(),
        qty: _qty,
        unitPrice: parseAmount(price.text),
        percent: _pct,
        advance: parseAmount(advance.text),
        accountId: accountId,
        note: note.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } on StateError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(widget.orderId == null ? 'سفارش جدید' : 'ویرایش سفارش')),
      body: Constrained(
        maxWidth: 860,
        child: Form(
          key: key,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Section(
              title: 'مشخصات سفارش',
              child: Column(children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: number,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'شمارهٔ سفارش'),
                      validator: (v) => parseAmount(v ?? '') <= 0 ? 'شمارهٔ نامعتبر' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: JalaliDateField(iso: date, onChanged: (v) => setState(() => date = v))),
                ]),
                gap(),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey('$partyId${parties.length}'),
                      initialValue: partyId,
                      decoration: const InputDecoration(labelText: 'مشتری'),
                      items: [for (final p in parties) DropdownMenuItem(value: p.id, child: Text(p.name))],
                      validator: (v) => v == null ? 'یک مشتری انتخاب کنید' : null,
                      onChanged: (v) => partyId = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'شخص جدید',
                    onPressed: () async {
                      final before = parties.map((p) => p.id).toSet();
                      await editParty(context, repo);
                      final now = await repo.parties();
                      final added = now.where((p) => !before.contains(p.id)).firstOrNull;
                      if (!mounted) return;
                      setState(() {
                        parties = now;
                        if (added != null) partyId = added.id;
                      });
                    },
                    icon: const Icon(Icons.person_add_alt),
                  ),
                ]),
              ]),
            ),
            gap(16),
            Section(
              title: 'کالای سفارش‌داده‌شده',
              child: Column(children: [
                LayoutBuilder(
                  builder: (context, box) => RawAutocomplete<Product>(
                    textEditingController: title,
                    focusNode: focus,
                    displayStringForOption: (p) => p.name,
                    optionsBuilder: (v) {
                      final t = v.text.trim();
                      if (products.isEmpty) return const Iterable<Product>.empty();
                      return products.where((p) => t.isEmpty || p.name.contains(t) || (p.code.isNotEmpty && p.code.contains(enDigits(t)))).take(8);
                    },
                    onSelected: _pick,
                    fieldViewBuilder: (c, ctl, fn, _) => TextFormField(
                      controller: ctl,
                      focusNode: fn,
                      decoration: InputDecoration(labelText: 'کالا', suffixIcon: products.isEmpty ? null : const Icon(Icons.search)),
                      onChanged: (v) {
                        final p = products.where((p) => p.id == productId).firstOrNull;
                        if (p != null && p.name != v) productId = null;
                      },
                      validator: (v) => (v ?? '').trim().isEmpty ? 'نام کالا؟' : null,
                    ),
                    optionsViewBuilder: (c, onSel, opts) => Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Material(
                        elevation: 6,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: 260, maxWidth: box.maxWidth),
                          child: ListView(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            children: [
                              for (final p in opts)
                                ListTile(dense: true, title: Text(p.name), subtitle: Text('موجودی ${qtyText(p.stock)} ${p.unit} • ${money(p.salePrice)}'), onTap: () => onSel(p)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                gap(),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextFormField(
                      controller: qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'کل تعداد سفارش'),
                      validator: (v) => _qty <= 0 ? 'نامعتبر' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: AmountField(controller: price, label: 'قیمت واحد')),
                ]),
                gap(),
                ListenableBuilder(
                  listenable: Listenable.merge([qty, price]),
                  builder: (_, _) => Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('جمع سفارش: ${moneyC(_total)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
            gap(16),
            Section(
              title: 'پیش‌دریافت',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: TextFormField(
                      controller: percent,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'درصد پیش‌دریافت', suffixText: '٪'),
                      validator: (v) => _pct <= 0 ? 'درصد؟' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    // Once the amount is edited by hand it stops following the percent.
                    child: Focus(
                      onFocusChange: (f) {
                        if (!f && advance.text != _autoText) advanceTouched = true;
                      },
                      child: AmountField(
                        controller: advance,
                        label: 'مبلغ دریافت‌شده',
                        helper: 'خودکار از درصد؛ اگر کمتر یا بیشتر گرفتید بنویسید',
                      ),
                    ),
                  ),
                ]),
                gap(),
                DropdownButtonFormField<String?>(
                  key: ValueKey('acc${accounts.length}'),
                  initialValue: accountId,
                  decoration: const InputDecoration(labelText: 'واریز به حساب'),
                  items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                  validator: (v) => parseAmount(advance.text) > 0 && v == null ? 'حساب را انتخاب کنید' : null,
                  onChanged: (v) => accountId = v,
                ),
                gap(),
                Text(
                  'این مبلغ به حساب انتخاب‌شده اضافه می‌شود ولی مشتری بستانکار نمی‌شود. روی هر فاکتور فروشِ این سفارش، این درصد از جمع فاکتور پرداخت‌شده حساب می‌شود.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
            gap(16),
            Section(title: 'توضیحات', child: TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات'))),
            gap(20),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('ذخیره سفارش')),
          ]),
        ),
      ),
    );
  }
}
