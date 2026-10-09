import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String? accountId;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    return RepoBuilder<_TxData>(
      repo: repo,
      load: () async => _TxData(
        await repo.transactions(accountId: accountId),
        {for (final a in await repo.accounts()) a.id: a.name},
        {for (final p in await repo.parties()) p.id: p.name},
        {for (final k in await repo.categories()) k.id: k.name},
      ),
      builder: (c, d) => Scaffold(
        body: Constrained(child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: DropdownButtonFormField<String?>(
              initialValue: accountId,
              decoration: const InputDecoration(labelText: 'فیلتر حساب', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem(value: null, child: Text('همهٔ حساب‌ها')),
                for (final e in d.accounts.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => accountId = v),
            ),
          ),
          Expanded(
            child: d.txs.isEmpty
                ? emptyState('تراکنشی ثبت نشده است.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    itemCount: d.txs.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (c, i) {
                      final t = d.txs[i];
                      final isIn = t.kind == 'receipt';
                      final sub = [
                        jalaliText(t.date),
                        d.accounts[t.accountId] ?? '',
                        if (t.partyId != null) d.parties[t.partyId] ?? '',
                        if (t.categoryId != null) d.cats[t.categoryId] ?? '',
                        if (t.description.isNotEmpty) t.description,
                      ].join(' • ');
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: (isIn ? Colors.green : Colors.redAccent).withValues(alpha: 0.14),
                            child: Icon(isIn ? Icons.south_west : Icons.north_east, color: isIn ? Colors.green : Colors.redAccent),
                          ),
                          title: Text('${isIn ? 'دریافت' : 'پرداخت'}  ${moneyC(t.amount)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(sub),
                          onTap: () => editTx(c, repo, tx: t),
                        ),
                      );
                    },
                  ),
          ),
        ])),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => editTx(c, repo),
          icon: const Icon(Icons.add),
          label: const Text('تراکنش جدید'),
        ),
      ),
    );
  }
}

class _TxData {
  _TxData(this.txs, this.accounts, this.parties, this.cats);
  final List<Tx> txs;
  final Map<String, String> accounts, parties, cats;
}

/// Add/edit a receipt or payment. Also used from the invoice screen to record
/// a payment against an invoice (pass [invoiceId], [partyId], [kind], [amount]).
Future<void> editTx(BuildContext context, Repo repo,
    {Tx? tx, String? partyId, String? invoiceId, String? kind, int? amount}) async {
  final accounts = await repo.accounts();
  final parties = await repo.parties();
  final allCats = await repo.categories();
  if (!context.mounted) return;
  if (accounts.isEmpty) {
    toast(context, 'ابتدا از بخش «حساب‌ها» یک حساب بسازید.');
    return;
  }
  var k = tx?.kind ?? kind ?? 'receipt';
  var date = tx?.date ?? todayIso();
  String? accountId = tx?.accountId ?? accounts.first.id;
  String? party = tx?.partyId ?? partyId;
  String? cat = tx?.categoryId;
  final amountC = TextEditingController(text: tx != null ? '${tx.amount}' : (amount != null ? '$amount' : ''));
  final desc = TextEditingController(text: tx?.description);
  final key = GlobalKey<FormState>();

  await showDialog(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) {
        final cats = allCats.where((c) => c.kind == (k == 'receipt' ? 'income' : 'expense')).toList();
        if (cat != null && !cats.any((c) => c.id == cat)) cat = null;
        return AlertDialog(
          title: Text(tx == null ? 'تراکنش جدید' : 'ویرایش تراکنش'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: key,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'receipt', label: Text('دریافت'), icon: Icon(Icons.south_west)),
                      ButtonSegment(value: 'payment', label: Text('پرداخت'), icon: Icon(Icons.north_east)),
                    ],
                    selected: {k},
                    onSelectionChanged: (s) => set(() => k = s.first),
                  ),
                  gap(),
                  AmountField(
                    controller: amountC,
                    validator: (v) => parseAmount(v ?? '') <= 0 ? 'مبلغ را وارد کنید' : null,
                  ),
                  gap(),
                  JalaliDateField(iso: date, onChanged: (v) => set(() => date = v)),
                  gap(),
                  DropdownButtonFormField<String?>(
                    initialValue: accountId,
                    decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder()),
                    items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                    onChanged: (v) => accountId = v,
                  ),
                  gap(),
                  DropdownButtonFormField<String?>(
                    initialValue: party,
                    decoration: const InputDecoration(labelText: 'شخص (اختیاری)', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('—')),
                      for (final p in parties) DropdownMenuItem(value: p.id, child: Text(p.name)),
                    ],
                    onChanged: (v) => party = v,
                  ),
                  gap(),
                  DropdownButtonFormField<String?>(
                    key: ValueKey(k),
                    initialValue: cat,
                    decoration: const InputDecoration(labelText: 'دسته‌بندی (اختیاری)', border: OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('—')),
                      for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => cat = v,
                  ),
                  gap(),
                  TextFormField(
                    controller: desc,
                    decoration: const InputDecoration(labelText: 'توضیحات', border: OutlineInputBorder()),
                  ),
                ]),
              ),
            ),
          ),
          actions: [
            if (tx != null)
              TextButton(
                onPressed: () async {
                  if (!await confirm(dc, 'این تراکنش حذف شود؟')) return;
                  await repo.deleteTx(tx.id);
                  if (dc.mounted) Navigator.pop(dc);
                },
                child: const Text('حذف'),
              ),
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                if (!key.currentState!.validate()) return;
                await repo.saveTx(
                  id: tx?.id,
                  date: date,
                  kind: k,
                  amount: parseAmount(amountC.text),
                  accountId: accountId!,
                  partyId: party,
                  categoryId: cat,
                  invoiceId: tx?.invoiceId ?? invoiceId,
                  description: desc.text.trim(),
                );
                if (dc.mounted) Navigator.pop(dc);
              },
              child: const Text('ذخیره'),
            ),
          ],
        );
      },
    ),
  );
}
