import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../util/format.dart';
import 'common.dart';
import 'transactions_page.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key, required this.repo, required this.onNavigate});
  final Repo repo;

  /// Switches the main navigation to the page with the given id.
  final void Function(String id) onNavigate;

  @override
  Widget build(BuildContext context) => RepoBuilder<Dashboard>(
        repo: repo,
        load: repo.dashboard,
        builder: (c, d) {
          final scheme = Theme.of(c).colorScheme;
          final green = Colors.green.shade600;
          final red = scheme.error;
          final stats = [
            StatCard(title: 'موجودی حساب‌ها', value: moneyC(d.totalBalance), icon: Icons.account_balance_wallet_outlined, color: scheme.primary),
            StatCard(title: 'دریافتی این ماه', value: moneyC(d.monthIncome), icon: Icons.south_west, color: green),
            StatCard(title: 'پرداختی این ماه', value: moneyC(d.monthExpense), icon: Icons.north_east, color: red),
            StatCard(title: 'طلب از اشخاص', value: moneyC(d.receivable), icon: Icons.trending_up, color: Colors.teal),
            StatCard(title: 'بدهی به اشخاص', value: moneyC(d.payable), icon: Icons.trending_down, color: Colors.orange.shade800),
          ];
          return Scaffold(
            body: Constrained(
              maxWidth: 1100,
              child: LayoutBuilder(builder: (c, box) {
                final cols = box.maxWidth > 900 ? 3 : (box.maxWidth > 560 ? 2 : 1);
                final w = (box.maxWidth - 32 - 12 * (cols - 1)) / cols;
                return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                  Wrap(spacing: 12, runSpacing: 12, children: [for (final s in stats) SizedBox(width: w, child: s)]),
                  const SizedBox(height: 16),
                  Section(
                    title: 'دریافت و پرداخت ۶ ماه اخیر',
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      _legend(green, 'دریافت'),
                      const SizedBox(width: 12),
                      _legend(red, 'پرداخت'),
                    ]),
                    child: SizedBox(
                      height: 200,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _BarsPainter(d.months, green, red, Theme.of(c).textTheme.bodySmall!.color!, scheme.outlineVariant),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    if (d.overdue.isNotEmpty)
                      SizedBox(
                        width: box.maxWidth - 32,
                        child: Section(
                          title: 'فاکتورهای سررسیدگذشته (${faDigits('${d.overdue.length}')})',
                          trailing: TextButton(onPressed: () => onNavigate('invoices'), child: const Text('فاکتورها')),
                          child: Column(children: [
                            for (final i in d.overdue.take(6))
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                leading: Icon(Icons.schedule, color: red),
                                title: Text('${i.info.label} ${faDigits('${i.number}')} • ${d.names[i.partyId] ?? ''}'),
                                subtitle: Text('سررسید ${faDigits(jalaliText(i.dueDate!))}'),
                                trailing: Text(moneyC(i.remaining), style: TextStyle(color: red, fontWeight: FontWeight.w700)),
                              ),
                          ]),
                        ),
                      ),
                    SizedBox(
                      width: cols == 1 ? box.maxWidth - 32 : (box.maxWidth - 44) / 2,
                      child: Section(
                        title: 'چک‌های نزدیک سررسید',
                        trailing: TextButton(onPressed: () => onNavigate('cheques'), child: const Text('همه')),
                        child: d.dueCheques.isEmpty
                            ? const Text('چک سررسیدشده یا نزدیک سررسید وجود ندارد.')
                            : Column(children: [
                                for (final x in d.dueCheques.take(5))
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    leading: Icon(x.kind == 'received' ? Icons.south_west : Icons.north_east,
                                        color: x.kind == 'received' ? green : red),
                                    title: Text(moneyC(x.amount)),
                                    subtitle: Text('سررسید ${jalaliText(x.dueDate)}${x.dueDate.compareTo(todayIso()) < 0 ? ' (گذشته)' : ''}'),
                                  ),
                              ]),
                      ),
                    ),
                    SizedBox(
                      width: cols == 1 ? box.maxWidth - 32 : (box.maxWidth - 44) / 2,
                      child: Section(
                        title: 'هشدار موجودی کالا',
                        trailing: TextButton(onPressed: () => onNavigate('products'), child: const Text('انبار')),
                        child: d.lowStock.isEmpty
                            ? const Text('همهٔ کالاها موجودی کافی دارند.')
                            : Column(children: [
                                for (final p in d.lowStock.take(5))
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                                    title: Text(p.name),
                                    trailing: Text('${qtyText0(p.stock)} ${p.unit}'),
                                  ),
                              ]),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Section(
                    title: 'آخرین تراکنش‌ها',
                    trailing: TextButton(onPressed: () => onNavigate('transactions'), child: const Text('همه')),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: d.recent.isEmpty
                        ? const Text('هنوز تراکنشی ثبت نشده است.')
                        : Column(children: [
                            for (final t in d.recent)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(txIcon(t.kind), color: t.kind == 'receipt' ? green : (t.kind == 'transfer' ? Colors.blueGrey : red)),
                                title: Text('${txKindLabel(t.kind)} ${moneyC(t.amount)}'),
                                subtitle: Text([
                                  jalaliText(t.date),
                                  d.names[t.partyId] ?? d.names[t.accountId] ?? '',
                                  if (t.description.isNotEmpty) t.description,
                                ].where((s) => s.isNotEmpty).join(' • ')),
                              ),
                          ]),
                  ),
                  const SizedBox(height: 16),
                  Wrap(spacing: 10, runSpacing: 10, children: [
                    FilledButton.icon(
                        onPressed: () => editTx(c, repo, kind: 'receipt'),
                        icon: const Icon(Icons.south_west),
                        label: const Text('ثبت دریافت')),
                    FilledButton.tonalIcon(
                        onPressed: () => editTx(c, repo, kind: 'payment'),
                        icon: const Icon(Icons.north_east),
                        label: const Text('ثبت پرداخت')),
                    OutlinedButton.icon(
                        onPressed: () => onNavigate('new_invoice'),
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: const Text('فاکتور جدید')),
                  ]),
                ]);
              }),
            ),
          );
        },
      );

  static String qtyText0(double q) => faDigits(q == q.roundToDouble() ? '${q.round()}' : q.toStringAsFixed(1));

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 12)),
      ]);
}

