/// Column alignment in a printed table. Text columns start at the right edge
/// (Persian), number columns are aligned to the left edge.
enum Col { text, number, center }

class ReportTable {
  ReportTable({
    this.heading,
    required this.headers,
    required this.rows,
    this.totals,
    this.caption = '',
    List<Col>? cols,
    List<double>? flex,
  })  : cols = cols ?? List.filled(headers.length, Col.text),
        flex = flex ?? List.filled(headers.length, 1);

  final String? heading;
  final List<String> headers;
  final List<List<String>> rows;

  /// Optional bold last row.
  final List<String>? totals;

  /// A line (or two) written under the table, e.g. the total in words.
  final String caption;
  final List<Col> cols;
  final List<double> flex;
}

/// Everything a printed report needs; [PdfDocs.report] turns it into a PDF so
/// all reports share one layout (business header, title, summary, tables).
class ReportDoc {
  ReportDoc({
    required this.title,
    this.subtitle = '',
    this.summary = const [],
    this.tables = const [],
    this.footnote = '',
    this.signatures = const [],
    this.closing = '',
  });

  final String title, subtitle, footnote;

  /// Labels of signature boxes at the end (e.g. buyer and seller).
  final List<String> signatures;

  /// A closing line printed centred at the very end.
  final String closing;

  /// Label/value boxes shown above the tables.
  final List<(String, String)> summary;
  final List<ReportTable> tables;
}
