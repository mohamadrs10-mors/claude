import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/print/order_docs.dart';
import 'package:simple_accounting/util/format.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

var _n = 0;

Future<Repo> newRepo() async {
  sqfliteFfiInit();
  final dir = Directory.systemTemp.createTempSync('acc_draft');
  final r = Repo(await AppDb.open(path: '${dir.path}/db${_n++}.db', factory: databaseFactoryFfi));
  await r.init();
  return r;
}

void main() {
  test('a draft books nothing; it becomes a real order with the advance when converted; the delivery date is kept', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 1000000);
    final acc = (await r.accounts()).single.id;
    await r.saveParty(name: 'علی');
    final ali = (await r.parties()).single.id;
    final items = [OrderItem('برنج', 100, 1000), OrderItem('روغن', 10, 5000)]; // 150,000

    final did = await r.saveOrder(
      number: 1, date: '2025-03-01', partyId: ali, items: items, percent: 40, advance: 60000, note: 'پیش‌نویس',
      deliveryDate: '2025-03-20', draft: true,
      cheques: [ChequeDraft(amount: 5000, dueDate: '2025-04-01')], // ignored in a draft
    );
    var o = (await r.orders()).single;
    expect((o.isDraft, o.status, o.planned, o.cash, o.advance, o.available, o.total), (true, 'draft', 60000, 0, 0, 0, 150000));
    expect(o.deliveryDate, '2025-03-20');
    // No money moved, no liability, no cheque, the customer owes nothing, and invoices cannot take it.
    expect((await r.accounts()).single.balance, 1000000);
    expect((await r.transactions()).where((t) => t.description.contains('پیش‌دریافت')), isEmpty);
    expect(await r.cheques(), isEmpty);
    expect((await r.parties()).single.balance, 0);
    expect((await r.financialPosition()).advances, 0);
    expect((await r.orders(partyId: ali)).where((x) => x.open), isEmpty);
    expect(o.open, isFalse);

    // Editing a draft keeps it a draft (and can change its figures).
    await r.saveOrder(id: did, number: 1, date: '2025-03-01', partyId: ali, items: [OrderItem('برنج', 100, 1000)], percent: 50, advance: 50000, deliveryDate: '2025-03-25', draft: true);
    o = (await r.orders()).single;
    expect((o.isDraft, o.planned, o.total, o.deliveryDate, o.number), (true, 50000, 100000, '2025-03-25', 1));

    // Turning it into an order: same number and products, the advance is booked now, with a cheque too.
    await r.saveOrder(
      id: did, number: 1, date: '2025-03-02', partyId: ali, items: [OrderItem('برنج', 100, 1000)], percent: 50, advance: 30000, accountId: acc,
      deliveryDate: '2025-03-25', cheques: [ChequeDraft(amount: 20000, dueDate: '2025-04-05', number: '77')],
    );
    o = (await r.orders()).single;
    expect((o.status, o.isDraft, o.open, o.number, o.cash, o.chequeAmount, o.advance, o.planned), ('open', false, true, 1, 30000, 20000, 50000, 0));
    expect((await r.accounts()).single.balance, 1030000);
    expect((await r.cheques()).single.orderId, did);
    expect((await r.financialPosition()).advances, 50000);
    expect((await r.orders(partyId: ali)).where((x) => x.open).length, 1); // invoices can take it now
    expect((await r.parties()).single.balance, 0);

    // The delivery date goes with it; it is late once passed while the order is not fully invoiced.
    expect(o.lateAt('2025-03-24'), isFalse);
    expect(o.lateAt('2025-03-26'), isTrue);
    await r.saveInvoice(number: 1, kind: 'sale', date: '2025-03-10', partyId: ali, discount: 0, note: '', items: [InvoiceItem('برنج', 100, 1000)], orderId: did);
    expect((await r.orders()).single.lateAt('2025-03-26'), isFalse); // fully invoiced: not late

    // A draft can simply be deleted.
    final d2 = await r.saveOrder(number: 2, date: '2025-03-03', partyId: ali, items: [OrderItem('x', 1, 10)], percent: 10, advance: 1, draft: true);
    expect(await r.deleteOrder(d2), isNull);
    expect((await r.orders()).length, 1);
    await expectLater(r.saveOrder(number: 3, date: '2025-03-03', partyId: ali, items: [], percent: 10, advance: 1, draft: true), throwsA(isA<StateError>()));
  });

  test('the printout of a draft and of an order: figures, delivery date, cheques and the draft notice', () async {
    final r = await newRepo();
    await r.saveAccount(name: 'صندوق', kind: 'cash', opening: 0);
    final acc = (await r.accounts()).single.id;
    await r.saveParty(name: 'علی رضایی', phone: '09121234567');
    final ali = (await r.parties()).single;
    await r.saveProduct(name: 'برنج', unit: 'کیسه');
    final prod = (await r.products()).single;
    final did = await r.saveOrder(number: 7, date: '2025-03-01', partyId: ali.id, items: [OrderItem('برنج', 12.5, 20000, productId: prod.id)], percent: 40, advance: 100000, note: 'تحویل در انبار', deliveryDate: '2025-03-30', draft: true);
    var o = (await r.orders()).single;
    var doc = orderDoc(o, ali, const [], {prod.id: 'کیسه'});
    expect(doc.title, contains('پیش‌نویس'));
    expect(doc.subtitle, contains('علی رضایی'));
    final boxes = {for (final (k, v) in doc.summary) k: v};
    expect(boxes['جمع سفارش'], moneyC(250000));
    expect(boxes.keys.any((k) => k.contains('پیش‌دریافت پیشنهادی')), isTrue);
    expect(boxes['مانده بعد از پیش‌دریافت'], moneyC(150000));
    expect(boxes['تاریخ تحویل'], jalaliText('2025-03-30'));
    expect(doc.footnote, contains('قیمت‌های فوق با توجه به نوسانات قیمت متریال و مواد مصرفی تنها ۴۸ ساعت اعتبار دارد'));
    expect(doc.footnote, contains('تحویل در انبار'));
    // The line is editable: another text replaces it, an empty one removes it.
    expect(orderDoc(o, ali, const [], {prod.id: 'کیسه'}, draftFooter: 'اعتبار این برگه ۷۲ ساعت است').footnote, allOf(contains('۷۲ ساعت'), isNot(contains('۴۸ ساعت'))));
    expect(orderDoc(o, ali, const [], {prod.id: 'کیسه'}, draftFooter: '  ').footnote, 'توضیحات: تحویل در انبار');
    final t = doc.tables.single;
    expect(t.rows.single, ['۱', 'برنج', '۱۲.۵۰ کیسه', money(20000), money(250000)]);
    expect(t.rows.every((row) => row.length == t.headers.length), isTrue);
    expect(t.totals!.length, t.headers.length);

    // As an order: the received advance, the cheques table, no draft notice.
    await r.saveOrder(id: did, number: 7, date: '2025-03-01', partyId: ali.id, items: [OrderItem('برنج', 12.5, 20000, productId: prod.id)], percent: 40, advance: 60000, accountId: acc, cheques: [ChequeDraft(amount: 40000, dueDate: '2025-04-01', number: '55', bank: 'ملت')]);
    o = (await r.orders()).single;
    doc = orderDoc(o, ali, await r.cheques(), {prod.id: 'کیسه'});
    expect(doc.title, 'سفارش مشتری');
    expect(doc.footnote, isNot(contains('۴۸ ساعت'))); // the closing line is for drafts only
    expect(doc.tables.length, 2);
    expect(doc.tables[1].rows.single.last, money(40000));
    for (final tb in doc.tables) {
      expect(tb.rows.every((row) => row.length == tb.headers.length), isTrue);
    }
    expect({for (final (k, v) in doc.summary) k: v}['مانده بعد از پیش‌دریافت'], moneyC(150000));
  });
}
