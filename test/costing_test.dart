import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/costing.dart';

void main() {
  group('computeCost', () {
    test('sums lines, applies percent lines and wastage', () {
      final r = computeCost(CostSheet(batchQty: 100, wastePercent: 5, lines: [
        CostLine(name: 'مواد', value: 1000000),
        CostLine(name: 'دستمزد', value: 200000),
        CostLine(name: 'بسته‌بندی', value: 500, perUnit: true), // 50,000 for the batch
        CostLine(name: 'ارزی', type: 'fx', value: 10, rate: 50000), // 500,000
        CostLine(name: 'گمرک', type: 'percent', value: 10), // 10% of 1,750,000
      ]));
      expect(r.fixedTotal, 1750000);
      expect(r.percentTotal, 175000);
      expect(r.batchTotal, 1925000);
      expect(r.goodQty, 95);
      expect(r.unitCost, closeTo(1925000 / 95, 1e-9));
      expect(r.lineTotals, [1000000, 200000, 50000, 500000, 175000]);
    });

    test('zero quantity or 100% waste is invalid', () {
      expect(computeCost(CostSheet(batchQty: 0, lines: [CostLine(value: 10)])).valid, isFalse);
      expect(computeCost(CostSheet(batchQty: 5, wastePercent: 100, lines: [CostLine(value: 10)])).unitCost, 0);
    });
  });

  group('Pricing', () {
    test('markup, margin and profit', () {
      expect(Pricing.markup(1000, 25), 1250);
      expect(Pricing.margin(1000, 20), 1250); // 250 is 20% of 1250
      expect(Pricing.margin(1000, 100), isNull);
      expect(Pricing.fixedProfit(1000, 300), 1300);
      final a = Pricing.analyze(1000, 1250);
      expect(a.profit, 250);
      expect(a.margin, closeTo(20, 1e-9));
      expect(a.markup, closeTo(25, 1e-9));
    });

    test('vat, discount, break-even, average cost, rounding', () {
      expect(Pricing.addVat(1000, 10), closeTo(1100, 1e-9));
      expect(Pricing.removeVat(1100, 10), closeTo(1000, 1e-9));
      // 25% markup and a 20% discount: list = 1250 / 0.8
      expect(Pricing.listPrice(1000, 25, 20), closeTo(1562.5, 1e-9));
      expect(Pricing.breakEvenQty(100000, 1500, 1000), 200);
      expect(Pricing.breakEvenQty(100000, 900, 1000), isNull);
      expect(Pricing.weightedAverage(10, 100, 30, 200), 175);
      expect(Pricing.weightedAverage(-5, 100, 10, 200), 200); // negative stock ignored
      expect(Pricing.roundUp(12345, 1000), 13000);
      expect(Pricing.roundUp(12345, 0), 12345);
    });
  });

  group('Expr', () {
    final vars = {'cost': 1000.0, 'qty': 4.0, 'vat': 10.0};

    test('arithmetic, precedence and percent', () {
      expect(Expr.evaluate('1 + 2 * 3', vars), 7);
      expect(Expr.evaluate('(1 + 2) * 3', vars), 9);
      expect(Expr.evaluate('2 ^ 3 ^ 2', vars), 512);
      expect(Expr.evaluate('-2 ^ 2', vars), -4);
      expect(Expr.evaluate('cost * (1 + 25%)', vars), 1250);
      expect(Expr.evaluate('cost*(1+vat%)', vars), closeTo(1100, 1e-9));
    });

    test('functions and persian input', () {
      expect(Expr.evaluate('round(cost / 3)', vars), 333);
      expect(Expr.evaluate('ceil(1234, 100)', vars), 1300);
      expect(Expr.evaluate('max(cost, 5000, 20)', vars), 5000);
      expect(Expr.evaluate('min(cost, qty)', vars), 4);
      expect(Expr.evaluate('sqrt(16) + abs(-2)', vars), 6);
      expect(Expr.evaluate('۱٬۵۰۰ × ۲'.replaceAll('٬', ','), vars), 3000);
      expect(Expr.evaluate('1,250,000 + 5', vars), 1250005);
      expect(Expr.evaluate('COST * 2', vars), 2000);
    });

    test('errors are reported, never thrown as crashes', () {
      for (final bad in ['1 +', '(1', 'foo * 2', '2 # 3', 'round()', 'cost / 0', 'xyz(1)', '']) {
        expect(() => Expr.evaluate(bad, vars), throwsFormatException, reason: bad);
      }
    });
  });
}
