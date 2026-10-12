import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/pdf_docs.dart';
import '../print/report_builders.dart';
import '../util/format.dart';
import 'common.dart';
import 'parties_page.dart';
import 'print_dialog.dart';
import 'products_page.dart';
import 'transactions_page.dart';

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

class _InvoicesPageState extends State<InvoicesPage> {
  String q = '';
  String? kind;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    return RepoBuilder<(List<Invoice>, Map<String, String>)>(
      repo: repo,
      load: () async => (await repo.invoices(), {for (final p in await repo.parties()) p.id: p.name}),
      builder: (c, d) {
        final (all, names) = d;
        final list = all.where((i) {
          if (kind != null && i.kind != kind) return false;
          if (q.isEmpty) return true;
          return (names[i.partyId] ?? '').contains(q) || faDigits('${i.number}').contains(faDigits(q)) || '${i.number}' == q;
        }).toList();
        final unpaid = all.where((i) => i.kind == 'sale' && i.remaining > 0).fold<int>(0, (a, i) => a + i.remaining);
        final salesTotal = all.where((i) => i.kind == 'sale').fold<int>(0, (a, i) => a + i.total);
        return Scaffold(
          body: Constrained(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
              Row(children: [
                Expanded(child: StatCard(title: 'مجموع فروش', value: moneyC(salesTotal), icon: Icons.point_of_sale, color: Colors.green.shade700)),
                const SizedBox(width: 12),
                Expanded(child: StatCard(title: 'مطالبات فاکتورها', value: moneyC(unpaid), icon: Icons.hourglass_bottom, color: Colors.orange.shade800)),
              ]),
              const SizedBox(height: 12),
              SearchBox(onChanged: (v) => setState(() => q = v), hint: 'جستجوی نام شخص یا شمارهٔ فاکتور...'),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: PrintButton(
                  repo: repo,
                  label: 'چاپ فهرست',
                  doc: () => invoicesDoc(list, names,
                      filter: [if (kind != null) invoiceKind(kind!).label, if (q.isNotEmpty) 'جستجو: $q'].join(' • ')),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  ChoiceChip(label: const Text('همه'), selected: kind == null, onSelected: (_) => setState(() => kind = null)),
                  for (final k in invoiceKinds) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(label: Text(k.label), selected: kind == k.code, onSelected: (_) => setState(() => kind = k.code)),
                  ],
                ]),
              ),
              const SizedBox(height: 12),
              if (list.isEmpty)
                emptyState(all.isEmpty ? 'فاکتوری ثبت نشده است.' : 'فاکتوری پیدا نشد.')
              else
                Card(
                  child: Column(children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(),
                      _tile(c, list[i], names),
                    ],
                  ]),
                ),
            ]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => openInvoiceEditor(c, repo),
            icon: const Icon(Icons.add),
            label: const Text('فاکتور جدید'),
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext c, Invoice inv, Map<String, String> names) {
    final settled = inv.remaining <= 0;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(c).colorScheme.primaryContainer,
        foregroundColor: Theme.of(c).colorScheme.onPrimaryContainer,
        child: Text(faDigits('${inv.number}'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ),
      title: Text('${inv.info.label} • ${names[inv.partyId] ?? '؟'}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(jalaliText(inv.date)),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(money(inv.total), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        StatusChip(settled ? 'تسویه شده' : 'مانده ${money(inv.remaining)}', settled ? Colors.green.shade700 : Colors.orange.shade800),
      ]),
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceViewPage(repo: widget.repo, invoiceId: inv.id))),
    );
  }
}

void openInvoiceEditor(BuildContext c, Repo repo, {String? invoiceId}) =>
    Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceEditPage(repo: repo, invoiceId: invoiceId)));

class InvoiceViewPage extends StatelessWidget {
  const InvoiceViewPage({super.key, required this.repo, required this.invoiceId});
  final Repo repo;
  final String invoiceId;

