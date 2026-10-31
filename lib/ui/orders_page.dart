import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/order_docs.dart';
import '../util/format.dart';
import 'auth.dart';
import 'common.dart';
import 'invoices_page.dart';
import 'parties_page.dart';
import 'cheques_page.dart';
import 'print_dialog.dart';
import 'products_page.dart';

/// Orders with an advance payment: the customer orders a quantity of a
/// product and pays part of it up front; every sale invoice made for the
/// order counts that percent as already paid.
class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  String filter = 'all'; // all | open | draft | closed

  Repo get repo => widget.repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<(List<Order>, Map<String, String>)>(
        repo: repo,
        load: () async => (await repo.orders(), {for (final p in await repo.parties()) p.id: p.name}),
        builder: (c, d) {
          final (all, names) = d;
          final held = all.fold<int>(0, (a, o) => a + o.available);
          final list = [
            for (final o in all)
              if (switch (filter) { 'open' => o.open, 'draft' => o.isDraft, 'closed' => o.status == 'closed', _ => true }) o
          ];
          final today = todayIso();
          final canEdit = AccessScope.of(context).canEdit('orders');
          return Scaffold(
            body: Constrained(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
                StatCard(title: 'پیش‌دریافت‌های هنوز کسرنشده', value: moneyC(held), icon: Icons.savings_outlined, color: Colors.orange.shade800),
                const SizedBox(height: 8),
                Text(
                  'مشتری سفارش یک کالا را می‌دهد و بخشی از مبلغ را پیش‌پرداخت می‌کند. این پول به حساب شما می‌رود ولی مشتری بستانکار نمی‌شود. '
                  'روی هر فاکتور فروشی که برای این سفارش بزنید، همان درصد پیش‌دریافت از جمع فاکتور پرداخت‌شده حساب می‌شود و مشتری فقط بدهکار مانده است. '
                  'قبل از سفارش قطعی، «پیش‌نویس سفارش» بزنید و برای مشتری چاپ کنید؛ بعداً با یک کلیک به سفارش تبدیل می‌شود.',
                  style: Theme.of(c).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, children: [
                  for (final (id, t) in const [('all', 'همه'), ('open', 'باز'), ('draft', 'پیش‌نویس'), ('closed', 'بسته‌شده')])
                    ChoiceChip(label: Text(t), selected: filter == id, onSelected: (_) => setState(() => filter = id)),
                ]),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  emptyState(filter == 'draft' ? 'پیش‌نویسی ثبت نشده است.' : 'سفارشی ثبت نشده است.')
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
                          subtitle: Text(
                            list[i].isDraft
                                ? '${faDigits('${list[i].items.length}')} قلم • پیش‌دریافت پیشنهادی ${moneyC(list[i].planned)} (${faDigits(qtyText(list[i].percent))}٪)${list[i].deliveryDate.isEmpty ? '' : ' • تحویل ${faDigits(jalaliText(list[i].deliveryDate))}'}'
                                : '${faDigits('${list[i].items.length}')} قلم • پیش‌دریافت ${faDigits(qtyText(list[i].percent))}٪ • فاکتورشده ${faDigits('${(list[i].progress * 100).round()}')}٪${list[i].deliveryDate.isEmpty ? '' : ' • تحویل ${faDigits(jalaliText(list[i].deliveryDate))}'}',
                          ),
                          trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(list[i].total), style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            list[i].isDraft
                                ? StatusChip('پیش‌نویس', Colors.orange.shade800)
                                : (list[i].lateAt(today) ? StatusChip('تحویل گذشته', Colors.red.shade700) : StatusChip(list[i].open ? 'باز' : 'بسته‌شده', list[i].open ? Colors.green.shade700 : Colors.blueGrey)),
                          ]),
                          onTap: () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => OrderViewPage(repo: repo, orderId: list[i].id))),
                        ),
                      ],
                    ]),
                  ),
              ]),
            ),
            floatingActionButton: !canEdit
                ? null
                : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    FloatingActionButton.extended(
                      heroTag: 'draft',
                      onPressed: () => openOrderEditor(c, repo, draft: true),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('پیش‌نویس سفارش'),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton.extended(
                      heroTag: 'order',
                      onPressed: () => openOrderEditor(c, repo),
                      icon: const Icon(Icons.add),
                      label: const Text('سفارش جدید'),
                    ),
                  ]),
          );
        },
      );
}

