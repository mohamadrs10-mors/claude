import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../print/report_builders.dart';
import '../util/format.dart';
import 'common.dart';
import 'invoices_page.dart';
import 'period.dart';
import 'print_dialog.dart';

/// معین اشخاص: pick a party and a period and see every invoice and every
/// payment/receipt between us, with the running balance. Printable.
class PartyLedgerTab extends StatefulWidget {
  const PartyLedgerTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<PartyLedgerTab> createState() => _PartyLedgerTabState();
}

class _PartyLedgerTabState extends State<PartyLedgerTab> {
  final period = PeriodController(kind: PeriodKind.all);
  List<Party> parties = [];
  String? selected;
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    () async {
      final list = await widget.repo.parties();
      if (!mounted) return;
      setState(() {
        parties = list;
        selected = list.isEmpty ? null : list.first.id;
        loaded = true;
      });
    }();
  }

  @override
  void dispose() {
    period.dispose();
    super.dispose();
  }

  static String _bal(int v) => v == 0 ? '۰' : (v > 0 ? '${money(v)} بدهکار' : '${money(-v)} بستانکار');

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    if (parties.isEmpty) return emptyState('هنوز شخصی تعریف نشده است.');
    final party = parties.firstWhere((p) => p.id == selected, orElse: () => parties.first);
    return ListenableBuilder(
      listenable: period,
      builder: (context, _) => RepoBuilder<PartyLedger>(
        key: ValueKey('pledger${party.id}${period.key}'),
        repo: widget.repo,
        load: () {
          final (a, b) = period.range;
          return widget.repo.partyLedger(party.id, from: a, toExclusive: b);
        },
        builder: (c, l) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          DropdownMenu<String>(
            key: ValueKey('menu${party.id}'),
            expandedInsets: EdgeInsets.zero,
            initialSelection: party.id,
            enableFilter: true,
            requestFocusOnTap: true,
            label: const Text('شخص'),
            dropdownMenuEntries: [for (final p in parties) DropdownMenuEntry(value: p.id, label: p.name)],
            onSelected: (v) {
              if (v != null) setState(() => selected = v);
            },
          ),
          const SizedBox(height: 10),
          PeriodBar(controller: period),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: PrintButton(repo: widget.repo, doc: () => partyLedgerDoc(party, l, period.label)),
          ),
          Row(children: [
            Expanded(child: StatCard(title: 'مانده از قبل', value: _bal(l.opening), icon: Icons.first_page, color: Colors.blueGrey)),
            const SizedBox(width: 12),
            Expanded(child: StatCard(title: 'مانده پایان', value: _bal(l.closing), icon: Icons.last_page, color: l.closing > 0 ? Colors.orange.shade800 : (l.closing < 0 ? Colors.green.shade700 : Theme.of(c).colorScheme.primary))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: StatCard(title: 'جمع بدهکار', value: moneyC(l.totalDebit), icon: Icons.north_east, color: Colors.redAccent)),
            const SizedBox(width: 12),
            Expanded(child: StatCard(title: 'جمع بستانکار', value: moneyC(l.totalCredit), icon: Icons.south_west, color: Colors.green)),
          ]),
          const SizedBox(height: 12),
          if (l.rows.isEmpty)
            emptyState('در این بازه فاکتور یا تراکنشی بین ما و ${party.name} نیست.')
          else
            Card(
              child: Column(children: [
                for (var i = 0; i < l.rows.length; i++) ...[
                  if (i > 0) const Divider(),
                  _row(c, l.rows[i]),
                ],
              ]),
            ),
          if (l.pendingCheques.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('چک‌های در انتظار (هنوز در مانده نیامده‌اند)', style: Theme.of(c).textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                for (final x in l.pendingCheques)
                  ListTile(
                    dense: true,
                    leading: Icon(x.kind == 'received' ? Icons.south_west : Icons.north_east, color: x.kind == 'received' ? Colors.green : Colors.redAccent),
                    title: Text(moneyC(x.amount)),
                    subtitle: Text('سررسید ${jalaliText(x.dueDate)}${x.number.isEmpty ? '' : ' • شمارهٔ ${faDigits(x.number)}'}${x.bank.isEmpty ? '' : ' • ${x.bank}'}'),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          Text('بدهکار یعنی طلب ما از شخص؛ بستانکار یعنی بدهی ما به او. با زدن روی هر فاکتور، خود فاکتور باز می‌شود.', style: Theme.of(c).textTheme.bodySmall),
        ]),
      ),
    );
  }

  Widget _row(BuildContext c, PartyLedgerRow r) {
    final isInvoice = r.invoiceId != null && r.type != 'کسر از پیش‌دریافت';
    final icon = isInvoice ? Icons.receipt_long_outlined : (r.type == 'دریافت' ? Icons.south_west : (r.type == 'پرداخت' ? Icons.north_east : Icons.savings_outlined));
    return ListTile(
      dense: true,
      leading: Icon(icon, color: r.credit > 0 ? Colors.green : Colors.redAccent),
      title: Text('${r.type}${r.number.isEmpty ? '' : ' ${r.number}'}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([jalaliText(r.date), if (r.description.isNotEmpty) r.description].join(' • ')),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(r.debit > 0 ? '+${money(r.debit)}' : '−${money(r.credit)}', style: TextStyle(fontWeight: FontWeight.w600, color: r.debit > 0 ? Colors.redAccent : Colors.green.shade700)),
        Text('مانده ${_bal(r.balance)}', style: Theme.of(c).textTheme.bodySmall),
      ]),
      onTap: r.invoiceId == null
          ? null
          : () => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => InvoiceViewPage(repo: widget.repo, invoiceId: r.invoiceId!))),
    );
  }
}
