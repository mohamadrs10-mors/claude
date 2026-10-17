import 'dart:convert';
import 'dart:math' as math;

import '../util/format.dart';

/// One line of a cost sheet.
///
/// * `amount`  – a fixed amount in the local currency
/// * `fx`      – an amount in a foreign currency, multiplied by [rate]
/// * `percent` – a percentage of all the amount/fx lines (e.g. customs duty)
///
/// For `amount` and `fx` lines, [perUnit] decides whether the value is for the
/// whole batch or for every unit of it (e.g. packaging per piece).
class CostLine {
  CostLine({this.name = '', this.type = 'amount', this.value = 0, this.rate = 1, this.perUnit = false});

  String name;
  String type; // amount | percent | fx
  double value;
  double rate;
  bool perUnit;

  Map<String, Object?> toJson() => {'n': name, 't': type, 'v': value, 'r': rate, 'u': perUnit};

  factory CostLine.fromJson(Map<String, dynamic> j) => CostLine(
        name: (j['n'] ?? '') as String,
        type: (j['t'] ?? 'amount') as String,
        value: ((j['v'] ?? 0) as num).toDouble(),
        rate: ((j['r'] ?? 1) as num).toDouble(),
        perUnit: (j['u'] ?? false) as bool,
      );
}

class CostSheet {
  CostSheet({this.batchQty = 1, this.wastePercent = 0, List<CostLine>? lines, this.note = ''}) : lines = lines ?? [];

  double batchQty;
  double wastePercent;
  List<CostLine> lines;
  String note;

  String linesJson() => jsonEncode([for (final l in lines) l.toJson()]);

  static List<CostLine> linesFromJson(String s) {
    try {
      return [for (final j in jsonDecode(s) as List) CostLine.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      return [];
    }
  }
}

class CostResult {
  CostResult({
    required this.fixedTotal,
    required this.percentTotal,
    required this.batchTotal,
    required this.goodQty,
    required this.unitCost,
    required this.lineTotals,
    required this.valid,
  });

  /// Sum of the amount and foreign-currency lines.
  final double fixedTotal;

  /// Sum of the percentage lines.
  final double percentTotal;

  /// Everything that was spent on the whole batch.
  final double batchTotal;

  /// Units left after wastage.
  final double goodQty;

  /// Final cost of one sellable unit (قیمت تمام‌شده).
  final double unitCost;

  /// Cost of every line for the whole batch, in the same order as the input.
  final List<double> lineTotals;
  final bool valid;
}

/// Final cost of one unit: all costs of the batch divided by the units that
/// survive wastage.
CostResult computeCost(CostSheet s) {
  final qty = s.batchQty;
  final totals = <double>[];
  var fixed = 0.0;
  for (final l in s.lines) {
    if (l.type == 'percent') {
      totals.add(0);
      continue;
    }
    final base = l.type == 'fx' ? l.value * l.rate : l.value;
    final t = l.perUnit ? base * qty : base;
    totals.add(t);
    fixed += t;
  }
  var percent = 0.0;
  for (var i = 0; i < s.lines.length; i++) {
    if (s.lines[i].type == 'percent') {
      totals[i] = fixed * s.lines[i].value / 100;
      percent += totals[i];
    }
  }
  final good = qty * (1 - s.wastePercent / 100);
  final ok = qty > 0 && good > 0;
  final total = fixed + percent;
  return CostResult(
    fixedTotal: fixed,
    percentTotal: percent,
    batchTotal: total,
    goodQty: ok ? good : 0,
    unitCost: ok ? total / good : 0,
    lineTotals: totals,
    valid: ok,
  );
}

/// Price formulas. Every function returns null when the inputs make no sense
/// (e.g. a 100 % margin) so the UI can show a dash instead of Infinity.
class Pricing {
  /// Cost plus a percentage of the cost (markup).
  static double markup(double cost, double percent) => cost * (1 + percent / 100);

  /// Price such that [percent] of the price is profit (gross margin).
  static double? margin(double cost, double percent) => percent >= 100 ? null : cost / (1 - percent / 100);

  static double fixedProfit(double cost, double profit) => cost + profit;

  /// Profit, margin and markup of a chosen price.
  static ({double profit, double? margin, double? markup}) analyze(double cost, double price) => (
        profit: price - cost,
        margin: price == 0 ? null : (price - cost) / price * 100,
        markup: cost == 0 ? null : (price - cost) / cost * 100,
      );

  static double addVat(double price, double vat) => price * (1 + vat / 100);

  static double? removeVat(double priceWithVat, double vat) => vat <= -100 ? null : priceWithVat / (1 + vat / 100);

  /// List price that still gives a [markupPercent] profit after a
  /// [discountPercent] discount is given to the customer.
  static double? listPrice(double cost, double markupPercent, double discountPercent) =>
      discountPercent >= 100 ? null : markup(cost, markupPercent) / (1 - discountPercent / 100);

  /// Units to sell to cover [fixedCosts] when each unit earns price − variable cost.
  static double? breakEvenQty(double fixedCosts, double price, double variableCost) =>
      price <= variableCost ? null : fixedCosts / (price - variableCost);

  /// New average cost after buying [newQty] units at [newCost] on top of
  /// [stock] units that cost [oldCost] each.
  static double? weightedAverage(double stock, double oldCost, double newQty, double newCost) {
    final q = math.max(stock, 0) + newQty;
    return q <= 0 ? null : (math.max(stock, 0) * oldCost + newQty * newCost) / q;
  }

