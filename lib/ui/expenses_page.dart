import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/expenses_repo.dart';
import '../data/repo.dart';
import '../print/report_doc.dart';
import '../util/format.dart';
import 'auth.dart';
import 'common.dart';
import 'period.dart';
import 'print_dialog.dart';

String _msg(Object e) => e is StateError ? e.message : '$e';

/// Expenses (هزینه‌ها): rent, bills, repairs and the like, registered without
/// a purchase invoice, plus standing monthly expenses.
class ExpensesPage extends StatelessWidget {
  const ExpensesPage({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(children: [
          const TabBar(tabs: [Tab(text: 'هزینه‌ها'), Tab(text: 'هزینه‌های ثابت ماهانه')]),
          Expanded(child: TabBarView(children: [ExpensesTab(repo: repo), RecurringTab(repo: repo)])),
        ]),
      );
}

/// What the category choice in a form stands for: an existing category, or a
/// new name to be created when saving.
class CatChoice {
  CatChoice({this.id, this.newName});
  String? id, newName;
}

/// The category field of the expense forms: the expense categories, the usual
/// names that do not exist yet, and "another name...".
Widget categoryField(BuildContext dc, List<Category> cats, CatChoice choice, void Function(void Function()) set) {
  final existing = {for (final c in cats) c.name};
  final suggestions = [for (final n in suggestedExpenseCategories) if (!existing.contains(n)) n];
  final value = choice.id ?? (choice.newName == null ? null : 'n:${choice.newName}');
  final items = <DropdownMenuItem<String>>[
    for (final c in cats) DropdownMenuItem(value: c.id, child: Text(c.name)),
    if (choice.newName != null && !suggestions.contains(choice.newName)) DropdownMenuItem(value: 'n:${choice.newName}', child: Text('${choice.newName} (جدید)')),
    for (final n in suggestions) DropdownMenuItem(value: 'n:$n', child: Text('$n (پیشنهادی)')),
    const DropdownMenuItem(value: '#other', child: Text('نام دیگر...')),
  ];
  return DropdownButtonFormField<String>(
    key: ValueKey('cat$value${items.length}'),
    isExpanded: true,
    initialValue: items.any((i) => i.value == value) ? value : null,
    decoration: const InputDecoration(labelText: 'دستهٔ هزینه'),
    items: items,
    onChanged: (v) async {
      if (v == null) return;
      if (v == '#other') {
        final c = TextEditingController();
        final name = await showDialog<String>(
          context: dc,
          builder: (d2) => AlertDialog(
            title: const Text('دستهٔ هزینهٔ جدید'),
            content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'نام دسته')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d2), child: const Text('انصراف')),
              FilledButton(onPressed: () => Navigator.pop(d2, c.text.trim()), child: const Text('تأیید')),
            ],
          ),
        );
        if (name != null && name.isNotEmpty) {
          set(() {
            choice.id = null;
            choice.newName = name;
          });
        }
      } else if (v.startsWith('n:')) {
        set(() {
          choice.id = null;
          choice.newName = v.substring(2);
        });
      } else {
        set(() {
          choice.id = v;
          choice.newName = null;
        });
      }
    },
  );
}

/// Registers or edits an expense.
Future<void> editExpense(BuildContext context, Repo repo, {Expense? expense}) async {
  final accounts = await repo.accounts();
  final cats = [for (final c in await repo.categories()) if (c.kind == 'expense') c];
  if (!context.mounted) return;
  if (accounts.isEmpty) return toast(context, 'ابتدا از بخش «حساب‌ها» یک حساب (صندوق یا بانک) بسازید.');
  var date = expense?.date ?? todayIso();
  String account = accounts.any((a) => a.id == expense?.accountId) ? expense!.accountId : accounts.first.id;
  final choice = CatChoice(id: expense?.categoryId);
  final amount = TextEditingController(text: expense == null ? '' : '${expense.amount}');
  final desc = TextEditingController(text: expense?.description);
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: Text(expense == null ? 'ثبت هزینه' : 'ویرایش هزینه'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('برای اجاره، قبض، تعمیرات و مانند آن فاکتور خرید لازم نیست؛ مبلغ از حساب کم می‌شود و در سود و زیان به‌عنوان هزینه می‌آید.', style: Theme.of(dc).textTheme.bodySmall),
              gap(),
              categoryField(dc, cats, choice, set),
              gap(),
              AmountField(controller: amount, label: 'مبلغ'),
              gap(),
              JalaliDateField(iso: date, onChanged: (v) => set(() => date = v)),
              gap(),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: account,
                decoration: const InputDecoration(labelText: 'پرداخت از حساب'),
                items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => account = v ?? account,
              ),
              gap(),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'شرح (پرداخت به چه کسی / برای چه)')),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
        ),
        actions: [
          if (expense != null)
            TextButton(
              onPressed: () async {
                if (!await confirm(dc, 'این هزینه حذف شود؟')) return;
                try {
                  await repo.deleteTx(expense.id);
                  if (dc.mounted) Navigator.pop(dc);
                } catch (e) {
                  set(() => error = _msg(e));
                }
              },
              child: const Text('حذف'),
            ),
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              try {
                await repo.saveExpense(id: expense?.id, date: date, amount: parseAmount(amount.text), accountId: account, categoryId: choice.id, newCategory: choice.newName, description: desc.text);
                if (dc.mounted) Navigator.pop(dc);
              } catch (e) {
                set(() => error = _msg(e));
              }
            },
            child: const Text('ثبت'),
          ),
        ],
      ),
    ),
  );
}

