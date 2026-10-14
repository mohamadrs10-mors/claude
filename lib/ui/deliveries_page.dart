import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/delivery_doc.dart';
import '../util/format.dart';
import 'common.dart';
import 'parties_page.dart';
import 'print_dialog.dart';
import 'products_page.dart';

/// Delivery receipts that are issued without an invoice.
class DeliveriesPage extends StatefulWidget {
  const DeliveriesPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<DeliveriesPage> createState() => _DeliveriesPageState();
}

class _DeliveriesPageState extends State<DeliveriesPage> {
  String q = '';

  Future<void> _print(BuildContext c, Delivery d, Map<String, Party> parties) async {
    final items = await widget.repo.deliveryItems(d.id);
    if (c.mounted) await printDelivery(c, widget.repo, DeliveryDoc.fromDelivery(d, items, parties[d.partyId]));
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    return RepoBuilder<(List<Delivery>, Map<String, Party>)>(
      repo: repo,
      load: () async => (await repo.deliveries(), {for (final p in await repo.parties()) p.id: p}),
      builder: (c, data) {
        final (all, parties) = data;
        String who(Delivery d) => d.recipient.isNotEmpty ? d.recipient : (parties[d.partyId]?.name ?? '—');
        final list = all.where((d) => q.isEmpty || who(d).contains(q) || '${d.number}' == enDigits(q)).toList();
        return Scaffold(
          body: Constrained(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
              Text(
                'رسید تحویل بدون فاکتور؛ برای کالایی که فقط می‌خواهید تحویل‌اش را ثبت و چاپ کنید. '
                'این رسید روی موجودی انبار و حساب اشخاص اثری ندارد. رسید تحویل هر فاکتور را از صفحهٔ خود فاکتور چاپ کنید.',
                style: Theme.of(c).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SearchBox(onChanged: (v) => setState(() => q = v), hint: 'جستجوی نام تحویل‌گیرنده یا شماره...'),
              const SizedBox(height: 12),
              if (list.isEmpty)
                emptyState(all.isEmpty ? 'رسید تحویلی ثبت نشده است.' : 'رسیدی پیدا نشد.')
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
                        title: Text(who(list[i]), style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(jalaliText(list[i].date)),
                        onTap: () => openDeliveryEditor(c, repo, id: list[i].id),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'چاپ', icon: const Icon(Icons.print_outlined), onPressed: () => _print(c, list[i], parties)),
                          IconButton(
                            tooltip: 'حذف',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              if (await confirm(c, 'این رسید تحویل حذف شود؟')) await repo.deleteDelivery(list[i].id);
                            },
                          ),
                        ]),
                      ),
                    ],
                  ]),
                ),
            ]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => openDeliveryEditor(c, repo),
            icon: const Icon(Icons.add),
            label: const Text('رسید تحویل جدید'),
          ),
        );
      },
    );
  }
}

Future<void> openDeliveryEditor(BuildContext c, Repo repo, {String? id}) =>
    Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => DeliveryEditPage(repo: repo, deliveryId: id)));

class _DLine {
  _DLine({String t = '', String q = '1', String u = '', this.productId})
      : title = TextEditingController(text: t),
        qty = TextEditingController(text: q),
        unit = TextEditingController(text: u);
  final TextEditingController title, qty, unit;
  final focus = FocusNode();
  String? productId;
  double get q => parseQty(qty.text);
  void dispose() {
    title.dispose();
    qty.dispose();
    unit.dispose();
    focus.dispose();
  }
}

class DeliveryEditPage extends StatefulWidget {
  const DeliveryEditPage({super.key, required this.repo, this.deliveryId});
  final Repo repo;
  final String? deliveryId;
  @override
  State<DeliveryEditPage> createState() => _DeliveryEditPageState();
}

