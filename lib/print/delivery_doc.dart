import '../data/repo.dart';
import '../util/format.dart';

/// Everything a delivery receipt (رسید تحویل) shows: no prices, only what was
/// handed over, to whom and, optionally, who signed for it.
class DeliveryDoc {
  DeliveryDoc({
    required this.number,
    required this.date,
    required this.lines,
    this.partyLabel = 'تحویل‌گیرنده',
    this.partyName = '',
    this.phone = '',
    this.address = '',
    this.ref = '',
    this.note = '',
  });

  final String number, date, partyLabel, partyName, phone, address, ref, note;

  /// (title, quantity, unit)
  final List<(String, double, String)> lines;

  /// Receipt for the goods of an invoice. Units come from the product list
  /// because invoice rows do not store one.
  static DeliveryDoc fromInvoice(Invoice inv, List<InvoiceItem> items, Party? party, List<Product> products) {
    final unit = {for (final p in products) p.id: p.unit};
    return DeliveryDoc(
      number: '${inv.number}',
      date: inv.date,
      partyLabel: inv.info.partyLabel,
      partyName: party?.name ?? '',
      phone: party?.phone ?? '',
      ref: 'بابت ${inv.info.label} شمارهٔ ${faDigits('${inv.number}')}',
      note: inv.note,
      lines: [for (final it in items) (it.title, it.qty, unit[it.productId] ?? '')],
    );
  }

  /// Receipt that has no invoice behind it.
  static DeliveryDoc fromDelivery(Delivery d, List<DeliveryItem> items, Party? party) => DeliveryDoc(
        number: '${d.number}',
        date: d.date,
        partyName: d.recipient.isNotEmpty ? d.recipient : (party?.name ?? ''),
        phone: party?.phone ?? '',
        address: d.address,
        note: d.note,
        lines: [for (final it in items) (it.title, it.qty, it.unit)],
      );
}