typedef _ExpData = (List<ExpenseGroup>, List<Expense>, Map<String, String>, Map<String, String>);

class ExpensesTab extends StatefulWidget {
  const ExpensesTab({super.key, required this.repo});
  final Repo repo;
  @override
  State<ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<ExpensesTab> {
  final period = PeriodController();
  String? filter;

  Repo get repo => widget.repo;

  Future<_ExpData> _load() async {
    final (from, to) = period.range;
    final groups = await repo.expenseGroups(from: from, toExclusive: to);
    final list = await repo.expenses(from: from, toExclusive: to);
    return (groups, list, {for (final c in await repo.categories()) c.id: c.name}, {for (final a in await repo.accounts()) a.id: a.name});
  }

  @override
  void dispose() {
    period.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('transactions');
    return ListenableBuilder(
      listenable: period,
      builder: (context, _) => RepoBuilder<_ExpData>(
        key: ValueKey(period.key),
        repo: repo,
        load: _load,
        builder: (c, data) {
          final (groups, all, cats, accs) = data;
          final total = groups.fold<int>(0, (a, g) => a + g.total);
          final list = filter == null ? all : [for (final e in all) if (e.categoryId == (filter == '' ? null : filter)) e];
          ReportDoc doc() => ReportDoc(
                title: 'گزارش هزینه‌ها',
                subtitle: period.label,
                summary: [('جمع هزینه‌ها', moneyC(total)), ('تعداد', faDigits('${all.length}'))],
                tables: [
                  ReportTable(
                    heading: 'به تفکیک دسته',
                    headers: const ['دسته', 'تعداد', 'جمع', 'سهم'],
                    cols: const [Col.text, Col.center, Col.number, Col.center],
                    flex: const [3, 1, 2, 1],
                    rows: [for (final g in groups) [g.name, faDigits('${g.count}'), money(g.total), total == 0 ? '' : '${faDigits('${(g.total * 100 / total).round()}')}٪']],
                    totals: ['جمع', '', money(total), ''],
                  ),
                  ReportTable(
                    heading: 'فهرست',
                    headers: const ['تاریخ', 'دسته', 'شرح', 'حساب', 'مبلغ'],
                    cols: const [Col.center, Col.text, Col.text, Col.text, Col.number],
                    flex: const [1.4, 2, 3, 1.6, 1.8],
                    rows: [for (final e in all) [jalaliText(e.date), cats[e.categoryId] ?? 'بدون دسته‌بندی', e.description, accs[e.accountId] ?? '', money(e.amount)]],
                  ),
                ],
              );
          return Scaffold(
            body: Constrained(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                PeriodBar(controller: period),
                gap(),
                FutureBuilder<List<RecurringExpense>>(
                  future: () {
                    final n = Jalali.now();
                    return repo.recurringDue(n.year, n.month);
                  }(),
                  builder: (c, snap) {
                    final due = snap.data ?? const <RecurringExpense>[];
                    if (due.isEmpty) return const SizedBox.shrink();
                    return Card(
                      color: Theme.of(c).colorScheme.tertiaryContainer,
                      child: ListTile(
                        leading: const Icon(Icons.event_repeat),
                        title: Text('${faDigits('${due.length}')} هزینهٔ ثابت این ماه هنوز ثبت نشده است'),
                        subtitle: Text(due.take(3).map((d) => d.title).join('، ')),
                        trailing: TextButton(onPressed: () => DefaultTabController.of(c).animateTo(1), child: const Text('ثبت')),
                      ),
                    );
                  },
                ),
                Row(children: [
                  Expanded(child: StatCard(title: 'جمع هزینه‌ها (${period.label})', value: moneyC(total), icon: Icons.receipt_long_outlined, color: Theme.of(c).colorScheme.error)),
                  const SizedBox(width: 12),
                  Expanded(child: StatCard(title: 'تعداد ثبت', value: faDigits('${all.length}'), icon: Icons.tag, color: Theme.of(c).colorScheme.primary)),
                ]),
                gap(),
                Row(children: [
                  Expanded(child: Text('به تفکیک دسته', style: Theme.of(c).textTheme.titleSmall)),
                  PrintButton(repo: repo, label: 'چاپ', doc: doc),
                ]),
                if (groups.isEmpty)
                  emptyState('در این بازه هزینه‌ای ثبت نشده است.\nبا دکمهٔ «ثبت هزینه» اجاره، قبض و هزینه‌های دیگر را ثبت کنید.')
                else
                  Card(
                    child: Column(children: [
                      for (final g in groups)
                        ListTile(
                          dense: true,
                          selected: filter == (g.categoryId ?? ''),
                          title: Text('${g.name} (${faDigits('${g.count}')})'),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: LinearProgressIndicator(value: total == 0 ? 0 : g.total / total, minHeight: 6, borderRadius: BorderRadius.circular(3)),
                          ),
                          trailing: Text(money(g.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => setState(() => filter = filter == (g.categoryId ?? '') ? null : (g.categoryId ?? '')),
                        ),
                    ]),
                  ),
                if (filter != null)
                  Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: () => setState(() => filter = null), icon: const Icon(Icons.filter_alt_off), label: const Text('نمایش همهٔ دسته‌ها'))),
                gap(),
                if (list.isNotEmpty)
                  Card(
                    child: Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.north_east),
                          title: Text(list[i].description.isEmpty ? (cats[list[i].categoryId] ?? 'هزینه') : list[i].description),
                          subtitle: Text('${faDigits(jalaliText(list[i].date))} • ${cats[list[i].categoryId] ?? 'بدون دسته‌بندی'} • ${accs[list[i].accountId] ?? ''}'),
                          trailing: Text(money(list[i].amount), style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(c).colorScheme.error)),
                          onTap: !canEdit ? null : () => editExpense(c, repo, expense: list[i]),
                        ),
                      ],
                    ]),
                  ),
              ]),
            ),
            floatingActionButton: !canEdit ? null : FloatingActionButton.extended(onPressed: () => editExpense(c, repo), icon: const Icon(Icons.add), label: const Text('ثبت هزینه')),
          );
        },
      ),
    );
  }
}