class _DeliveryEditPageState extends State<DeliveryEditPage> {
  final key = GlobalKey<FormState>();
  final number = TextEditingController();
  final recipient = TextEditingController();
  final address = TextEditingController();
  final note = TextEditingController();
  final lines = <_DLine>[];
  List<Party> parties = [];
  List<Product> products = [];
  String date = todayIso();
  String? partyId;
  bool loaded = false;

  Repo get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [number, recipient, address, note]) {
      c.dispose();
    }
    for (final l in lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    parties = await repo.parties();
    products = await repo.products();
    if (widget.deliveryId != null) {
      final d = (await repo.deliveries()).firstWhere((x) => x.id == widget.deliveryId);
      date = d.date;
      partyId = d.partyId;
      number.text = '${d.number}';
      recipient.text = d.recipient;
      address.text = d.address;
      note.text = d.note;
      for (final it in await repo.deliveryItems(d.id)) {
        lines.add(_DLine(t: it.title, q: qtyText(it.qty), u: it.unit, productId: it.productId));
      }
    } else {
      number.text = '${await repo.nextDeliveryNumber()}';
    }
    if (lines.isEmpty) lines.add(_DLine());
    if (mounted) setState(() => loaded = true);
  }

  void _pick(_DLine l, Product p) {
    l.productId = p.id;
    l.title.text = p.name;
    l.unit.text = p.unit;
    setState(() {});
  }

  Future<void> _save() async {
    if (!key.currentState!.validate()) return;
    if (partyId == null && recipient.text.trim().isEmpty) {
      toast(context, 'تحویل‌گیرنده را انتخاب کنید یا نامش را بنویسید.');
      return;
    }
    await repo.saveDelivery(
      id: widget.deliveryId,
      number: parseAmount(number.text),
      date: date,
      partyId: partyId,
      recipient: recipient.text.trim(),
      address: address.text.trim(),
      note: note.text.trim(),
      items: [for (final l in lines) DeliveryItem(l.title.text.trim(), l.q, unit: l.unit.text.trim(), productId: l.productId)],
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(widget.deliveryId == null ? 'رسید تحویل جدید' : 'ویرایش رسید تحویل')),
      body: Constrained(
        maxWidth: 860,
        child: Form(
          key: key,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
            Section(
              title: 'مشخصات رسید',
              child: Column(children: [
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
                      decoration: const InputDecoration(labelText: 'تحویل‌گیرنده (از اشخاص، اختیاری)'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('— بدون شخص —')),
                        for (final p in parties) DropdownMenuItem(value: p.id, child: Text(p.name)),
                      ],
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
                TextFormField(controller: recipient, decoration: const InputDecoration(labelText: 'یا نام تحویل‌گیرنده (متن آزاد)')),
                gap(),
                TextFormField(controller: address, decoration: const InputDecoration(labelText: 'نشانی تحویل (اختیاری)')),
              ]),
            ),
            gap(16),
            Section(
              title: 'اقلام تحویلی',
              child: Column(children: [
                for (var i = 0; i < lines.length; i++) _lineRow(i),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => setState(() => lines.add(_DLine())),
                    icon: const Icon(Icons.add),
                    label: const Text('افزودن ردیف'),
                  ),
                ),
              ]),
            ),
            gap(16),
            Section(title: 'توضیحات', child: TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات'))),
            gap(20),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('ذخیره رسید')),
          ]),
        ),
      ),
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
                  decoration: InputDecoration(labelText: 'کالا / شرح', suffixIcon: products.isEmpty ? null : const Icon(Icons.search)),
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
                            ListTile(dense: true, title: Text(p.name), subtitle: Text('موجودی ${qtyText(p.stock)} ${p.unit}'), onTap: () => onSel(p)),
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
            child: TextFormField(
              controller: l.qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'تعداد'),
              validator: (v) => l.q <= 0 ? 'نامعتبر' : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: TextFormField(controller: l.unit, decoration: const InputDecoration(labelText: 'واحد (عدد، کیلو، ...)'))),
        ]),
      ]),
    );
  }
}
