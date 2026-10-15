import 'package:flutter/material.dart';

import '../data/guard.dart';
import '../data/repo.dart';
import '../data/user_admin.dart';
import '../print/report_doc.dart';
import '../util/format.dart';
import 'common.dart';
import 'print_dialog.dart';

/// The activity report (گزارش فعالیت کاربران): who created, changed or deleted
/// what, and who signed in, newest first, with filters and printing.
class ActivityTab extends StatefulWidget {
  const ActivityTab({super.key, required this.admin, required this.users, this.repo});
  final UserAdmin admin;
  final List<UserInfo> users;

  /// Needed for printing.
  final Repo? repo;

  @override
  State<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<ActivityTab> {
  static const _actions = {'create': 'ثبت', 'edit': 'ویرایش', 'delete': 'حذف', 'login': 'ورود', 'logout': 'خروج', 'sync': 'همگام‌سازی'};
  String? userId, action, table, from, to;
  final text = TextEditingController();
  late Future<List<AuditEntry>> future = _load();

  Future<List<AuditEntry>> _load() => widget.admin.audit(userId: userId, action: action, table: table, from: from, to: to, text: text.text, limit: 500);

  void _reload() => setState(() => future = _load());

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  String _when(DateTime t) =>
      '${faDigits(jalaliText(isoOf(t)))}  ${faDigits('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}')}';

  IconData _icon(String a) => switch (a) {
        'create' => Icons.add_circle_outline,
        'edit' => Icons.edit_outlined,
        'delete' => Icons.delete_outline,
        'login' => Icons.login,
        'logout' => Icons.logout,
        _ => Icons.sync,
      };

  Widget _dd<T>(String label, T? value, Map<T, String> items, ValueChanged<T?> on) => SizedBox(
        width: 170,
        child: DropdownButtonFormField<T?>(
          key: ValueKey('$label$value'),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: [DropdownMenuItem<T?>(value: null, child: const Text('همه')), for (final e in items.entries) DropdownMenuItem<T?>(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            on(v);
            _reload();
          },
        ),
      );

  Future<void> _print(List<AuditEntry> list) async {
    final repo = widget.repo;
    if (repo == null) return;
    await printReport(
      context,
      repo,
      ReportDoc(
        title: 'گزارش فعالیت کاربران',
        subtitle: '${from == null ? '' : 'از ${faDigits(jalaliText(from!))} '}${to == null ? '' : 'تا ${faDigits(jalaliText(to!))}'}'.trim(),
        tables: [
          ReportTable(
            headers: const ['زمان', 'کاربر', 'عمل', 'شرح', 'سیستم'],
            cols: const [Col.center, Col.text, Col.center, Col.text, Col.text],
            flex: const [2, 1.5, 1, 4, 2],
            rows: [for (final e in list) [_when(e.at), e.userName, e.actionLabel, e.summary, e.device]],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<AuditEntry>>(
        future: future,
        builder: (c, snap) {
          final list = snap.data ?? const <AuditEntry>[];
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _dd<String>('کاربر', userId, {for (final u in widget.users) u.id: u.display}, (v) => userId = v),
                _dd<String>('عمل', action, _actions, (v) => action = v),
                _dd<String>('بخش', table, {for (final e in auditTables.entries) e.key: e.value}, (v) => table = v),
                SizedBox(
                  width: 170,
                  child: from == null
                      ? OutlinedButton.icon(onPressed: () async => _pick(true), icon: const Icon(Icons.event), label: const Text('از تاریخ'))
                      : InputChip(label: Text('از ${faDigits(jalaliText(from!))}'), onPressed: () => _pick(true), onDeleted: () {
                          from = null;
                          _reload();
                        }),
                ),
                SizedBox(
                  width: 170,
                  child: to == null
                      ? OutlinedButton.icon(onPressed: () async => _pick(false), icon: const Icon(Icons.event), label: const Text('تا تاریخ'))
                      : InputChip(label: Text('تا ${faDigits(jalaliText(to!))}'), onPressed: () => _pick(false), onDeleted: () {
                          to = null;
                          _reload();
                        }),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: text,
                    onSubmitted: (_) => _reload(),
                    decoration: InputDecoration(labelText: 'جستجو در شرح', isDense: true, suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _reload)),
                  ),
                ),
                if (widget.repo != null) IconButton(tooltip: 'چاپ', icon: const Icon(Icons.print_outlined), onPressed: list.isEmpty ? null : () => _print(list)),
              ]),
            ),
            Expanded(
              child: snap.connectionState != ConnectionState.done
                  ? const Center(child: CircularProgressIndicator())
                  : snap.hasError
                      ? Center(child: Text('خطا: ${snap.error}'))
                      : list.isEmpty
                          ? emptyState('فعالیتی ثبت نشده است.')
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: list.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final e = list[i];
                                return ListTile(
                                  dense: true,
                                  leading: Icon(_icon(e.action), color: e.action == 'delete' ? Theme.of(context).colorScheme.error : null),
                                  title: Text('${e.actionLabel}${e.summary.isEmpty ? '' : ' • ${e.summary}'}'),
                                  subtitle: Text('${e.userName} • ${_when(e.at)}${e.device.isEmpty ? '' : ' • ${e.device}'}'),
                                );
                              },
                            ),
            ),
          ]);
        },
      );

  Future<void> _pick(bool isFrom) async {
    final r = await showDialog<String>(context: context, builder: (_) => JalaliPickerDialog(isoOf(DateTime.now())));
    if (r == null) return;
    if (isFrom) {
      from = r;
    } else {
      to = r;
    }
    _reload();
  }
}
