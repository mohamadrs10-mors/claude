import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import '../print/report_builders.dart';
import 'common.dart';
import 'print_dialog.dart';

const _statusLabel = {'pending': 'در انتظار', 'cleared': 'وصول شده', 'bounced': 'برگشتی'};

Color _statusColor(BuildContext c, String s) => switch (s) {
      'cleared' => Colors.green.shade700,
      'bounced' => Theme.of(c).colorScheme.error,
      _ => Colors.orange.shade800,
    };

class ChequesPage extends StatefulWidget {
  const ChequesPage({super.key, required this.repo});
  final Repo repo;
  @override
  State<ChequesPage> createState() => _ChequesPageState();
}

class _ChequesPageState extends State<ChequesPage> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 2, vsync: this);
  Map<String, int> _orderNo = {};

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepoBuilder<(List<Cheque>, Map<String, String>, Map<String, int>)>(
        repo: widget.repo,
        load: () async => (
          await widget.repo.cheques(),
          {for (final p in await widget.repo.parties()) p.id: p.name},
          {for (final o in await widget.repo.orders()) o.id: o.number},
        ),
        builder: (c, d) {
          final (all, names, orderNo) = d;
          _orderNo = orderNo;
          return Scaffold(
            body: Constrained(
              child: Column(children: [
                TabBar(controller: tabs, tabs: const [Tab(text: 'چک‌های دریافتی'), Tab(text: 'چک‌های پرداختی')]),
                Expanded(
                  child: TabBarView(controller: tabs, children: [
                    _list(c, all.where((x) => x.kind == 'received').toList(), names),
                    _list(c, all.where((x) => x.kind == 'issued').toList(), names),
                  ]),
                ),
              ]),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => editCheque(c, widget.repo, kind: tabs.index == 0 ? 'received' : 'issued'),
              icon: const Icon(Icons.add),
              label: const Text('چک جدید'),
            ),
          );
        },
      );

  Widget _list(BuildContext c, List<Cheque> list, Map<String, String> names) {
    if (list.isEmpty) return emptyState('چکی ثبت نشده است.');
    final today = todayIso();
    final total = list.where((x) => x.status == 'pending').fold<int>(0, (a, x) => a + x.amount);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: PrintButton(
          repo: widget.repo,
          doc: () => chequesDoc(list, names, title: tabs.index == 0 ? 'فهرست چک‌های دریافتی' : 'فهرست چک‌های پرداختی'),
        ),
      ),
      StatCard(title: 'جمع چک‌های در انتظار', value: moneyC(total), icon: Icons.pending_actions, color: Colors.orange.shade800),
      const SizedBox(height: 12),
      Card(
        child: Column(children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const Divider(),
            Builder(builder: (c) {
              final x = list[i];
              final overdue = x.status == 'pending' && x.dueDate.compareTo(today) < 0;
              return ListTile(
                leading: Icon(x.kind == 'received' ? Icons.south_west : Icons.north_east,
                    color: x.kind == 'received' ? Colors.green : Colors.redAccent),
                title: Text('${money(x.amount)} $currencyLabel', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  'سررسید ${jalaliText(x.dueDate)}${overdue ? ' (گذشته)' : ''}',
                  if (x.partyId != null) names[x.partyId] ?? '',
                  if (x.bank.isNotEmpty) x.bank,
                  if (x.number.isNotEmpty) 'شمارهٔ ${faDigits(x.number)}',
                  if (x.orderId != null) 'پیش‌دریافت سفارش ${faDigits('${_orderNo[x.orderId] ?? ''}')}',
                ].join(' • ')),
                trailing: StatusChip(overdue ? 'سررسید گذشته' : _statusLabel[x.status]!,
                    overdue ? Theme.of(c).colorScheme.error : _statusColor(c, x.status)),
                onTap: () => editCheque(c, widget.repo, cheque: x),
              );
            }),
          ],
        ]),
      ),
    ]);
  }
}

