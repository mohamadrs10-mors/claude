import '../data/repo.dart';
import '../util/format.dart';
import 'report_doc.dart';

/// Turns on-screen report data into a [ReportDoc] so every report can be
/// printed with the same layout.

String _q(double q) => numText(q);

const _statusLabel = {'pending': 'در انتظار', 'cleared': 'وصول شده', 'bounced': 'برگشتی'};

ReportDoc monthlyDoc(MonthReport r, String period) => ReportDoc(
      title: 'گزارش درآمد و هزینه',
      subtitle: period,
      summary: [('دریافتی‌ها', moneyC(r.income)), ('پرداختی‌ها', moneyC(r.expense)), ('خالص', moneyC(r.net))],
      tables: [
        ReportTable(
          heading: 'به تفکیک دسته‌بندی',
          headers: const ['دسته‌بندی', 'نوع', 'مبلغ'],
          cols: const [Col.text, Col.center, Col.number],
          flex: const [3, 1.2, 2],
          rows: [for (final (name, kind, total) in r.byCategory) [name, kind == 'receipt' ? 'دریافت' : 'پرداخت', money(total)]],
          totals: ['جمع دریافتی منهای پرداختی', '', money(r.net)],
        ),
      ],
    );

ReportDoc productSalesDoc(List<ProductSales> sales, List<Product> products, String period) {
  final revenue = sales.fold<int>(0, (a, s) => a + s.revenue);
  final stockValue = products.fold<double>(0, (a, p) => a + (p.stock > 0 ? p.stock * p.buyPrice : 0));
  return ReportDoc(
    title: 'گزارش فروش کالا',
    subtitle: period,
    summary: [('فروش خالص', moneyC(revenue)), ('ارزش فعلی انبار', moneyC(stockValue.round()))],
    tables: [
      ReportTable(
        headers: const ['ردیف', 'کالا', 'تعداد', 'مبلغ فروش'],
        cols: const [Col.center, Col.text, Col.number, Col.number],
        flex: const [0.7, 3.5, 1.4, 2],
        rows: [
          for (var i = 0; i < sales.length; i++) [faDigits('${i + 1}'), sales[i].name, '${_q(sales[i].qty)} ${sales[i].unit}'.trim(), money(sales[i].revenue)],
        ],
        totals: ['', 'جمع', '', money(revenue)],
      ),
    ],
    footnote: 'برگشت از فروش کسر شده است.',
  );
}

ReportDoc partyBalancesDoc(List<Party> parties) {
  final debtors = parties.where((p) => p.balance > 0).toList()..sort((a, b) => b.balance.compareTo(a.balance));
  final creditors = parties.where((p) => p.balance < 0).toList()..sort((a, b) => a.balance.compareTo(b.balance));
  ReportTable table(String heading, List<Party> list) => ReportTable(
        heading: heading,
        headers: const ['ردیف', 'نام', 'تلفن', 'مانده'],
        cols: const [Col.center, Col.text, Col.text, Col.number],
        flex: const [0.7, 3, 2, 2],
        rows: [for (var i = 0; i < list.length; i++) [faDigits('${i + 1}'), list[i].name, faDigits(list[i].phone), money(list[i].balance.abs())]],
        totals: ['', 'جمع', '', money(list.fold<int>(0, (a, p) => a + p.balance.abs()))],
      );
  return ReportDoc(
    title: 'بدهکاران و بستانکاران',
    subtitle: 'تا امروز',
    tables: [table('بدهکاران (طلب ما)', debtors), table('بستانکاران (بدهی ما)', creditors)],
    footnote: 'مبالغ بر حسب $currencyLabel.',
  );
}

ReportDoc buyersDoc(Product p, List<PartySales> rows, String period) {
  final total = rows.fold<int>(0, (a, r) => a + r.revenue);
  return ReportDoc(
    title: 'فروش «${p.name}» به تفکیک اشخاص',
    subtitle: 'بازه: $period',
    summary: [
      ('کل فروش', moneyC(total)),
      ('تعداد فروخته‌شده', '${_q(rows.fold<double>(0, (a, r) => a + r.qty))} ${p.unit}'),
      ('تعداد خریداران', faDigits('${rows.length}')),
    ],
    tables: [
      ReportTable(
        headers: ['ردیف', 'نام شخص', 'تعداد (${p.unit})', 'فاکتور', 'مبلغ فروش', 'سهم'],
        cols: const [Col.center, Col.text, Col.number, Col.center, Col.number, Col.number],
        flex: const [0.7, 3, 1.4, 1, 1.8, 1],
        rows: [
          for (var i = 0; i < rows.length; i++)
            [
              faDigits('${i + 1}'),
              rows[i].name,
              _q(rows[i].qty),
              faDigits('${rows[i].invoices}'),
              money(rows[i].revenue),
              total > 0 ? '${numText(rows[i].revenue * 100 / total, 1)}٪' : '',
            ],
        ],
        totals: ['', 'جمع کل', _q(rows.fold<double>(0, (a, r) => a + r.qty)), faDigits('${rows.fold<int>(0, (a, r) => a + r.invoices)}'), money(total), ''],
      ),
    ],
    footnote: 'برگشت از فروش کسر شده است؛ تخفیف و مالیات کل فاکتور در مبلغ‌ها نیست.',
  );
}