// ---- standing expenses -------------------------------------------------------

Future<void> editRecurring(BuildContext context, Repo repo, {RecurringExpense? item}) async {
  final accounts = await repo.accounts();
  final cats = [for (final c in await repo.categories()) if (c.kind == 'expense') c];
  if (!context.mounted) return;
  if (accounts.isEmpty) return toast(context, 'ابتدا از بخش «حساب‌ها» یک حساب بسازید.');
  final title = TextEditingController(text: item?.title);
  final amount = TextEditingController(text: item == null ? '' : '${item.amount}');
  final day = TextEditingController(text: '${item?.day ?? 1}');
  String account = accounts.any((a) => a.id == item?.accountId) ? item!.accountId! : accounts.first.id;
  final choice = CatChoice(id: item?.categoryId);
  var active = item?.active ?? true;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (dc) => StatefulBuilder(
      builder: (dc, set) => AlertDialog(
        title: Text(item == null ? 'هزینهٔ ثابت ماهانه' : 'ویرایش هزینهٔ ثابت'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('هزینه‌ای که هر ماه تکرار می‌شود (اجاره، اینترنت، ...). هر ماه با یک کلیک ثبت می‌شود؛ خودکار پولی از حساب کم نمی‌شود.', style: Theme.of(dc).textTheme.bodySmall),
              gap(),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'عنوان (مثلاً اجارهٔ مغازه)')),
              gap(),
              categoryField(dc, cats, choice, set),
              gap(),
              AmountField(controller: amount, label: 'مبلغ هر ماه'),
              gap(),
              Row(children: [
                Expanded(child: TextField(controller: day, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'روز ماه'))),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: account,
                    decoration: const InputDecoration(labelText: 'حساب'),
                    items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
                    onChanged: (v) => account = v ?? account,
                  ),
                ),
              ]),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فعال'), value: active, onChanged: (v) => set(() => active = v)),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: TextStyle(color: Theme.of(dc).colorScheme.error))),
            ]),
          ),
        ),
        actions: [
          if (item != null)
            TextButton(
              onPressed: () async {
                if (!await confirm(dc, 'این هزینهٔ ثابت حذف شود؟ هزینه‌های ثبت‌شدهٔ قبلی می‌مانند.')) return;
                await repo.deleteRecurring(item.id);
                if (dc.mounted) Navigator.pop(dc);
              },
              child: const Text('حذف'),
            ),
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('انصراف')),
          FilledButton(
            onPressed: () async {
              try {
                await repo.saveRecurring(
                  id: item?.id,
                  title: title.text,
                  categoryId: choice.id,
                  newCategory: choice.newName,
                  amount: parseAmount(amount.text),
                  accountId: account,
                  day: int.tryParse(enDigits(day.text.trim())) ?? 1,
                  active: active,
                );
                if (dc.mounted) Navigator.pop(dc);
              } catch (e) {
                set(() => error = _msg(e));
              }
            },
            child: const Text('ذخیره'),
          ),
        ],
      ),
    ),
  );
}