/// [partyId] and [orderId] pre-fill a new cheque that is the advance of an order.
Future<void> editCheque(BuildContext context, Repo repo, {Cheque? cheque, String kind = 'received', String? partyId, String? orderId}) async {
  final parties = await repo.parties();
  final accounts = await repo.accounts();
  if (!context.mounted) return;
  var k = cheque?.kind ?? kind;
  var due = cheque?.dueDate ?? todayIso();
  String? party = cheque?.partyId ?? partyId;
  final forOrder = (cheque?.orderId ?? orderId) != null;
  final amount = TextEditingController(text: cheque == null ? '' : '${cheque.amount}');
  final number = TextEditingController(text: cheque?.number);
  final bank = TextEditingController(text: cheque?.bank);
  final note = TextEditingController(text: cheque?.note);
  final key = GlobalKey<FormState>();

  await showDialog(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: Text(cheque == null ? 'چک جدید' : 'ویرایش چک'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Form(
              key: key,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'received', label: Text('دریافتی'), icon: Icon(Icons.south_west)),
                    ButtonSegment(value: 'issued', label: Text('پرداختی'), icon: Icon(Icons.north_east)),
                  ],
                  selected: {k},
                  onSelectionChanged: cheque == null && !forOrder ? (s) => set(() => k = s.first) : null,
                ),
                gap(),
                AmountField(
                  controller: amount,
                  validator: (v) => parseAmount(v ?? '') <= 0 ? 'مبلغ را وارد کنید' : null,
                ),
                gap(),
                JalaliDateField(iso: due, label: 'تاریخ سررسید', onChanged: (v) => set(() => due = v)),
                gap(),
                DropdownButtonFormField<String?>(
                  initialValue: party,
                  decoration: InputDecoration(labelText: k == 'received' ? 'دریافت از' : 'پرداخت به'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('—')),
                    for (final p in parties) DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: forOrder ? null : (v) => party = v,
                ),
                if (forOrder)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text('این چک بخشی از پیش‌دریافت یک سفارش است؛ با وصول آن مشتری بستانکار نمی‌شود.', style: Theme.of(dc).textTheme.bodySmall),
                    ),
                  ),
                gap(),
                Row(children: [
                  Expanded(child: TextFormField(controller: number, decoration: const InputDecoration(labelText: 'شمارهٔ چک'))),
                  const SizedBox(width: 12),
                  Expanded(child: TextFormField(controller: bank, decoration: const InputDecoration(labelText: 'بانک'))),
                ]),
                gap(),
                TextFormField(controller: note, decoration: const InputDecoration(labelText: 'توضیحات')),
                if (cheque != null) ...[
                  gap(16),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('وضعیت: ${_statusLabel[cheque.status]}', style: Theme.of(dc).textTheme.titleSmall),
                  ),
                  gap(8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    if (cheque.status != 'cleared')
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('وصول شد'),
                        onPressed: () async {
                          final acc = await _pickAccount(dc, accounts);
                          if (acc == null) return;
                          await repo.setChequeStatus(cheque, 'cleared', accountId: acc);
                          if (dc.mounted) Navigator.pop(dc);
                        },
                      ),
                    if (cheque.status != 'bounced')
                      OutlinedButton.icon(
                        icon: const Icon(Icons.undo),
                        label: const Text('برگشت خورد'),
                        onPressed: () async {
                          await repo.setChequeStatus(cheque, 'bounced');
                          if (dc.mounted) Navigator.pop(dc);
                        },
                      ),
                    if (cheque.status != 'pending')
                      OutlinedButton.icon(
                        icon: const Icon(Icons.hourglass_empty),
                        label: const Text('بازگشت به در انتظار'),
                        onPressed: () async {
                          await repo.setChequeStatus(cheque, 'pending');
                          if (dc.mounted) Navigator.pop(dc);
                        },
                      ),
                  ]),
                ],
              ]),
            ),
          ),
        ),
        actions: [
          if (cheque != null)
            TextButton(
              onPressed: () async {
                if (!await confirm(dc, 'این چک حذف شود؟${cheque.txId != null ? ' تراکنش وصول آن هم حذف می‌شود.' : ''}')) return;
                await repo.deleteCheque(cheque);
                if (dc.mounted) Navigator.pop(dc);
              },
              child: const Text('حذف'),
            ),
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              if (!key.currentState!.validate()) return;
              await repo.saveCheque(
                id: cheque?.id,
                kind: k,
                number: enDigits(number.text.trim()),
                bank: bank.text.trim(),
                amount: parseAmount(amount.text),
                dueDate: due,
                partyId: party,
                note: note.text.trim(),
                orderId: orderId,
              );
              if (dc.mounted) Navigator.pop(dc);
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    ),
  );
}

Future<String?> _pickAccount(BuildContext c, List<Account> accounts) async {
  if (accounts.isEmpty) {
    toast(c, 'ابتدا یک حساب بسازید.');
    return null;
  }
  return showDialog<String>(
    context: c,
    builder: (dc) => SimpleDialog(
      title: const Text('به کدام حساب وصول شد؟'),
      children: [
        for (final a in accounts)
          SimpleDialogOption(onPressed: () => Navigator.pop(dc, a.id), child: Text(a.name)),
      ],
    ),
  );
}
