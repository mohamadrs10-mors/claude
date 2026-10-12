import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import '../print/report_builders.dart';
import 'common.dart';
import 'print_dialog.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => RepoBuilder<(List<Account>, List<Category>)>(
        repo: repo,
        load: () async => (await repo.accounts(), await repo.categories()),
        builder: (c, d) {
          final (accounts, cats) = d;
          final total = accounts.fold<int>(0, (a, b) => a + b.balance);
          return Scaffold(
            body: Constrained(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              StatCard(title: 'جمع موجودی همهٔ حساب‌ها', value: moneyC(total), icon: Icons.account_balance_wallet_outlined, color: amountColor(c, total) == Theme.of(c).hintColor ? Theme.of(c).colorScheme.primary : amountColor(c, total)),
              const SizedBox(height: 16),
              _header(c, 'حساب‌ها', () => _editAccount(c), trailing: PrintButton(repo: repo, doc: () => accountsDoc(accounts))),
              if (accounts.isEmpty) emptyState('هنوز حسابی ندارید. یک صندوق یا حساب بانکی اضافه کنید.'),
              if (accounts.isNotEmpty) Card(child: Column(children: [
              for (final a in accounts)
                ListTile(
                  leading: Icon(a.kind == 'cash' ? Icons.payments_outlined : Icons.account_balance_outlined),
                  title: Text(a.name),
                  subtitle: Text(a.kind == 'cash' ? 'صندوق' : 'بانک'),
                  trailing: Text(money(a.balance), style: TextStyle(color: amountColor(c, a.balance), fontWeight: FontWeight.bold)),
                  onTap: () => _editAccount(c, a),
                ),
              ])),
              const SizedBox(height: 16),
              _header(c, 'دسته‌بندی‌ها', () => _editCategory(c)),
              if (cats.isEmpty) emptyState('برای گزارش بهتر، دسته‌بندی درآمد و هزینه تعریف کنید.'),
              if (cats.isNotEmpty) Card(child: Column(children: [
              for (final k in cats)
                ListTile(
                  leading: Icon(k.kind == 'income' ? Icons.south_west : Icons.north_east,
                      color: k.kind == 'income' ? Colors.green : Colors.redAccent),
                  title: Text(k.name),
                  subtitle: Text(k.kind == 'income' ? 'درآمد' : 'هزینه'),
                  onTap: () => _editCategory(c, k),
                ),
              ])),
            ])),
          );
        },
      );

  Widget _header(BuildContext c, String t, VoidCallback add, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Text(t, style: Theme.of(c).textTheme.titleMedium),
          const Spacer(),
          ?trailing,
          IconButton.filledTonal(onPressed: add, icon: const Icon(Icons.add), tooltip: 'افزودن'),
        ]),
      );

  Future<void> _editAccount(BuildContext c, [Account? a]) async {
    final name = TextEditingController(text: a?.name);
    final opening = TextEditingController(text: a == null ? '' : '${a.opening}');
    var kind = a?.kind ?? 'cash';
    final key = GlobalKey<FormState>();
    await showDialog(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text(a == null ? 'حساب جدید' : 'ویرایش حساب'),
          content: Form(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'نام حساب', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').trim().isEmpty ? 'نام را وارد کنید' : null,
              ),
              gap(),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'cash', label: Text('صندوق')),
                  ButtonSegment(value: 'bank', label: Text('بانک')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => set(() => kind = s.first),
              ),
              gap(),
              AmountField(controller: opening, label: 'موجودی اولیه'),
            ]),
          ),
          actions: [
            if (a != null)
              TextButton(
                onPressed: () async {
                  if (!await confirm(dc, 'این حساب حذف شود؟')) return;
                  final err = await repo.deleteAccount(a.id);
                  if (!dc.mounted) return;
                  if (err != null) {
                    toast(dc, err);
                  } else {
                    Navigator.pop(dc);
                  }
                },
                child: const Text('حذف'),
              ),
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                if (!key.currentState!.validate()) return;
                await repo.saveAccount(id: a?.id, name: name.text.trim(), kind: kind, opening: parseAmount(opening.text));
                if (dc.mounted) Navigator.pop(dc);
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editCategory(BuildContext c, [Category? k]) async {
    final name = TextEditingController(text: k?.name);
    var kind = k?.kind ?? 'expense';
    final key = GlobalKey<FormState>();
    await showDialog(
      context: c,
      builder: (dc) => StatefulBuilder(
        builder: (dc, set) => AlertDialog(
          title: Text(k == null ? 'دسته‌بندی جدید' : 'ویرایش دسته‌بندی'),
          content: Form(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: name,
                decoration: const InputDecoration(labelText: 'نام', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').trim().isEmpty ? 'نام را وارد کنید' : null,
              ),
              gap(),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'income', label: Text('درآمد')),
                  ButtonSegment(value: 'expense', label: Text('هزینه')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => set(() => kind = s.first),
              ),
            ]),
          ),
          actions: [
            if (k != null)
              TextButton(
                onPressed: () async {
                  if (!await confirm(dc, 'این دسته‌بندی حذف شود؟')) return;
                  final err = await repo.deleteCategory(k.id);
                  if (!dc.mounted) return;
                  if (err != null) {
                    toast(dc, err);
                  } else {
                    Navigator.pop(dc);
                  }
                },
                child: const Text('حذف'),
              ),
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
            FilledButton(
              onPressed: () async {
                if (!key.currentState!.validate()) return;
                await repo.saveCategory(id: k?.id, name: name.text.trim(), kind: kind);
                if (dc.mounted) Navigator.pop(dc);
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
  }
}