  /// Rounds [v] up to a multiple of [step] (0 = no rounding).
  static double roundUp(double v, double step) => step <= 0 ? v : (v / step).ceilToDouble() * step;
}

/// A small, safe expression language for custom price formulas:
/// numbers, + - * / ^, parentheses, `25%`, variables and a few functions
/// (round, ceil, floor, abs, sqrt, min, max). No code is ever executed.
class Expr {
  static const functions = {'round', 'ceil', 'floor', 'abs', 'sqrt', 'min', 'max', 'if'};

  static double evaluate(String source, Map<String, double> vars) {
    final p = _Parser(_normalize(source), vars);
    final v = p.parse();
    if (v.isNaN || v.isInfinite) throw const FormatException('نتیجه قابل محاسبه نیست (تقسیم بر صفر؟)');
    return v;
  }

  /// Accepts Persian digits/operators so the user can type naturally.
  static String _normalize(String s) => enDigits(s)
      .replaceAll('×', '*')
      .replaceAll('÷', '/')
      .replaceAll('٪', '%')
      .replaceAll('٫', '.')
      .replaceAll('،', ',')
      .replaceAll('−', '-')
      .replaceAll(RegExp(r'(?<=\d),(?=\d{3}(\D|$))'), ''); // 1,250,000 -> 1250000
}

class _Parser {
  _Parser(this.s, this.vars);
  final String s;
  final Map<String, double> vars;
  int i = 0;

  Never _fail(String m) => throw FormatException(m);

  void _ws() {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
  }

  bool _eat(String c) {
    _ws();
    if (i < s.length && s[i] == c) {
      i++;
      return true;
    }
    return false;
  }

  double parse() {
    final v = _expr();
    _ws();
    if (i < s.length) _fail('کاراکتر نامعتبر «${s[i]}»');
    return v;
  }

  bool _eatStr(String t) {
    _ws();
    if (s.startsWith(t, i)) {
      i += t.length;
      return true;
    }
    return false;
  }

  /// Comparisons (> < >= <= == !=) give 1 or 0, so `if(hours > 160, 1.5, 1)` works.
  double _expr() {
    final v = _sum();
    if (_eatStr('>=')) return v >= _sum() ? 1 : 0;
    if (_eatStr('<=')) return v <= _sum() ? 1 : 0;
    if (_eatStr('==')) return v == _sum() ? 1 : 0;
    if (_eatStr('!=')) return v != _sum() ? 1 : 0;
    if (_eatStr('>')) return v > _sum() ? 1 : 0;
    if (_eatStr('<')) return v < _sum() ? 1 : 0;
    return v;
  }

  double _sum() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _unary();
    while (true) {
      if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        v /= _unary();
      } else {
        return v;
      }
    }
  }

  // Unary minus binds weaker than ^, so -2 ^ 2 is -4 as in maths.
  double _unary() {
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  double _power() {
    final base = _postfix();
    if (_eat('^')) return math.pow(base, _unary()).toDouble();
    return base;
  }

  double _postfix() {
    var v = _primary();
    while (_eat('%')) {
      v /= 100;
    }
    return v;
  }

  double _primary() {
    _ws();
    if (i >= s.length) _fail('عبارت ناقص است');
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) _fail('پرانتز بسته نشده است');
      return v;
    }
    final num = RegExp(r'\d+(\.\d+)?|\.\d+').matchAsPrefix(s, i);
    if (num != null) {
      i = num.end;
      return double.parse(num[0]!);
    }
    final id = RegExp(r'[A-Za-z_][A-Za-z_0-9]*').matchAsPrefix(s, i);
    if (id != null) {
      i = id.end;
      final name = id[0]!.toLowerCase();
      if (_eat('(')) {
        final args = <double>[];
        if (!_eat(')')) {
          do {
            args.add(_expr());
          } while (_eat(','));
          if (!_eat(')')) _fail('پرانتز تابع بسته نشده است');
        }
        return _call(name, args);
      }
      final v = vars[name];
      if (v == null) _fail('متغیر ناشناخته «$name»');
      return v;
    }
    _fail('کاراکتر نامعتبر «${s[i]}»');
  }

  double _call(String f, List<double> a) {
    void need(int n) {
      if (a.length != n) _fail('تابع $f باید $n ورودی داشته باشد');
    }

    switch (f) {
      case 'round':
        if (a.length == 2) return (a[0] / a[1]).roundToDouble() * a[1]; // round(x, step)
        need(1);
        return a[0].roundToDouble();
      case 'ceil':
        if (a.length == 2) return (a[0] / a[1]).ceilToDouble() * a[1];
        need(1);
        return a[0].ceilToDouble();
      case 'floor':
        if (a.length == 2) return (a[0] / a[1]).floorToDouble() * a[1];
        need(1);
        return a[0].floorToDouble();
      case 'abs':
        need(1);
        return a[0].abs();
      case 'sqrt':
        need(1);
        return math.sqrt(a[0]);
      case 'if':
        need(3);
        return a[0] != 0 ? a[1] : a[2]; // if(condition, then, else)
      case 'min':
        if (a.length < 2) _fail('تابع min حداقل دو ورودی می‌خواهد');
        return a.reduce(math.min);
      case 'max':
        if (a.length < 2) _fail('تابع max حداقل دو ورودی می‌خواهد');
        return a.reduce(math.max);
    }
    _fail('تابع ناشناخته «$f»');
  }
}
