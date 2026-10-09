import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import '../print/pdf_docs.dart';
import 'invoices_page.dart';
import 'transactions_page.dart';

class PartiesPage extends StatefulWidget {
  const PartiesPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<PartiesPage> createState() => _PartiesPageState();
}

class _PartiesPageState extends State<PartiesPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    return RepoBuilder<List<Party>>(
      repo: repo,
      load: repo.parties,
      builder: (c, all) {
        final list = all.where((p) => q.isEmpty || p.name.contains(q) || p.phone.contains(enDigits(q))).toList();
        return Scaffold(
          body: Constrained(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
              Row(children: [
                Expanded(child: StatCard(title: 'طلب شما', value: moneyC(all.where((p) => p.balance > 0).fold<int>(0, (a, p) => a + p.balance)), icon: Icons.trending_up, color: Colors.green.shade700)),
                const SizedBox(width: 12),
                Expanded(child: StatCard(title: 'بدهی شما', value: moneyC(all.where((p) => p.balance < 0).fold<int>(0, (a, p) => a - p.balance)), icon: Icons.trending_down, color: Theme.of(c).colorScheme.error)),
              ]),
              const SizedBox(height: 12),
              SearchBox(onChanged: (v) => setState(() => q = v), hint: 'جستجوی نام یا تلفن...'),
              const SizedBox(height: 12),
              if (list.isEmpty)
                emptyState(all.isEmpty ? 'هنوز شخصی ثبت نشده است.' : 'شخصی پیدا نشد.')
              else
                Card(
                  child: Column(children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(),
                      Builder(builder: (c) {
                        final p = list[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Theme.of(c).colorScheme.primaryContainer,
                            foregroundColor: Theme.of(c).colorScheme.onPrimaryContainer,
                            child: Text(p.name.characters.first),
                          ),
                          title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(p.balance == 0 ? 'تسویه' : (p.balance > 0 ? 'بدهکار به شما' : 'بستانکار از شما')),
                          trailing: Text(money(p.balance.abs()),
                              style: TextStyle(fontWeight: FontWeight.w700, color: amountColor(c, p.balance))),
                          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => PartyDetailPage(repo: repo, party: p))),
                        );
                      }),
                    ],
                  ]),
                ),
            ]),
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => editParty(c, repo),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('شخص جدید'),
          ),
        );
      },
    );
  }
}

Future<void> editParty(BuildContext c, Repo repo, [Party? p]) async {
  final name = TextEditingController(text: p?.name);
  final phone = TextEditingController(text: p?.phone);
  final note = TextEditingController(text: p?.note);
  final key = GlobalKey<FormState>();
  await showDialog(
    context: c,
    builder: (dc) => AlertDialog(
      title: Text(p == null ? 'شخص جدید' : 'ویرایش شخص'),
      content: Form(
        key: key,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(
            controller: name,
            decoration: const InputDecoration(labelText: 'نام', border: OutlineInputBorder()),
            validator: (v) => (v ?? '').trim().isEmpty ? 'نام را وارد کنید' : null,
          ),
          gap(),
          TextFormField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'تلفن', border: OutlineInputBorder()),
          ),
          gap(),
          TextFormField(
            controller: note,
            decoration: const InputDecoration(labelText: 'یادداشت', border: OutlineInputBorder()),
          ),
        ]),
      ),
      actions: [
        if (p != null)
          TextButton(
            onPressed: () async {
              if (!await confirm(dc, 'این شخص حذف شود؟')) return;
              final err = await repo.deleteParty(p.id);
              if (!dc.mounted) return;
              if (err != null) {
                toast(dc, err);
              } else {
                Navigator.pop(dc);
                if (c.mounted) Navigator.popUntil(c, (r) => r.isFirst);
              }
            },
            child: const Text('حذف'),
          ),
        TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
        FilledButton(
          onPressed: () async {
            if (!key.currentState!.validate()) return;
            await repo.saveParty(id: p?.id, name: name.text.trim(), phone: phone.text.trim(), note: note.text.trim());
            if (dc.mounted) Navigator.pop(dc);
          },
          child: const Text('ذخیره'),
        ),
      ],
    ),
  );
}

class PartyDetailPage extends StatelessWidget {
  const PartyDetailPage({super.key, required this.repo, required this.party});
  final Repo repo;
  final Party party;

  @override
  Widget build(BuildContext context) => RepoBuilder<(Party?, List<Tx>, List<Invoice>)>(
        repo: repo,
        load: () async {
          final p = (await repo.parties()).where((x) => x.id == party.id).firstOrNull;
          return (p, await repo.transactions(partyId: party.id), await repo.invoices(partyId: party.id));
        },
        builder: (c, d) {
          final (p, txs, invs) = d;
          if (p == null) return const Scaffold(body: Center(child: Text('این شخص حذف شد.')));
          return Scaffold(
            appBar: AppBar(title: Text(p.name), actions: [
              IconButton(
                tooltip: 'چاپ صورت‌حساب',
                icon: const Icon(Icons.print_outlined),
                onPressed: () async {
                  try {
                    await PdfDocs.printBytes(await PdfDocs(repo).statement(p), 'صورت‌حساب ${p.name}');
                  } catch (e) {
                    if (c.mounted) toast(c, 'چاپ ممکن نشد: $e');
                  }
                },
              ),
              IconButton(tooltip: 'ویرایش', icon: const Icon(Icons.edit_outlined), onPressed: () => editParty(c, repo, p)),
            ]),
            body: Constrained(
              maxWidth: 820,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
                StatCard(
                  title: p.balance == 0 ? 'تسویه' : (p.balance > 0 ? 'بدهکار به شما' : 'بستانکار از شما'),
                  value: moneyC(p.balance.abs()),
                  subtitle: [p.phone, p.note].where((s) => s.isNotEmpty).map(faDigits).join(' • '),
                  icon: Icons.account_balance_outlined,
                  color: p.balance == 0 ? Theme.of(c).colorScheme.primary : amountColor(c, p.balance),
                ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: () => editTx(c, repo, partyId: p.id, kind: 'receipt'),
                      icon: const Icon(Icons.south_west), label: const Text('دریافت از او')),
                  OutlinedButton.icon(
                      onPressed: () => editTx(c, repo, partyId: p.id, kind: 'payment'),
                      icon: const Icon(Icons.north_east), label: const Text('پرداخت به او')),
                ]),
                if (invs.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('فاکتورها', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(children: [
                      for (final i in invs)
                        ListTile(
                          dense: true,
                          title: Text('${i.info.label} شمارهٔ ${faDigits('${i.number}')}'),
                          subtitle: Text(jalaliText(i.date)),
                          trailing: Text(money(i.total)),
                          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => InvoiceViewPage(repo: repo, invoiceId: i.id))),
                        ),
                    ]),
                  ),
                ],
                if (txs.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('تراکنش‌ها', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(children: [
                      for (final t in txs)
                        ListTile(
                          dense: true,
                          leading: Icon(t.kind == 'receipt' ? Icons.south_west : Icons.north_east,
                              color: t.kind == 'receipt' ? Colors.green : Colors.redAccent),
                          title: Text('${t.kind == 'receipt' ? 'دریافت' : 'پرداخت'} ${moneyC(t.amount)}'),
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
}
