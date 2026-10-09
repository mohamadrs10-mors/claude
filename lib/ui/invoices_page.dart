import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'transactions_page.dart';

class InvoicesPage extends StatelessWidget {
  const InvoicesPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<(List<Invoice>, Map<String, String>)>(
        repo: repo,
        load: () async => (await repo.invoices(), {for (final p in await repo.parties()) p.id: p.name}),
        builder: (c, d) {
          final (list, names) = d;
          return Scaffold(
            body: list.isEmpty
                ? emptyState('فاکتوری ثبت نشده است.')
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final inv = list[i];
                      final settled = inv.remaining <= 0;
                      return ListTile(
                        leading: CircleAvatar(child: Text(faDigits('${inv.number}'))),
                        title: Text('${inv.kind == 'sale' ? 'فروش به' : 'خرید از'} ${names[inv.partyId] ?? '؟'}'),
                        subtitle: Text('${jalaliText(inv.date)} • ${settled ? 'تسویه شده' : 'مانده ${money(inv.remaining)}'}'),
                        trailing: Text(money(inv.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceViewPage(repo: repo, invoiceId: inv.id))),
                      );
                    },
                  ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceEditPage(repo: repo))),
              icon: const Icon(Icons.add),
              label: const Text('فاکتور جدید'),
            ),
          );
        },
      );
}

class InvoiceViewPage extends StatelessWidget {
  const InvoiceViewPage({super.key, required this.repo, required this.invoiceId});
  final Repo repo;
  final String invoiceId;

  @override
  Widget build(BuildContext context) => RepoBuilder<(Invoice?, List<InvoiceItem>, String, List<Tx>)>(
        repo: repo,
        load: () async {
          final inv = (await repo.invoices()).where((i) => i.id == invoiceId).firstOrNull;
          if (inv == null) return (null, <InvoiceItem>[], '', <Tx>[]);
          final party = (await repo.parties()).where((p) => p.id == inv.partyId).firstOrNull;
          final txs = (await repo.transactions()).where((t) => t.invoiceId == inv.id).toList();
          return (inv, await repo.invoiceItems(inv.id), party?.name ?? '؟', txs);
        },
        builder: (c, d) {
          final (inv, items, party, txs) = d;
          if (inv == null) return const Scaffold(body: Center(child: Text('این فاکتور حذف شد.')));
          final isSale = inv.kind == 'sale';
          return Scaffold(
            appBar: AppBar(title: Text('فاکتور ${isSale ? 'فروش' : 'خرید'} ${faDigits('${inv.number}')}'), actions: [
              IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceEditPage(repo: repo, invoiceId: inv.id))),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  if (!await confirm(c, 'این فاکتور حذف شود؟ پرداخت‌های آن حفظ می‌شود.')) return;
                  await repo.deleteInvoice(inv.id);
                  if (c.mounted) Navigator.pop(c);
                },
              ),
            ]),
            body: ListView(padding: const EdgeInsets.all(16), children: [
              Text('${isSale ? 'مشتری' : 'تأمین‌کننده'}: $party'),
              Text('تاریخ: ${jalaliText(inv.date)}'),
              if (inv.note.isNotEmpty) Text('توضیحات: ${inv.note}'),
              const Divider(height: 32),
              for (final it in items)
                ListTile(
                  dense: true,
                  title: Text(it.title),
                  subtitle: Text('${faDigits(_q(it.qty))} × ${money(it.unitPrice)}'),
                  trailing: Text(money(it.total)),
                ),
              const Divider(),
              _row('جمع', inv.subtotal),
              if (inv.discount > 0) _row('تخفیف', -inv.discount),
              _row('مبلغ نهایی', inv.total, bold: true),
              _row(isSale ? 'دریافت‌شده' : 'پرداخت‌شده', inv.paid),
              _row('مانده', inv.remaining, bold: true),
              gap(),
              FilledButton.icon(
                onPressed: () => editTx(c, repo,
                    partyId: inv.partyId, invoiceId: inv.id, kind: isSale ? 'receipt' : 'payment',
                    amount: inv.remaining > 0 ? inv.remaining : null),
                icon: const Icon(Icons.payments_outlined),
                label: Text(isSale ? 'ثبت دریافت' : 'ثبت پرداخت'),
              ),
              for (final t in txs)
                ListTile(
                  dense: true,
                  title: Text('${money(t.amount)} تومان'),
                  subtitle: Text(jalaliText(t.date)),
                  onTap: () => editTx(c, repo, tx: t),
                ),
            ]),
          );
        },
      );

  static String _q(double q) => q == q.roundToDouble() ? '${q.round()}' : '$q';

  Widget _row(String l, int v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Text(l, style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
          const Spacer(),
          Text(money(v), style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
        ]),
      );
}

