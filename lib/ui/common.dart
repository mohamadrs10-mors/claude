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

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = widget.load();
    });
  }

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
  const AmountField({super.key, required this.controller, this.label = 'مبلغ', this.validator});
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

// ---- shared building blocks ------------------------------------------------

/// Rounded search box used above lists.
class SearchBox extends StatelessWidget {
  const SearchBox({super.key, required this.onChanged, this.hint = 'جستجو...'});
  final ValueChanged<String> onChanged;
  final String hint;

  @override
  Widget build(BuildContext context) => TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          isDense: true,
        ),
      );
}

/// Small coloured label such as "تسویه شده".
class StatusChip extends StatelessWidget {
  const StatusChip(this.text, this.color, {super.key});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// Dashboard style metric tile.
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.title, required this.value, required this.icon, required this.color, this.subtitle});
  final String title, value;
  final String? subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(value, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          ]),
        ),
      );
}

/// Titled card used to group content.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.trailing, this.padding = const EdgeInsets.all(16)});
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: padding,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

/// Keeps content readable on very wide windows.
class Constrained extends StatelessWidget {
  const Constrained({super.key, required this.child, this.maxWidth = 980});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child));
}