Future<void> openOrderEditor(BuildContext c, Repo repo, {String? id, bool draft = false, bool convert = false}) =>
    Navigator.push(c, MaterialPageRoute<void>(builder: (_) => OrderEditPage(repo: repo, orderId: id, draft: draft, convert: convert)));

class OrderViewPage extends StatelessWidget {
  const OrderViewPage({super.key, required this.repo, required this.orderId});
  final Repo repo;
  final String orderId;

  @override
  Widget build(BuildContext context) => RepoBuilder<(Order?, Party?, List<Invoice>, Map<String, String>, List<Cheque>)>(
        repo: repo,
        load: () async {
          final o = (await repo.orders()).where((x) => x.id == orderId).firstOrNull;
          if (o == null) return (null, null, <Invoice>[], <String, String>{}, <Cheque>[]);
          final party = (await repo.parties()).where((p) => p.id == o.partyId).firstOrNull;
          final units = {for (final p in await repo.products()) p.id: p.unit};
          return (o, party, (await repo.invoices()).where((i) => i.orderId == o.id).toList(), units,
              (await repo.cheques()).where((x) => x.orderId == o.id).toList());
        },
        builder: (c, d) {
          final (o, party, invoices, units, cheques) = d;
          if (o == null) return const Scaffold(body: Center(child: Text('این سفارش حذف شد.')));
          final canEdit = AccessScope.of(c).canEdit('orders');
          final draft = o.isDraft;
          Future<void> printIt() => printReport(c, repo, orderDoc(o, party, cheques, units));
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
              title: Text('${draft ? 'پیش‌نویس سفارش' : 'سفارش'} ${faDigits('${o.number}')}'),
              actions: [
                IconButton(tooltip: 'چاپ', icon: const Icon(Icons.print_outlined), onPressed: printIt),
                if (canEdit) IconButton(tooltip: 'ویرایش', icon: const Icon(Icons.edit_outlined), onPressed: () => openOrderEditor(c, repo, id: o.id, draft: draft)),
                if (canEdit) IconButton(
                  tooltip: 'حذف',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (!await confirm(c, draft ? 'این پیش‌نویس حذف شود؟' : 'این سفارش و دریافت پیش‌دریافتش حذف شود؟')) return;
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
                        draft ? StatusChip('پیش‌نویس', Colors.orange.shade800) : StatusChip(o.open ? 'باز' : 'بسته‌شده', o.open ? Colors.green.shade700 : Colors.blueGrey),
                      ]),
                      Text('تاریخ: ${jalaliText(o.date)}'),
                      if (o.deliveryDate.isNotEmpty)
                        Row(children: [
                          Text('تاریخ تحویل: ${faDigits(jalaliText(o.deliveryDate))}'),
                          if (o.lateAt(todayIso())) ...[const SizedBox(width: 8), StatusChip('تحویل گذشته', Colors.red.shade700)],
                        ]),
                      if (o.note.isNotEmpty) Text('توضیحات: ${o.note}'),
                      const Divider(height: 24),
                      Text('کالاهای سفارش', style: Theme.of(c).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      for (final it in o.items) ...[
                        Row(children: [
                          Expanded(child: Text(it.title, style: const TextStyle(fontWeight: FontWeight.w600))),
                          Text(money(it.total)),
                        ]),
                        Text(
                          draft
                              ? '${qtyText(it.qty)} ${units[it.productId] ?? ''} × ${money(it.unitPrice)}'
                              : '${qtyText(it.qty)} ${units[it.productId] ?? ''} × ${money(it.unitPrice)}  •  فاکتورشده ${qtyText(it.invoicedQty)} از ${qtyText(it.qty)}',
                          style: Theme.of(c).textTheme.bodySmall,
                        ),
                        if (!draft) ...[
                          const SizedBox(height: 4),
                          LinearProgressIndicator(value: it.qty <= 0 ? 0 : (it.invoicedQty / it.qty).clamp(0, 1).toDouble()),
                        ],
                        const SizedBox(height: 10),
                      ],
                      const Divider(height: 16),
                      row('جمع سفارش', moneyC(o.total), bold: true),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: draft
                        ? [
                            row('درصد پیش‌دریافت', '${faDigits(qtyText(o.percent))}٪'),
                            row('پیش‌دریافت پیشنهادی', moneyC(o.planned), bold: true),
                            row('مانده بعد از پیش‌دریافت', moneyC((o.total - o.planned).clamp(0, o.total)), bold: true),
                            const SizedBox(height: 6),
                            Text('هنوز پولی دریافت و ثبت نشده است؛ با «تبدیل به سفارش» پیش‌دریافت واقعی (نقد و چک) ثبت می‌شود.', style: Theme.of(c).textTheme.bodySmall),
                          ]
                        : [
                      row('درصد پیش‌دریافت', '${faDigits(qtyText(o.percent))}٪'),
                      row('پیش‌دریافت دریافت‌شده', moneyC(o.advance), bold: true),
                      if (o.chequeAmount > 0) ...[
                        row('  • نقدی', moneyC(o.cash)),
                        row('  • چکی (برگشتی حساب نمی‌شود)', moneyC(o.chequeAmount)),
                      ],
                      row('کسرشده روی فاکتورها', moneyC(o.applied)),
                      if (o.released > 0) row('تبدیل‌شده به اعتبار مشتری', moneyC(o.released)),
                      row('باقی‌ماندهٔ قابل کسر', moneyC(o.available), bold: true),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  if (draft && canEdit)
                    FilledButton.icon(
                      onPressed: () => openOrderEditor(c, repo, id: o.id, convert: true),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('تبدیل به سفارش'),
                    ),
                  OutlinedButton.icon(onPressed: printIt, icon: const Icon(Icons.print_outlined), label: Text(draft ? 'چاپ برای مشتری' : 'چاپ سفارش')),
                  if (o.open)
                    FilledButton.icon(
                      onPressed: () => openInvoiceEditor(c, repo, partyId: o.partyId, orderId: o.id),
                      icon: const Icon(Icons.receipt_long_outlined),
                      label: const Text('صدور فاکتور برای این سفارش'),
                    ),
                  if (o.open)
                    OutlinedButton.icon(
                      onPressed: () => editCheque(c, repo, kind: 'received', partyId: o.partyId, orderId: o.id),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('ثبت چک پیش‌دریافت'),
                    ),
                  if (!draft)
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
                if (!draft && cheques.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('چک‌های پیش‌دریافت', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(children: [
                      for (final x in cheques)
                        ListTile(
                          dense: true,
                          title: Text(moneyC(x.amount)),
                          subtitle: Text('سررسید ${jalaliText(x.dueDate)}${x.number.isEmpty ? '' : ' • شمارهٔ ${faDigits(x.number)}'}${x.bank.isEmpty ? '' : ' • ${x.bank}'}'),
                          trailing: StatusChip(
                            switch (x.status) { 'cleared' => 'وصول شده', 'bounced' => 'برگشتی', _ => 'در انتظار' },
                            switch (x.status) { 'cleared' => Colors.green.shade700, 'bounced' => Theme.of(c).colorScheme.error, _ => Colors.orange.shade800 },
                          ),
                          onTap: () => editCheque(c, repo, cheque: x),
                        ),
                    ]),
                  ),
                ],
                if (!draft) ...[
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
                ],
              ]),
            ),
          );
        },
      );
}