class _Line {
  _Line([String t = '', String q = '1', String p = ''])
      : title = TextEditingController(text: t),
        qty = TextEditingController(text: q),
        price = TextEditingController(text: p);
  final TextEditingController title, qty, price;
  double get q => double.tryParse(enDigits(qty.text).replaceAll('٫', '.')) ?? 0;
  int get total => (q * parseAmount(price.text)).round();
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
  final note = TextEditingController();
  final number = TextEditingController();
  String kind = 'sale';
  String date = todayIso();
  String? partyId;
  List<Party> parties = [];
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = widget.repo;
    parties = await repo.parties();
    if (widget.invoiceId != null) {
      final inv = (await repo.invoices()).firstWhere((i) => i.id == widget.invoiceId);
      kind = inv.kind;
      date = inv.date;
      partyId = inv.partyId;
      discount.text = inv.discount == 0 ? '' : '${inv.discount}';
      note.text = inv.note;
      number.text = '${inv.number}';
      for (final it in await repo.invoiceItems(inv.id)) {
        lines.add(_Line(it.title, it.qty == it.qty.roundToDouble() ? '${it.qty.round()}' : '${it.qty}', '${it.unitPrice}'));
      }
    } else {
      number.text = '${await repo.nextInvoiceNumber()}';
      lines.add(_Line());
    }
    if (mounted) setState(() => loaded = true);
  }

  int get subtotal => lines.fold(0, (a, l) => a + l.total);

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(widget.invoiceId == null ? 'فاکتور جدید' : 'ویرایش فاکتور')),
      body: Form(
        key: key,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'sale', label: Text('فروش')),
              ButtonSegment(value: 'purchase', label: Text('خرید')),
            ],
            selected: {kind},
            onSelectionChanged: (s) => setState(() => kind = s.first),
          ),
          gap(),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: number,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'شماره', border: OutlineInputBorder()),
                validator: (v) => parseAmount(v ?? '') <= 0 ? 'شماره نامعتبر' : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: JalaliDateField(iso: date, onChanged: (v) => setState(() => date = v))),
          ]),
          gap(),
          DropdownButtonFormField<String?>(
            initialValue: partyId,
            decoration: InputDecoration(labelText: kind == 'sale' ? 'مشتری' : 'تأمین‌کننده', border: const OutlineInputBorder()),
            items: [for (final p in parties) DropdownMenuItem(value: p.id, child: Text(p.name))],
            validator: (v) => v == null ? 'یک شخص انتخاب کنید (در بخش اشخاص بسازید)' : null,
            onChanged: (v) => partyId = v,
          ),
          gap(20),
          Text('اقلام', style: Theme.of(context).textTheme.titleMedium),
          for (var i = 0; i < lines.length; i++) _lineRow(i),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => lines.add(_Line())),
              icon: const Icon(Icons.add),
              label: const Text('افزودن ردیف'),
            ),
          ),
          gap(),
          AmountField(controller: discount, label: 'تخفیف (تومان)'),
          gap(),
          TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات', border: OutlineInputBorder())),
          gap(20),
          ListenableBuilder(
            listenable: Listenable.merge([discount, ...lines.expand((l) => [l.qty, l.price])]),
            builder: (_, _) {
              final total = subtotal - parseAmount(discount.text);
              return Text('مبلغ نهایی: ${money(total)} تومان', style: Theme.of(context).textTheme.titleLarge);
            },
          ),
          gap(20),
          FilledButton(onPressed: _save, child: const Text('ذخیره فاکتور')),
        ]),
      ),
    );
  }

  Widget _lineRow(int i) {
    final l = lines[i];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 4,
          child: TextFormField(
            controller: l.title,
            decoration: const InputDecoration(labelText: 'شرح', border: OutlineInputBorder()),
            validator: (v) => (v ?? '').trim().isEmpty ? 'شرح؟' : null,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 2,
          child: TextFormField(
            controller: l.qty,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'تعداد', border: OutlineInputBorder()),
            validator: (v) => l.q <= 0 ? 'نامعتبر' : null,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(flex: 3, child: AmountField(controller: l.price, label: 'قیمت واحد')),
        IconButton(
          onPressed: lines.length == 1 ? null : () => setState(() => lines.removeAt(i)),
          icon: const Icon(Icons.close),
        ),
      ]),
    );
  }

  Future<void> _save() async {
    if (!key.currentState!.validate()) return;
    await widget.repo.saveInvoice(
      id: widget.invoiceId,
      number: parseAmount(number.text),
      kind: kind,
      date: date,
      partyId: partyId!,
      discount: parseAmount(discount.text),
      note: note.text.trim(),
      items: [for (final l in lines) InvoiceItem(l.title.text.trim(), l.q, parseAmount(l.price.text))],
    );
    if (mounted) Navigator.pop(context);
  }
}