ReportDoc transactionsDoc(List<Tx> txs, {required Map<String, String> accounts, required Map<String, String> parties, required Map<String, String> categories, String filter = ''}) {
  final receipts = txs.where((t) => t.kind == 'receipt').fold<int>(0, (a, t) => a + t.amount);
  final payments = txs.where((t) => t.kind == 'payment').fold<int>(0, (a, t) => a + t.amount);
  String account(Tx t) => t.kind == 'transfer'
      ? 'از ${accounts[t.accountId] ?? ''} به ${accounts[t.toAccountId] ?? ''}'
      : (accounts[t.accountId] ?? '');
  return ReportDoc(
    title: 'فهرست تراکنش‌ها',
    subtitle: filter,
    summary: [('جمع دریافت', moneyC(receipts)), ('جمع پرداخت', moneyC(payments)), ('تفاضل', moneyC(receipts - payments))],
    tables: [
      ReportTable(
        headers: const ['تاریخ', 'نوع', 'حساب', 'شخص', 'دسته‌بندی', 'توضیحات', 'مبلغ'],
        cols: const [Col.center, Col.center, Col.text, Col.text, Col.text, Col.text, Col.number],
        flex: const [1.3, 1, 1.6, 1.8, 1.5, 2.4, 1.8],
        rows: [
          for (final t in txs)
            [
              jalaliText(t.date),
              txKindLabel(t.kind),
              account(t),
              parties[t.partyId] ?? '',
              categories[t.categoryId] ?? '',
              t.description,
              money(t.amount),
            ],
        ],
      ),
    ],
  );
}

ReportDoc invoicesDoc(List<Invoice> list, Map<String, String> names, {String filter = ''}) {
  final total = list.fold<int>(0, (a, i) => a + i.total);
  final remaining = list.fold<int>(0, (a, i) => a + i.remaining);
  return ReportDoc(
    title: 'فهرست فاکتورها',
    subtitle: filter,
    summary: [('جمع مبلغ فاکتورها', moneyC(total)), ('جمع مانده', moneyC(remaining))],
    tables: [
      ReportTable(
        headers: const ['شماره', 'نوع', 'تاریخ', 'شخص', 'مبلغ', 'مانده'],
        cols: const [Col.center, Col.text, Col.center, Col.text, Col.number, Col.number],
        flex: const [0.9, 1.8, 1.4, 2.6, 1.8, 1.6],
        rows: [
          for (final i in list) [faDigits('${i.number}'), i.info.label, jalaliText(i.date), names[i.partyId] ?? '', money(i.total), money(i.remaining)],
        ],
        totals: ['', '', '', 'جمع', money(total), money(remaining)],
      ),
    ],
    footnote: 'فاکتورهای برگشتی هم با مبلغ مثبت در فهرست آمده‌اند.',
  );
}

ReportDoc stockDoc(List<Product> products) {
  final value = products.fold<double>(0, (a, p) => a + (p.stock > 0 ? p.stock * p.buyPrice : 0));
  return ReportDoc(
    title: 'گزارش موجودی انبار',
    subtitle: 'تا امروز',
    summary: [('تعداد کالا', faDigits('${products.length}')), ('ارزش انبار (قیمت خرید)', moneyC(value.round()))],
    tables: [
      ReportTable(
        headers: const ['کد', 'کالا', 'موجودی', 'قیمت خرید', 'قیمت فروش', 'ارزش'],
        cols: const [Col.center, Col.text, Col.number, Col.number, Col.number, Col.number],
        flex: const [0.9, 3, 1.6, 1.6, 1.6, 1.9],
        rows: [
          for (final p in products)
            [faDigits(p.code), p.name + (p.low ? ' (کمبود)' : ''), '${_q(p.stock)} ${p.unit}', money(p.buyPrice), money(p.salePrice), money((p.stock > 0 ? p.stock * p.buyPrice : 0).round())],
        ],
        totals: ['', 'جمع', '', '', '', money(value.round())],
      ),
    ],
  );
}