class OrderEditPage extends StatefulWidget {
  const OrderEditPage({super.key, required this.repo, this.orderId, this.draft = false, this.convert = false});
  final Repo repo;
  final String? orderId;

  /// A draft (quotation): nothing is booked, the advance is only planned.
  final bool draft;

  /// Turns the draft [orderId] into a real order (advance, account and cheques are asked).
  final bool convert;
  @override
  State<OrderEditPage> createState() => _OrderEditPageState();
}


/// One product row of the order form.
class _OLine {
  _OLine({String t = '', String q = '1', String p = '', this.productId})
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

/// A cheque entered together with a new order.
class _CRow {
  final amount = TextEditingController();
  final number = TextEditingController();
  final bank = TextEditingController();
  String due = todayIso();
  void dispose() {
    amount.dispose();
    number.dispose();
    bank.dispose();
  }
}

class _OrderEditPageState extends State<OrderEditPage> {
  final key = GlobalKey<FormState>();
  final number = TextEditingController();
  final percent = TextEditingController(text: '50');
  final advance = TextEditingController();
  final note = TextEditingController();
  final lines = <_OLine>[];
  final chequeRows = <_CRow>[];
  int _existingCheques = 0; // cheques of the order being edited
  List<Party> parties = [];
  List<Product> products = [];
  List<Account> accounts = [];
  String date = todayIso();
  String deliveryDate = '';
  String? partyId, accountId;
  bool loaded = false;

