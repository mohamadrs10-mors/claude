import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import '../print/report_builders.dart';
import 'common.dart';
import 'print_dialog.dart';

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
            child: Row(children: [
              Expanded(
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
              const SizedBox(width: 8),
              PrintButton(
                repo: repo,
                doc: () => transactionsDoc(d.txs,
                    accounts: d.accounts,
                    parties: d.parties,
                    categories: d.cats,
                    filter: accountId == null ? 'همهٔ حساب‌ها' : 'حساب: ${d.accounts[accountId] ?? ''}'),
              ),
            ]),
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
                      final isTransfer = t.kind == 'transfer';
                      final sub = [
                        jalaliText(t.date),
                        isTransfer ? 'از ${d.accounts[t.accountId] ?? ''} به ${d.accounts[t.toAccountId] ?? ''}' : (d.accounts[t.accountId] ?? ''),
                        if (t.partyId != null) d.parties[t.partyId] ?? '',
                        if (t.categoryId != null) d.cats[t.categoryId] ?? '',
                        if (t.description.isNotEmpty) t.description,
                      ].join(' • ');
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: txColor(t.kind).withValues(alpha: 0.14),
                            child: Icon(txIcon(t.kind), color: txColor(t.kind)),
                          ),
                          title: Text('${txKindLabel(t.kind)}  ${moneyC(t.amount)}', style: const TextStyle(fontWeight: FontWeight.w600)),
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
  String? toAccountId = tx?.toAccountId ?? (accounts.length > 1 ? accounts[1].id : null);
  String? party = tx?.partyId ?? partyId;
  String? cat = tx?.categoryId;
  final amountC = TextEditingController(text: tx != null ? '${tx.amount}' : (amount != null ? '$amount' : ''));
  final desc = TextEditingController(text: tx?.description);
  final key = GlobalKey<FormState>();

  await showDialog(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) {
        final transfer = k == 'transfer';
        final cats = allCats.where((c) => c.kind == (k == 'receipt' ? 'income' : 'expense')).toList();
        if (cat != null && !cats.any((c) => c.id == cat)) cat = null;
        return AlertDialog(
          title: Text(tx == null ? (transfer ? 'انتقال بین حساب‌ها' : 'تراکنش جدید') : 'ویرایش تراکنش'),
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
                      ButtonSegment(value: 'transfer', label: Text('انتقال'), icon: Icon(Icons.swap_horiz)),
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
                    decoration: InputDecoration(labelText: transfer ? 'از حساب' : 'حساب', border: const OutlineInputBorder()),
                    items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                    onChanged: (v) => accountId = v,
                  ),
                  if (transfer) ...[
                    gap(),
                    DropdownButtonFormField<String?>(
                      initialValue: toAccountId,
                      decoration: const InputDecoration(labelText: 'به حساب', border: OutlineInputBorder()),
                      items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                      validator: (v) => v == null ? 'حساب مقصد را انتخاب کنید' : (v == accountId ? 'مبدأ و مقصد یکی است' : null),
                      onChanged: (v) => toAccountId = v,
                    ),
                  ],
                  if (!transfer) ...[
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
                  ],
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
                  toAccountId: k == 'transfer' ? toAccountId : null,
                  partyId: k == 'transfer' ? null : party,
                  categoryId: k == 'transfer' ? null : cat,
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