ReportDoc chequesDoc(List<Cheque> list, Map<String, String> names, {required String title}) {
  final pending = list.where((c) => c.status == 'pending').fold<int>(0, (a, c) => a + c.amount);
  return ReportDoc(
    title: title,
    subtitle: 'مرتب بر اساس سررسید',
    summary: [('جمع چک‌های در انتظار', moneyC(pending))],
    tables: [
      ReportTable(
        headers: const ['سررسید', 'شخص', 'بانک', 'شمارهٔ چک', 'وضعیت', 'مبلغ'],
        cols: const [Col.center, Col.text, Col.text, Col.center, Col.center, Col.number],
        flex: const [1.4, 2.4, 1.6, 1.4, 1.3, 1.8],
        rows: [
          for (final c in list) [jalaliText(c.dueDate), names[c.partyId] ?? '', c.bank, faDigits(c.number), _statusLabel[c.status] ?? '', money(c.amount)],
        ],
        totals: ['', '', '', '', 'جمع', money(list.fold<int>(0, (a, c) => a + c.amount))],
      ),
    ],
  );
}

ReportDoc accountsDoc(List<Account> accounts) => ReportDoc(
      title: 'موجودی حساب‌ها',
      subtitle: 'تا امروز',
      tables: [
        ReportTable(
          headers: const ['حساب', 'نوع', 'موجودی اولیه', 'موجودی فعلی'],
          cols: const [Col.text, Col.center, Col.number, Col.number],
          flex: const [3, 1.2, 2, 2],
          rows: [for (final a in accounts) [a.name, a.kind == 'cash' ? 'صندوق' : 'بانک', money(a.opening), money(a.balance)]],
          totals: ['جمع', '', money(accounts.fold<int>(0, (s, a) => s + a.opening)), money(accounts.fold<int>(0, (s, a) => s + a.balance))],
        ),
      ],
    );

// ---- financial reports ------------------------------------------------------

ReportDoc profitLossDoc(ProfitLoss p, String period) => ReportDoc(
      title: 'گزارش سود و زیان',
      subtitle: period,
      summary: [('سود ناخالص', moneyC(p.grossProfit)), ('سود (زیان) خالص', moneyC(p.netProfit))],
      tables: [
        ReportTable(
          headers: const ['شرح', 'مبلغ'],
          cols: const [Col.text, Col.number],
          flex: const [4, 2],
          rows: [
            ['فروش خالص (پس از برگشتی و تخفیف، بدون مالیات)', money(p.sales)],
            ['بهای تمام‌شدهٔ کالای فروش‌رفته', money(-p.cogs)],
            ['سود ناخالص', money(p.grossProfit)],
            for (final (n, v) in p.otherIncomeByCategory) ['درآمد: $n', money(v)],
            for (final (n, v) in p.expensesByCategory) ['هزینه: $n', money(-v)],
          ],
          totals: ['سود (زیان) خالص', money(p.netProfit)],
        ),
      ],
      footnote: 'بهای کالا با قیمت تمام‌شدهٔ برگهٔ هزینه یا میانگین موزون خرید حساب شده است. '
          '${p.unlinkedSales != 0 ? 'فروش اقلامی که به کالا وصل نبوده (${money(p.unlinkedSales)}) بدون بهای تمام‌شده آمده است. ' : ''}'
          '${p.uncategorized != 0 ? 'پرداخت‌های بدون شخص و بدون دسته‌بندی (${money(p.uncategorized)}) در هیچ‌کجا نیامده است.' : ''}',
    );

ReportDoc financialPositionDoc(FinancialPosition f) => ReportDoc(
      title: 'وضعیت مالی (ترازنامهٔ ساده)',
      subtitle: 'تا امروز',
      summary: [('جمع دارایی‌ها', moneyC(f.assets)), ('جمع بدهی‌ها', moneyC(f.liabilities)), ('حقوق صاحبان سرمایه', moneyC(f.equity))],
      tables: [
        ReportTable(
          heading: 'دارایی‌ها',
          headers: const ['شرح', 'مبلغ'],
          cols: const [Col.text, Col.number],
          flex: const [4, 2],
          rows: [
            for (final (n, v) in f.accounts.where((a) => a.$2 > 0)) ['موجودی $n', money(v)],
            ['طلب از اشخاص', money(f.receivables)],
            ['موجودی کالا', money(f.inventory)],
            ['چک‌های دریافتی در انتظار', money(f.chequesReceived)],
          ],
          totals: ['جمع دارایی‌ها', money(f.assets)],
        ),
        ReportTable(
          heading: 'بدهی‌ها',
          headers: const ['شرح', 'مبلغ'],
          cols: const [Col.text, Col.number],
          flex: const [4, 2],
          rows: [
            ['بدهی به اشخاص', money(f.payables)],
            ['چک‌های پرداختی در انتظار', money(f.chequesIssued)],
            if (f.advances > 0) ['پیش‌دریافت از مشتریان (هنوز روی فاکتور نرفته)', money(f.advances)],
            for (final (n, v) in f.accounts.where((a) => a.$2 < 0)) ['برداشت بیش از موجودی $n', money(-v)],
          ],
          totals: ['جمع بدهی‌ها', money(f.liabilities)],
        ),
      ],
      footnote: 'موجودی کالا با قیمت تمام‌شده یا میانگین خرید ارزش‌گذاری شده است. دارایی ثابت و استهلاک در این گزارش نیست.',
    );