  /// Saving as a draft, or as an order (also when a draft is being converted).
  bool get isDraft => widget.draft && !widget.convert;

  /// An existing order whose advance/cheques are managed from its own page.
  bool get editingOrder => widget.orderId != null && !widget.convert && !widget.draft;
  // What the user changed last decides what follows: after typing the percent the
  // cash amount follows it; after typing the amount (or a cheque) the percent
  // follows the money received (cash + cheques) as a share of the order total.
  String? _driver; // 'percent' | 'amount' | null (leave as loaded)
  bool _busy = false;

  Repo get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    percent.addListener(() {
      if (!_busy) _driver = 'percent';
      _syncAdvance();
    });
    advance.addListener(() {
      if (!_busy) _driver = 'amount';
      _syncAdvance();
    });
    _load();
  }

  @override
  void dispose() {
    for (final c in [number, percent, advance, note]) {
      c.dispose();
    }
    for (final l in lines) {
      _drop(l);
    }
    for (final r in chequeRows) {
      r.amount.removeListener(_syncAdvance);
      r.dispose();
    }
    super.dispose();
  }

  _OLine _newLine({String t = '', String q = '1', String p = '', String? productId}) {
    final l = _OLine(t: t, q: q, p: p, productId: productId);
    l.qty.addListener(_syncAdvance);
    l.price.addListener(_syncAdvance);
    return l;
  }

