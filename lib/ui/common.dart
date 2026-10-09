import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../data/repo.dart';
import '../util/format.dart';

/// Rebuilds with fresh data whenever the repository changes.
class RepoBuilder<T> extends StatefulWidget {
  const RepoBuilder({super.key, required this.repo, required this.load, required this.builder});
  final Repo repo;
  final Future<T> Function() load;
  final Widget Function(BuildContext, T) builder;

  @override
  State<RepoBuilder<T>> createState() => _RepoBuilderState<T>();
}

class _RepoBuilderState<T> extends State<RepoBuilder<T>> {
  late Future<T> _future = widget.load();

  void _reload() => setState(() => _future = widget.load());

  @override
  void initState() {
    super.initState();
    widget.repo.addListener(_reload);
  }

  @override
  void dispose() {
    widget.repo.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _future,
        builder: (c, snap) {
          if (snap.hasError) return Center(child: Text('خطا: ${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return widget.builder(c, snap.data as T);
        },
      );
}

void toast(BuildContext c, String msg) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(msg)));

Future<bool> confirm(BuildContext c, String msg) async =>
    await showDialog<bool>(
      context: c,
      builder: (c) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('بله')),
        ],
      ),
    ) ??
    false;

Widget emptyState(String text) => Center(
    child: Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center)));

/// Amount colour: positive green, negative red.
Color amountColor(BuildContext c, num v) =>
    v > 0 ? Colors.green.shade700 : (v < 0 ? Theme.of(c).colorScheme.error : Theme.of(c).hintColor);

/// Jalali date picker returning an ISO (Gregorian) date string.
class JalaliDateField extends StatelessWidget {
  const JalaliDateField({super.key, required this.iso, required this.onChanged, this.label = 'تاریخ'});
  final String iso;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final r = await showDialog<String>(context: context, builder: (_) => _JalaliPicker(iso));
          if (r != null) onChanged(r);
        },
        child: InputDecorator(
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixIcon: const Icon(Icons.calendar_month)),
          child: Text(jalaliText(iso)),
        ),
      );
}

class _JalaliPicker extends StatefulWidget {
  const _JalaliPicker(this.iso);
  final String iso;
  @override
  State<_JalaliPicker> createState() => _JalaliPickerState();
}

class _JalaliPickerState extends State<_JalaliPicker> {
  late Jalali j = Jalali.fromDateTime(DateTime.parse(widget.iso));

  @override
  Widget build(BuildContext context) {
    final nowY = Jalali.now().year;
    final maxDay = j.monthLength;
    return AlertDialog(
      title: const Text('انتخاب تاریخ'),
      content: Row(mainAxisSize: MainAxisSize.min, children: [
        _dd<int>(j.year, [for (var y = nowY - 10; y <= nowY + 2; y++) y], (y) => faDigits('$y'),
            (y) => setState(() => j = Jalali(y, j.month, j.day.clamp(1, Jalali(y, j.month, 1).monthLength)))),
        const SizedBox(width: 8),
        _dd<int>(j.month, [for (var m = 1; m <= 12; m++) m], (m) => monthNames[m - 1],
            (m) => setState(() => j = Jalali(j.year, m, j.day.clamp(1, Jalali(j.year, m, 1).monthLength)))),
        const SizedBox(width: 8),
        _dd<int>(j.day, [for (var d = 1; d <= maxDay; d++) d], (d) => faDigits('$d'),
            (d) => setState(() => j = Jalali(j.year, j.month, d))),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: () => Navigator.pop(context, isoOf(j.toDateTime())), child: const Text('تأیید')),
      ],
    );
  }

  Widget _dd<T>(T v, List<T> items, String Function(T) label, ValueChanged<T> on) => DropdownButton<T>(
        value: v,
        items: [for (final i in items) DropdownMenuItem(value: i, child: Text(label(i)))],
        onChanged: (x) => on(x as T),
      );
}

/// Digits-only money input that tolerates Persian digits.
class AmountField extends StatelessWidget {
  const AmountField({super.key, required this.controller, this.label = 'مبلغ (تومان)', this.validator});
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        validator: validator,
      );
}

Widget gap([double h = 12]) => SizedBox(height: h);
