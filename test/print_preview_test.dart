import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:simple_accounting/data/db.dart';
import 'package:simple_accounting/data/repo.dart';
import 'package:simple_accounting/ui/print_dialog.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('print opens a preview first; paper, orientation and report options redraw it; nothing prints by itself', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('acc_prev');
      repo = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
      await repo.init();
    });

    printPreviewBuilderOverride = (key, build, fmt) => FutureBuilder(key: key, future: Future.value(build(fmt)), builder: (_, _) => const Text('PREVIEW'));
    addTearDown(() => printPreviewBuilderOverride = null);
    final built = <(String, bool, bool)>[]; // paper, landscape, option
    var option = false;
    Future<Uint8List> build(settings, PdfPageFormat f) async {
      built.add((settings.paper as String, f.width > f.height, option));
      return Uint8List.fromList(List.filled(10, 1));
    }

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (c) => Scaffold(
          body: TextButton(
            onPressed: () => showPrintDialog(
              c,
              repo,
              title: 'گزارش آزمایشی',
              filename: 'x.pdf',
              build: build,
              options: (c, refresh) => SwitchListTile(title: const Text('گزینهٔ گزارش'), value: option, onChanged: (v) {
                option = v;
                refresh();
              }),
            ),
            child: const Text('چاپ'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('چاپ'));
    await tester.pumpAndSettle();

    // The preview page is what opens; its own "چاپ" button is the only way to print.
    expect(find.textContaining('پیش‌نمایش چاپ'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'چاپ'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'ذخیره / اشتراک PDF'), findsOneWidget);
    expect(find.text('PREVIEW'), findsOneWidget);
    expect(built.isNotEmpty, isTrue);
    expect(built.last, ('a4', false, false));

    await tester.tap(find.text('A5'));
    await tester.pumpAndSettle();
    expect(built.last, ('a5', false, false));
    expect(repo.printSettings.paper, 'a5'); // remembered

    await tester.tap(find.text('افقی'));
    await tester.pumpAndSettle();
    expect(built.last, ('a5', true, false));

    await tester.tap(find.text('گزینهٔ گزارش'));
    await tester.pumpAndSettle();
    expect(built.last, ('a5', true, true));
  });

  testWidgets('thermal roll preview has no paper choice', (tester) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sqfliteFfiInit();
    late Repo repo;
    await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('acc_prev2');
      repo = Repo(await AppDb.open(path: '${dir.path}/x.db', factory: databaseFactoryFfi));
      await repo.init();
    });
    final formats = <PdfPageFormat>[];
    await tester.pumpWidget(MaterialApp(
      home: PrintPreviewPage(
        repo: repo,
        title: 'رسید',
        filename: 'r.pdf',
        roll: true,
        build: (s, f) async {
          formats.add(f);
          return Uint8List(4);
        },
        previewBuilder: (key, build, fmt) => FutureBuilder(key: key, future: Future.value(build(fmt)), builder: (_, _) => const Text('PREVIEW')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('PREVIEW'), findsOneWidget);
    expect(find.text('A5'), findsNothing);
    expect(formats.single.width, closeTo(repo.printSettings.rollWidthMm * PdfPageFormat.mm, 0.01));
  });
}