  void _drop(_OLine l) {
    l.qty.removeListener(_syncAdvance);
    l.price.removeListener(_syncAdvance);
    l.dispose();
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
      percent.text = qtyText(o.percent);
      _driver = null; // as saved, until the percent or the amounts are changed
      accountId = o.accountId ?? accounts.firstOrNull?.id;
      note.text = o.note;
      deliveryDate = o.deliveryDate;
      // A draft carries the planned advance; turning it into an order starts from it.
      advance.text = money(o.isDraft ? o.planned : o.cash);
      _existingCheques = o.chequeAmount;
      for (final it in o.items) {
        lines.add(_newLine(t: it.title, q: qtyText(it.qty), p: money(it.unitPrice), productId: it.productId));
      }
    } else {
      number.text = '${await repo.nextOrderNumber()}';
      accountId = accounts.firstOrNull?.id;
      _driver = 'percent';
    }
    if (lines.isEmpty) lines.add(_newLine());
    if (mounted) setState(() => loaded = true);
  }

  double get _pct => parseQty(percent.text).clamp(0, 100).toDouble();
  int get _total => lines.fold(0, (a, l) => a + l.total);
  int get _chequeSum => chequeRows.fold(0, (a, r) => a + parseAmount(r.amount.text)) + _existingCheques;

  /// Keeps percent and money consistent: either the cash amount follows the
  /// percent (total x percent minus the cheques) or the percent follows what
  /// was received (cash + cheques) / order total.
  void _syncAdvance() {
    if (_busy || !loaded || _driver == null) return;
    _busy = true;
    try {
      if (_driver == 'percent') {
        final want = (_total * _pct / 100).round() - _chequeSum;
        final v = want < 0 ? 0 : want;
        advance.text = v == 0 ? '' : money(v);
      } else if (_total > 0) {
        final got = parseAmount(advance.text) + _chequeSum;
        final pct = (got * 100 / _total).clamp(0, 100).toDouble();
        percent.text = got == 0 ? '' : plainNum(double.parse(pct.toStringAsFixed(2)), decimals: 2);
      }
    } finally {
      _busy = false;
    }
  }

  void _pick(_OLine l, Product p) {
    l.productId = p.id;
    l.title.text = p.name;
    if (p.salePrice > 0) l.price.text = money(p.salePrice);
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
        items: [for (final l in lines) OrderItem(l.title.text.trim(), l.q, parseAmount(l.price.text), productId: l.productId)],
        percent: _pct,
        advance: parseAmount(advance.text),
        accountId: accountId,
        note: note.text.trim(),
        deliveryDate: deliveryDate,
        draft: isDraft,
        cheques: [
          for (final r in chequeRows)
            ChequeDraft(amount: parseAmount(r.amount.text), dueDate: r.due, number: enDigits(r.number.text.trim()), bank: r.bank.text.trim()),
        ],
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
      appBar: AppBar(title: Text(widget.convert ? 'تبدیل پیش‌نویس به سفارش' : (isDraft ? (widget.orderId == null ? 'پیش‌نویس سفارش' : 'ویرایش پیش‌نویس') : (widget.orderId == null ? 'سفارش جدید' : 'ویرایش سفارش')))),
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
                gap(),
                Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.local_shipping_outlined),
                    label: Text(deliveryDate.isEmpty ? 'تاریخ تحویل (اختیاری)' : 'تحویل: ${faDigits(jalaliText(deliveryDate))}'),
                    onPressed: () async {
                      final r = await showDialog<String>(context: context, builder: (_) => JalaliPickerDialog(deliveryDate.isEmpty ? date : deliveryDate));
                      if (r != null) setState(() => deliveryDate = r);
                    },
                  ),
                  for (final d in const [7, 15, 30, 60])
                    ActionChip(label: Text('${faDigits('$d')} روز بعد'), onPressed: () => setState(() => deliveryDate = isoOf(DateTime.parse(date).add(Duration(days: d))))),
                  if (deliveryDate.isNotEmpty) IconButton(tooltip: 'حذف تاریخ تحویل', icon: const Icon(Icons.close), onPressed: () => setState(() => deliveryDate = '')),
                ]),
              ]),
            ),
            gap(16),
            Section(
              title: 'کالاهای سفارش‌داده‌شده',
              child: Column(children: [
                for (var i = 0; i < lines.length; i++) _lineRow(i),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => setState(() => lines.add(_newLine())),
                    icon: const Icon(Icons.add),
                    label: const Text('افزودن کالا'),
                  ),
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([for (final l in lines) ...[l.qty, l.price]]),
                  builder: (_, _) => Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('جمع سفارش: ${moneyC(_total)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
            gap(16),
            Section(
              title: isDraft ? 'پیش‌دریافت پیشنهادی' : 'پیش‌دریافت',
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
                    child: AmountField(
                      controller: advance,
                      label: isDraft ? 'مبلغ پیش‌دریافت پیشنهادی' : 'مبلغ نقدی دریافت‌شده',
                      helper: 'درصد را بنویسید تا مبلغ حساب شود، یا مبلغ را بنویسید تا درصد از روی دریافتی‌ها (نقد + چک) حساب شود',
                    ),
                  ),
                ]),
                ListenableBuilder(
                  listenable: Listenable.merge([percent, advance, for (final l in lines) ...[l.qty, l.price], for (final r in chequeRows) r.amount]),
                  builder: (c, _) {
                    final got = parseAmount(advance.text) + _chequeSum;
                    final over = _total > 0 && got > _total;
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'جمع دریافتی (نقد + چک): ${moneyC(got)}${_total > 0 ? ' = ${faDigits(plainNum(double.parse((got * 100 / _total).toStringAsFixed(2)), decimals: 2))}٪ از جمع سفارش (${moneyC(_total)})' : ''}'
                        '${over ? '\nهشدار: دریافتی از جمع سفارش بیشتر است.' : ''}',
                        style: TextStyle(fontWeight: FontWeight.w600, color: over ? Theme.of(c).colorScheme.error : null),
                      ),
                    );
                  },
                ),
                if (!isDraft) ...[
                gap(),
                DropdownButtonFormField<String?>(
                  key: ValueKey('acc${accounts.length}'),
                  initialValue: accountId,
                  decoration: const InputDecoration(labelText: 'واریز به حساب'),
                  items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                  validator: (v) => parseAmount(advance.text) > 0 && v == null ? 'حساب را انتخاب کنید' : null,
                  onChanged: (v) => accountId = v,
                ),
                ],
                gap(),
                Text(
                  isDraft
                      ? 'پیش‌نویس هیچ پولی ثبت نمی‌کند و روی حساب‌ها، فاکتورها و تراز مشتری اثری ندارد؛ فقط برای چاپ و نشان دادن به مشتری است. وقتی مشتری تأیید کرد، «تبدیل به سفارش» را بزنید.'
                      : 'این مبلغ به حساب انتخاب‌شده اضافه می‌شود ولی مشتری بستانکار نمی‌شود. روی هر فاکتور فروش این سفارش، این درصد از بخشی از فاکتور که کالای همین سفارش است پرداخت‌شده حساب می‌شود (کالاهای دیگر فاکتور کسر ندارند).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ]),
            ),
            if (!isDraft) ...[
            gap(16),
            Section(
              title: 'چک‌های پیش‌دریافت (اختیاری)',
              child: editingOrder
                  ? Text(
                      _existingCheques > 0
                          ? 'چک‌های این سفارش (${moneyC(_existingCheques)}) را از صفحهٔ خود سفارش ببینید یا ویرایش کنید؛ چک تازه هم از همان‌جا ثبت می‌شود.'
                          : 'چک پیش‌دریافت را از صفحهٔ خود سفارش («ثبت چک پیش‌دریافت») اضافه کنید.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        'اگر بخشی از پیش‌دریافت یا همهٔ آن را چک گرفته‌اید، اینجا بنویسید. چک هم مثل نقد از همان لحظه روی فاکتورهای این سفارش کسر می‌شود (اگر برگشت بخورد کسر برگردانده می‌شود) و با وصول، پولش به حساب می‌نشیند.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      gap(),
                      for (var i = 0; i < chequeRows.length; i++) _chequeRow(i),
                      TextButton.icon(
                        onPressed: () => setState(() {
                          final r = _CRow();
                          r.amount.addListener(_syncAdvance);
                          chequeRows.add(r);
                        }),
                        icon: const Icon(Icons.add),
                        label: const Text('افزودن چک'),
                      ),
                    ]),
            ),
            ],
            gap(16),
            Section(title: 'توضیحات', child: TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات'))),
            gap(20),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: Text(isDraft ? 'ذخیره پیش‌نویس' : (widget.convert ? 'تبدیل به سفارش و ثبت پیش‌دریافت' : 'ذخیره سفارش'))),
          ]),
        ),
      ),
    );
  }

  Widget _chequeRow(int i) {
    final r = chequeRows[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: AmountField(controller: r.amount, label: 'مبلغ چک', validator: (v) => parseAmount(v ?? '') <= 0 ? 'مبلغ؟' : null)),
          const SizedBox(width: 10),
          Expanded(child: JalaliDateField(iso: r.due, label: 'تاریخ سررسید', onChanged: (v) => setState(() => r.due = v))),
          IconButton(
            tooltip: 'حذف چک',
            onPressed: () => setState(() {
              final x = chequeRows.removeAt(i);
              x.amount.removeListener(_syncAdvance);
              x.dispose();
              _syncAdvance();
            }),
            icon: const Icon(Icons.close),
          ),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextFormField(controller: r.number, decoration: const InputDecoration(labelText: 'شمارهٔ چک'))),
          const SizedBox(width: 10),
          Expanded(child: TextFormField(controller: r.bank, decoration: const InputDecoration(labelText: 'بانک'))),
        ]),
      ]),
    );
  }

  Widget _lineRow(int i) {
    final l = lines[i];
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
                  decoration: InputDecoration(labelText: 'کالا', suffixIcon: products.isEmpty ? null : const Icon(Icons.search)),
                  onChanged: (v) {
                    final p = products.where((p) => p.id == l.productId).firstOrNull;
                    if (p != null && p.name != v) l.productId = null;
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
          ),
          IconButton(
            tooltip: 'حذف کالا',
            onPressed: lines.length == 1
                ? null
                : () => setState(() {
                      _drop(lines.removeAt(i));
                      _syncAdvance();
                    }),
            icon: const Icon(Icons.close),
          ),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextFormField(
              controller: l.qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'تعداد سفارش'),
              validator: (v) => l.q <= 0 ? 'نامعتبر' : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: AmountField(controller: l.price, label: 'قیمت واحد')),
        ]),
      ]),
    );
  }
}