class RecurringTab extends StatelessWidget {
  const RecurringTab({super.key, required this.repo});
  final Repo repo;

  @override
  Widget build(BuildContext context) {
    final canEdit = AccessScope.of(context).canEdit('transactions');
    final now = Jalali.now();
    return RepoBuilder<(List<RecurringExpense>, Map<String, String>, Map<String, String>)>(
      repo: repo,
      load: () async => (await repo.recurringExpenses(), {for (final c in await repo.categories()) c.id: c.name}, {for (final a in await repo.accounts()) a.id: a.name}),
      builder: (c, data) {
        final (list, cats, accs) = data;
        final due = [for (final r in list) if (r.active && !r.postedFor(now.year, now.month)) r];
        Future<void> post(RecurringExpense r) async {
          try {
            var force = false;
            if (r.postedFor(now.year, now.month)) {
              if (!await confirm(c, '«${r.title}» برای این ماه ثبت شده است. دوباره ثبت شود؟')) return;
              force = true;
            }
            await repo.postRecurring(r.id, now.year, now.month, force: force);
            if (c.mounted) toast(c, '«${r.title}» ثبت شد.');
          } catch (e) {
            if (c.mounted) toast(c, _msg(e));
          }
        }

        return Scaffold(
          body: Constrained(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
              if (due.isNotEmpty && canEdit)
                Card(
                  color: Theme.of(c).colorScheme.tertiaryContainer,
                  child: ListTile(
                    leading: const Icon(Icons.event_repeat),
                    title: Text('${faDigits('${due.length}')} هزینه برای ${monthNames[now.month - 1]} ${faDigits('${now.year}')} ثبت نشده'),
                    subtitle: Text('جمع ${moneyC(due.fold(0, (a, r) => a + r.amount))}'),
                    trailing: FilledButton(
                      onPressed: () async {
                        for (final r in due) {
                          try {
                            await repo.postRecurring(r.id, now.year, now.month);
                          } catch (_) {}
                        }
                        if (c.mounted) toast(c, 'هزینه‌های این ماه ثبت شد.');
                      },
                      child: const Text('ثبت همه'),
                    ),
                  ),
                ),
              gap(),
              if (list.isEmpty)
                emptyState('هنوز هزینهٔ ثابتی تعریف نشده است.\nاجاره، اینترنت و مانند آن را یک بار تعریف کنید تا هر ماه با یک کلیک ثبت شود.')
              else
                Card(
                  child: Column(children: [
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.event_repeat),
                        title: Text(list[i].title, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('${cats[list[i].categoryId] ?? ''} • روز ${faDigits('${list[i].day}')} هر ماه • ${accs[list[i].accountId] ?? ''}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text(money(list[i].amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            if (!list[i].active)
                              StatusChip('غیرفعال', Colors.grey)
                            else
                              list[i].postedFor(now.year, now.month) ? StatusChip('این ماه ثبت شد', Colors.green.shade700) : StatusChip('ثبت‌نشده', Colors.orange.shade800),
                          ]),
                          if (canEdit && list[i].active && !list[i].postedFor(now.year, now.month))
                            IconButton(tooltip: 'ثبت این ماه', icon: const Icon(Icons.check_circle_outline), onPressed: () => post(list[i])),
                        ]),
                        onTap: !canEdit ? null : () => editRecurring(c, repo, item: list[i]),
                      ),
                    ],
                  ]),
                ),
            ]),
          ),
          floatingActionButton: !canEdit ? null : FloatingActionButton.extended(onPressed: () => editRecurring(c, repo), icon: const Icon(Icons.add), label: const Text('هزینهٔ ثابت جدید')),
        );
      },
    );
  }
}