ReportDoc vatDoc(VatReport v, String period) => ReportDoc(
      title: 'گزارش مالیات بر ارزش افزوده',
      subtitle: period,
      summary: [
        ('مالیات فروش (دریافتی)', moneyC(v.outputTax)),
        ('مالیات خرید (پرداختی)', moneyC(v.inputTax)),
        (v.payable >= 0 ? 'مالیات قابل پرداخت' : 'مالیات قابل استرداد', moneyC(v.payable.abs())),
      ],
      tables: [
        ReportTable(
          headers: const ['تاریخ', 'سند', 'شخص', 'مبنای مالیات', 'مالیات'],
          cols: const [Col.center, Col.text, Col.text, Col.number, Col.number],
          flex: const [1.3, 2.2, 2.4, 1.8, 1.4],
          rows: [
            for (final l in v.lines) [jalaliText(l.date), '${invoiceKind(l.kind).label} ${faDigits('${l.number}')}', l.party, money(l.base), money(l.tax)],
          ],
          totals: ['', '', 'خالص فروش − خرید', money(v.salesBase - v.purchasesBase), money(v.payable)],
        ),
      ],
      footnote: 'برگشتی‌ها منفی آمده‌اند. این گزارش کمکی است و جایگزین اظهارنامهٔ رسمی نیست.',
    );

ReportDoc ageingDoc(List<AgeingRow> rows) {
  List<int> sum(int i) => [rows.fold(0, (a, r) => a + r.buckets[i])];
  return ReportDoc(
    title: 'سن مطالبات',
    subtitle: 'تا امروز',
    summary: [('جمع مطالبات', moneyC(rows.fold(0, (a, r) => a + r.total)))],
    tables: [
      ReportTable(
        headers: const ['شخص', '۰ تا ۳۰ روز', '۳۱ تا ۶۰', '۶۱ تا ۹۰', 'بیش از ۹۰', 'جمع'],
        cols: const [Col.text, Col.number, Col.number, Col.number, Col.number, Col.number],
        flex: const [2.6, 1.6, 1.4, 1.4, 1.5, 1.8],
        rows: [for (final r in rows) [r.name, for (final b in r.buckets) b == 0 ? '' : money(b), money(r.total)]],
        totals: ['جمع', for (var i = 0; i < 4; i++) money(sum(i).first), money(rows.fold(0, (a, r) => a + r.total))],
      ),
    ],
    footnote: 'پرداخت‌ها به قدیمی‌ترین فاکتورها اختصاص داده شده است؛ مانده اول دوره در ستون «بیش از ۹۰» می‌آید.',
  );
}

ReportDoc ledgerDoc({required String title, required String subtitle, required Ledger ledger, String unit = ''}) {
  String q(num v) => unit.isEmpty ? money(v.round()) : '${numText(v)} $unit';
  return ReportDoc(
    title: title,
    subtitle: subtitle,
    summary: [('مانده ابتدا', q(ledger.opening)), ('جمع ورودی', q(ledger.totalIn)), ('جمع خروجی', q(ledger.totalOut)), ('مانده پایان', q(ledger.closing))],
    tables: [
      ReportTable(
        headers: const ['تاریخ', 'شرح', 'ورودی', 'خروجی', 'مانده'],
        cols: const [Col.center, Col.text, Col.number, Col.number, Col.number],
        flex: const [1.3, 3.6, 1.5, 1.5, 1.7],
        rows: [
          for (final l in ledger.lines)
            [jalaliText(l.date), l.description, l.inAmount == 0 ? '' : (unit.isEmpty ? money(l.inAmount.round()) : numText(l.inAmount)), l.outAmount == 0 ? '' : (unit.isEmpty ? money(l.outAmount.round()) : numText(l.outAmount)), unit.isEmpty ? money(l.balance.round()) : numText(l.balance)],
        ],
        totals: ['', 'جمع', unit.isEmpty ? money(ledger.totalIn.round()) : numText(ledger.totalIn), unit.isEmpty ? money(ledger.totalOut.round()) : numText(ledger.totalOut), unit.isEmpty ? money(ledger.closing.round()) : numText(ledger.closing)],
      ),
    ],
  );
}