  @override
  Widget build(BuildContext context) => RepoBuilder<(Invoice?, List<InvoiceItem>, Party?, List<Tx>)>(
        repo: repo,
        load: () async {
          final inv = (await repo.invoices()).where((i) => i.id == invoiceId).firstOrNull;
          if (inv == null) return (null, <InvoiceItem>[], null, <Tx>[]);
          final party = (await repo.parties()).where((p) => p.id == inv.partyId).firstOrNull;
          final txs = (await repo.transactions()).where((t) => t.invoiceId == inv.id).toList();
          return (inv, await repo.invoiceItems(inv.id), party, txs);
        },
        builder: (c, d) {
          final (inv, items, party, txs) = d;
          if (inv == null) return const Scaffold(body: Center(child: Text('این فاکتور حذف شد.')));
          final info = inv.info;
          Future<void> openPrint() => showPrintDialog(
                c,
                repo,
                title: '${info.label} ${faDigits('${inv.number}')}',
                filename: 'invoice-${inv.number}.pdf',
                build: (s, f) => PdfDocs(repo, settings: s).invoice(inv, items, party, format: f),
              );
          Future<void> printRoll() async {
            try {
              final bytes = await PdfDocs(repo).invoice(inv, items, party, roll: true);
              await PdfDocs.printRoll(bytes, '${info.label} ${inv.number}', repo.printSettings);
            } catch (e) {
              if (c.mounted) toast(c, 'چاپ ممکن نشد: $e');
            }
          }

          return Scaffold(
            appBar: AppBar(
              title: Text('${info.label} ${faDigits('${inv.number}')}'),
              actions: [
                PopupMenuButton<String>(
                  tooltip: 'چاپ و اشتراک‌گذاری',
                  icon: const Icon(Icons.print_outlined),
                  onSelected: (v) => v == 'roll' ? printRoll() : openPrint(),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'page', child: ListTile(leading: Icon(Icons.description_outlined), title: Text('چاپ فاکتور (A4 / A5) و PDF'))),
                    PopupMenuItem(value: 'roll', child: ListTile(leading: const Icon(Icons.receipt_outlined), title: Text('چاپ رسید حرارتی ${faDigits('${repo.printSettings.rollWidthMm}')} میلی‌متری'))),
                  ],
                ),
                IconButton(tooltip: 'ویرایش', icon: const Icon(Icons.edit_outlined), onPressed: () => openInvoiceEditor(c, repo, invoiceId: inv.id)),
                IconButton(
                  tooltip: 'حذف',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (!await confirm(c, 'این فاکتور حذف شود؟ پرداخت‌های آن حفظ می‌شود.')) return;
                    await repo.deleteInvoice(inv.id);
                    if (c.mounted) Navigator.pop(c);
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
                        Expanded(child: Text('${info.partyLabel}: ${party?.name ?? '؟'}', style: Theme.of(c).textTheme.titleMedium)),
                        StatusChip(inv.remaining <= 0 ? 'تسویه شده' : 'تسویه نشده', inv.remaining <= 0 ? Colors.green.shade700 : Colors.orange.shade800),
                      ]),
                      const SizedBox(height: 4),
                      Text('تاریخ: ${jalaliText(inv.date)}'),
                      if (inv.note.isNotEmpty) Text('توضیحات: ${inv.note}'),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(),
                      ListTile(
                        dense: true,
                        leading: Text(faDigits('${i + 1}')),
                        title: Text(items[i].title),
                        subtitle: Text('${qtyText(items[i].qty)} × ${money(items[i].unitPrice)}'),
                        trailing: Text(money(items[i].total), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      _row('جمع اقلام', inv.subtotal),
                      if (inv.discount > 0) _row('تخفیف', inv.discount),
                      if (inv.taxPercent > 0) _row('مالیات (${faDigits('${inv.taxPercent}')}٪)', inv.tax),
                      const Divider(height: 20),
                      _row('مبلغ نهایی', inv.total, bold: true),
                      _row(info.paymentKind == 'receipt' ? 'دریافت‌شده' : 'پرداخت‌شده', inv.paid),
                      _row('مانده', inv.remaining, bold: true),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  FilledButton.icon(
                    onPressed: () => editTx(c, repo,
                        partyId: inv.partyId, invoiceId: inv.id, kind: info.paymentKind,
                        amount: inv.remaining > 0 ? inv.remaining : null),
                    icon: const Icon(Icons.payments_outlined),
                    label: Text(info.paymentKind == 'receipt' ? 'ثبت دریافت' : 'ثبت پرداخت'),
                  ),
                  OutlinedButton.icon(onPressed: openPrint, icon: const Icon(Icons.print_outlined), label: const Text('چاپ فاکتور')),
                ]),
                if (txs.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('پرداخت‌های این فاکتور', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(children: [
                      for (final t in txs)
                        ListTile(
                          dense: true,
                          title: Text(moneyC(t.amount)),
                          subtitle: Text(jalaliText(t.date)),
                          onTap: () => editTx(c, repo, tx: t),
                        ),
                    ]),
                  ),
                ],
              ]),
            ),
          );
        },
      );

  Widget _row(String l, int v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Text(l, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
          const Spacer(),
          Text('${money(v)} $currencyLabel', style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
        ]),
      );
}

