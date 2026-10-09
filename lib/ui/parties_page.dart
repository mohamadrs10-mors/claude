import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'transactions_page.dart';

class PartiesPage extends StatelessWidget {
  const PartiesPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<List<Party>>(
        repo: repo,
        load: repo.parties,
        builder: (c, list) => Scaffold(
          body: list.isEmpty
              ? emptyState('هنوز شخصی ثبت نشده است.')
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final p = list[i];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                      title: Text(p.name),
                      subtitle: Text(p.balance == 0
                          ? 'تسویه'
                          : (p.balance > 0 ? 'بدهکار به شما' : 'بستانکار از شما')),
                      trailing: Text(money(p.balance.abs()),
                          style: TextStyle(fontWeight: FontWeight.bold, color: amountColor(c, p.balance))),
                      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => PartyDetailPage(repo: repo, party: p))),
                    );
                  },
                ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => editParty(c, repo),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('شخص جدید'),
          ),
        ),
      );
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
              IconButton(icon: const Icon(Icons.edit), onPressed: () => editParty(c, repo, p)),
            ]),
            body: ListView(children: [
              ListTile(
                title: Text(p.balance == 0 ? 'تسویه' : (p.balance > 0 ? 'بدهکار به شما' : 'بستانکار از شما')),
                subtitle: Text([p.phone, p.note].where((s) => s.isNotEmpty).join(' • ')),
                trailing: Text('${money(p.balance.abs())} تومان',
                    style: Theme.of(c).textTheme.titleMedium?.copyWith(color: amountColor(c, p.balance))),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: () => editTx(c, repo, partyId: p.id, kind: 'receipt'),
                      icon: const Icon(Icons.south_west), label: const Text('دریافت از او')),
                  OutlinedButton.icon(
                      onPressed: () => editTx(c, repo, partyId: p.id, kind: 'payment'),
                      icon: const Icon(Icons.north_east), label: const Text('پرداخت به او')),
                ]),
              ),
              const Divider(),
              if (invs.isNotEmpty) const ListTile(title: Text('فاکتورها')),
              for (final i in invs)
                ListTile(
                  dense: true,
                  title: Text('${i.kind == 'sale' ? 'فروش' : 'خرید'} شمارهٔ ${faDigits('${i.number}')}'),
                  subtitle: Text(jalaliText(i.date)),
                  trailing: Text(money(i.total)),
                ),
              if (txs.isNotEmpty) const ListTile(title: Text('تراکنش‌ها')),
              for (final t in txs)
                ListTile(
                  dense: true,
                  leading: Icon(t.kind == 'receipt' ? Icons.south_west : Icons.north_east,
                      color: t.kind == 'receipt' ? Colors.green : Colors.redAccent),
                  title: Text('${t.kind == 'receipt' ? 'دریافت' : 'پرداخت'} ${money(t.amount)}'),
                  subtitle: Text(jalaliText(t.date)),
                  onTap: () => editTx(c, repo, tx: t),
                ),
            ]),
          );
        },
      );
}