/// Grouped bar chart (income vs expense per month) drawn without a chart
/// library. The first month is drawn on the right, matching the RTL layout.
class _BarsPainter extends CustomPainter {
  _BarsPainter(this.data, this.incomeColor, this.expenseColor, this.textColor, this.gridColor);
  final List<(String, int, int)> data;
  final Color incomeColor, expenseColor, textColor, gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 22.0, top = 8.0;
    final h = size.height - bottom - top;
    final maxV = data.fold<int>(1, (m, e) => [m, e.$2, e.$3].reduce((a, b) => a > b ? a : b));
    final grid = Paint()..color = gridColor..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = top + h * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final slot = size.width / data.length;
    final barW = (slot * 0.28).clamp(6.0, 26.0);
    for (var i = 0; i < data.length; i++) {
      final (label, inc, exp) = data[i];
      final cx = size.width - slot * (i + 0.5); // RTL: oldest on the right
      _bar(canvas, cx + 2, barW, h, top, inc, maxV, incomeColor, leftSide: false);
      _bar(canvas, cx - 2, barW, h, top, exp, maxV, expenseColor, leftSide: true);
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(color: textColor, fontSize: 11, fontFamily: 'Vazirmatn')),
        textDirection: TextDirection.rtl,
      )..layout(maxWidth: slot);
      tp.paint(canvas, Offset(cx - tp.width / 2, size.height - bottom + 4));
    }
  }

  void _bar(Canvas canvas, double x, double w, double h, double top, int v, int maxV, Color color, {required bool leftSide}) {
    final bh = v <= 0 ? 0.0 : (h * v / maxV).clamp(2.0, h);
    final r = leftSide ? Rect.fromLTWH(x - w, top + h - bh, w, bh) : Rect.fromLTWH(x, top + h - bh, w, bh);
    canvas.drawRRect(RRect.fromRectAndCorners(r, topLeft: const Radius.circular(5), topRight: const Radius.circular(5)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => old.data != data || old.incomeColor != incomeColor || old.textColor != textColor;
}