class _Line {
  _Line({String t = '', String q = '1', String p = '', this.productId})
      : title = TextEditingController(text: t),
        qty = TextEditingController(text: q),
        price = TextEditingController(text: p);
  final TextEditingController title, qty, price;
  final focus = FocusNode();
  String? productId;
  double get q => parseQty(qty.text);
  int get total => (q * parseAmount(price.text)).round();

  void dispose() {
    title.dispose();
    qty.dispose();
    price.dispose();
    focus.dispose();
  }
}

class InvoiceEditPage extends StatefulWidget {
  const InvoiceEditPage({super.key, required this.repo, this.invoiceId});
  final Repo repo;
  final String? invoiceId;
  @override
  State<InvoiceEditPage> createState() => _InvoiceEditPageState();
}

class _InvoiceEditPageState extends State<InvoiceEditPage> {
  final key = GlobalKey<FormState>();
  final lines = <_Line>[];
  final discount = TextEditingController();
  final tax = TextEditingController();
  final note = TextEditingController();
  final number = TextEditingController();
  String kind = 'sale';
  String date = todayIso();
  String? partyId;
  List<Party> parties = [];
  List<Product> products = [];
  Map<String, double> originalQty = {};
  String? originalKind;
  bool loaded = false;

  Repo get repo => widget.repo;
  InvoiceKind get info => invoiceKind(kind);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final l in lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    parties = await repo.parties();
    products = await repo.products();
    if (widget.invoiceId != null) {
      final inv = (await repo.invoices()).firstWhere((i) => i.id == widget.invoiceId);
      kind = inv.kind;
      originalKind = inv.kind;
      date = inv.date;
      partyId = inv.partyId;
      discount.text = inv.discount == 0 ? '' : '${inv.discount}';
      tax.text = '${inv.taxPercent}';
      note.text = inv.note;
      number.text = '${inv.number}';
      for (final it in await repo.invoiceItems(inv.id)) {
        if (it.productId != null) originalQty[it.productId!] = (originalQty[it.productId!] ?? 0) + it.qty;
        lines.add(_Line(t: it.title, q: it.qty == it.qty.roundToDouble() ? '${it.qty.round()}' : '${it.qty}', p: '${it.unitPrice}', productId: it.productId));
      }
    } else {
      number.text = '${await repo.nextInvoiceNumber()}';
      tax.text = repo.setting('default_tax', '0');
      lines.add(_Line());
    }
    if (mounted) setState(() => loaded = true);
  }

  int get subtotal => lines.fold(0, (a, l) => a + l.total);

  double _available(Product p) {
    // Stock already counts this invoice's saved quantities; add them back.
    var s = p.stock;
    final orig = originalQty[p.id];
    if (orig != null && originalKind != null) {
      final wasIn = invoiceKind(originalKind!).stockIn;
      s += wasIn ? -orig : orig;
    }
    return s;
  }

  void _pick(_Line l, Product p) {
    l.productId = p.id;
    l.title.text = p.name;
    final price = kind.startsWith('purchase') ? p.buyPrice : p.salePrice;
    if (price > 0) l.price.text = '$price';
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(widget.invoiceId == null ? 'فاکتور جدید' : 'ویرایش فاکتور')),
      body: Constrained(
        maxWidth: 860,
        child: Form(
          key: key,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Section(title: 'مشخصات فاکتور', child: Column(children: [
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'نوع فاکتور'),
                items: [for (final k in invoiceKinds) DropdownMenuItem(value: k.code, child: Text(k.label))],
                onChanged: (v) => setState(() => kind = v!),
              ),
              gap(),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: number,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'شماره'),
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
                    decoration: InputDecoration(labelText: info.partyLabel),
                    items: [for (final p in parties) DropdownMenuItem(value: p.id, child: Text(p.name))],
                    validator: (v) => v == null ? 'یک شخص انتخاب کنید' : null,
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
            ])),
            gap(16),
            Section(
              title: 'اقلام',
              child: Column(children: [
                if (products.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('برای انتخاب سریع، کالاها را در بخش «کالاها» تعریف کنید. نوشتن آزاد هم ممکن است.',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                for (var i = 0; i < lines.length; i++) _lineRow(i),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => setState(() => lines.add(_Line())),
                    icon: const Icon(Icons.add),
                    label: const Text('افزودن ردیف'),
                  ),
                ),
              ]),
            ),
            gap(16),
            Section(title: 'جمع و توضیحات', child: Column(children: [
              Row(children: [
                Expanded(child: AmountField(controller: discount, label: 'تخفیف')),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: tax,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'مالیات (درصد)'),
                  ),
                ),
              ]),
              gap(),
              TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات')),
              gap(16),
              ListenableBuilder(
                listenable: Listenable.merge([discount, tax, ...lines.expand((l) => [l.qty, l.price])]),
                builder: (_, _) {
                  final net = subtotal - parseAmount(discount.text);
                  final pct = parseAmount(tax.text).clamp(0, 100);
                  final t = (net * pct / 100).round();
                  Widget row(String l, int v, {bool bold = false}) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Text(l, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
                          const Spacer(),
                          Text(moneyC(v), style: TextStyle(fontWeight: bold ? FontWeight.w700 : null, fontSize: bold ? 17 : null)),
                        ]),
                      );
                  return Column(children: [
                    row('جمع اقلام', subtotal),
                    if (t > 0) row('مالیات', t),
                    const Divider(height: 16),
                    row('مبلغ نهایی', net + t, bold: true),
                  ]);
                },
              ),
            ])),
            gap(20),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('ذخیره فاکتور')),
          ]),
        ),
      ),
    );
  }

  Widget _lineRow(int i) {
    final l = lines[i];
    final prod = products.where((p) => p.id == l.productId).firstOrNull;
    final out = !info.stockIn;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => RawAutocomplete<Product>(
                textEditingController: l.title,
                focusNode: l.focus,
                displayStringForOption: (p) => p.name,
                optionsBuilder: (v) {
                  final t = v.text.trim();
                  if (products.isEmpty) return const Iterable<Product>.empty();
                  return products.where((p) => t.isEmpty || p.name.contains(t) || (p.code.isNotEmpty && p.code.contains(enDigits(t)))).take(8);
                },
                onSelected: (p) => _pick(l, p),
                fieldViewBuilder: (c, ctl, fn, _) => TextFormField(
                  controller: ctl,
                  focusNode: fn,
                  decoration: InputDecoration(
                    labelText: 'کالا / شرح',
                    suffixIcon: products.isEmpty ? null : const Icon(Icons.search),
                  ),
                  onChanged: (v) {
                    final p = products.where((p) => p.id == l.productId).firstOrNull;
                    if (p != null && p.name != v) setState(() => l.productId = null);
                  },
                  validator: (v) => (v ?? '').trim().isEmpty ? 'شرح؟' : null,
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
                            ListTile(
                              dense: true,
                              title: Text(p.name),
                              subtitle: Text('موجودی ${qtyText(p.stock)} ${p.unit} • ${money(kind.startsWith('purchase') ? p.buyPrice : p.salePrice)}'),
                              onTap: () => onSel(p),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'حذف ردیف',
            onPressed: lines.length == 1 ? null : () => setState(() => lines.removeAt(i).dispose()),
            icon: const Icon(Icons.close),
          ),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: l.qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: 'تعداد${prod != null ? ' (${prod.unit})' : ''}'),
              validator: (v) => l.q <= 0 ? 'نامعتبر' : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(flex: 3, child: AmountField(controller: l.price, label: 'قیمت واحد')),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: ListenableBuilder(
              listenable: Listenable.merge([l.qty, l.price]),
              builder: (_, _) => InputDecorator(
                decoration: const InputDecoration(labelText: 'مبلغ ردیف'),
                child: Text(money(l.total), style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ]),
        if (prod != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ListenableBuilder(
                listenable: l.qty,
                builder: (_, _) {
                  final over = out && l.q > _available(prod);
                  return Text(
                    over ? 'هشدار: موجودی ${qtyText(_available(prod))} ${prod.unit} است' : 'موجودی انبار: ${qtyText(_available(prod))} ${prod.unit}',
                    style: TextStyle(fontSize: 12, color: over ? Theme.of(context).colorScheme.error : Theme.of(context).hintColor),
                  );
                },
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> _save() async {
    if (!key.currentState!.validate()) return;
    await repo.saveInvoice(
      id: widget.invoiceId,
      number: parseAmount(number.text),
      kind: kind,
      date: date,
      partyId: partyId!,
      discount: parseAmount(discount.text),
      taxPercent: parseAmount(tax.text).clamp(0, 100),
      note: note.text.trim(),
      items: [
        for (final l in lines) InvoiceItem(l.title.text.trim(), l.q, parseAmount(l.price.text), productId: l.productId),
      ],
    );
    if (mounted) Navigator.pop(context);
  }
}
