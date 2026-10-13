import 'package:flutter/material.dart';
import 'package:shamsi_date/shamsi_date.dart';

import '../util/format.dart';

enum PeriodKind { all, year, month }

/// A reporting period chosen on screen: all time, a Jalali year or month.
class PeriodController extends ChangeNotifier {
  PeriodController({this.kind = PeriodKind.month});

  PeriodKind kind;
  int year = Jalali.now().year, month = Jalali.now().month;

  (String?, String?) get range => switch (kind) {
        PeriodKind.all => (null, null),
        PeriodKind.year => jalaliYearRange(year),
        PeriodKind.month => jalaliMonthRange(year, month),
      };

  /// ISO bounds that are always set, for queries that need both ends.
  (String, String) get bounds {
    final (a, b) = range;
    return (a ?? '0000-01-01', b ?? '9999-12-31');
  }

  String get label => switch (kind) {
        PeriodKind.all => 'کل دوران',
        PeriodKind.year => 'سال ${faDigits('$year')}',
        PeriodKind.month => '${monthNames[month - 1]} ${faDigits('$year')}',
      };

  String get key => '$kind$year$month';

  void setKind(PeriodKind k) {
    kind = k;
    notifyListeners();
  }

  void shift(int d) {
    if (kind == PeriodKind.year) {
      year += d;
    } else {
      month += d;
      if (month > 12) { month = 1; year++; }
      if (month < 1) { month = 12; year--; }
    }
    notifyListeners();
  }
}

/// Segmented all/year/month chooser with previous/next arrows.
class PeriodBar extends StatelessWidget {
  const PeriodBar({super.key, required this.controller, this.allowAll = true});
  final PeriodController controller;
  final bool allowAll;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Wrap(spacing: 12, runSpacing: 4, alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<PeriodKind>(
            showSelectedIcon: false,
            segments: [
              if (allowAll) const ButtonSegment(value: PeriodKind.all, label: Text('کل')),
              const ButtonSegment(value: PeriodKind.year, label: Text('سال')),
              const ButtonSegment(value: PeriodKind.month, label: Text('ماه')),
            ],
            selected: {controller.kind},
            onSelectionChanged: (s) => controller.setKind(s.first),
          ),
          if (controller.kind != PeriodKind.all)
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(onPressed: () => controller.shift(-1), icon: const Icon(Icons.chevron_right)),
              SizedBox(width: 130, child: Center(child: Text(controller.label, style: Theme.of(context).textTheme.titleSmall))),
              IconButton(onPressed: () => controller.shift(1), icon: const Icon(Icons.chevron_left)),
            ]),
        ]),
      );
}
