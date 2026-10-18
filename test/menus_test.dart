// Calculator's menus in Silica's menu bar (silica-desktop#25; calculator.md › Menus): the
// model the app publishes on `silica/menu`, the choices that come back and the ⌘ shortcuts.

import 'package:calculator/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silica_ui/silica_ui.dart' show SilicaMenuDelegate;

void main() {
  late List<MethodCall> calls;
  String? clipboard;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(674, 582);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    calls = [];
    clipboard = null;
    tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(SilicaMenuDelegate.defaultChannel, (
        call,
      ) async {
        calls.add(call);
        return true;
      })
      ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        if (call.method == 'Clipboard.getData') return {'text': '1234.5'};
        return null;
      });
    await tester.pumpWidget(const CalculatorApp(locale: Locale('en')));
    await tester.pump();
  }

  List<Map<Object?, Object?>> menus() =>
      ((calls.lastWhere((c) => c.method == 'setMenus').arguments
                  as Map)['menus']
              as List)
          .cast<Map<Object?, Object?>>();

  List<Map<Object?, Object?>> items(String menu) =>
      (menus().firstWhere((m) => m['label'] == menu)['items'] as List)
          .cast<Map<Object?, Object?>>();

  Map<Object?, Object?> item(String menu, String label) =>
      items(menu).firstWhere((i) => i['label'] == label);

  Map<Object?, Object?> role(String menu, String role) =>
      items(menu).firstWhere((i) => i['role'] == role);

  Future<void> choose(WidgetTester tester, Object? id) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SilicaMenuDelegate.defaultChannel.name,
      const JSONMethodCodec().encodeMethodCall(MethodCall('activated', id)),
      (_) {},
    );
    await tester.pump();
  }

  String mainLine(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('main line')),
          matching: find.byType(Text),
        ),
      )
      .first
      .data!;

  Future<void> type(WidgetTester tester, String keys) async {
    for (final k in keys.split('')) {
      final key = switch (k) {
        '=' => LogicalKeyboardKey.enter,
        '/' => LogicalKeyboardKey.slash,
        _ => LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(k)),
      };
      await tester.sendKeyEvent(key, character: k);
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('the menus as measured: app, Edit, View, Window, Help', (
    tester,
  ) async {
    await pump(tester);
    // Help is the standard one (silica-ui#99): the bar gives its title.
    expect(menus().map((m) => m['label']), [
      'Calculator',
      'Edit',
      'View',
      'Window',
      '',
    ]);
    expect(menus().map((m) => m['role']), [
      'app',
      null,
      null,
      'window',
      'help',
    ]);
    // The standard app menu: About enabled, no Settings… (Calculator has none), then the
    // system items (silica-ui#99).
    final app = menus().first['items'] as List;
    expect(
      [for (final i in app.cast<Map<Object?, Object?>>()) i['role'] ?? '—'],
      [
        'about',
        '—',
        'services',
        '—',
        'hide',
        'hide_others',
        'show_all',
        '—',
        'quit',
      ],
    );
    expect((app.first as Map)['enabled'], isTrue);
    expect((app.first as Map)['id'], isA<int>());
    // Edit: Copy and Paste work, the others are there disabled (CA-01).
    final edit = items('Edit').where((i) => i['separator'] != true);
    expect(
      {for (final i in edit) i['role']: i['enabled']},
      {
        'undo': false,
        'redo': false,
        'cut': false,
        'copy': true,
        'paste': true,
        'delete': false,
        'select_all': false,
      },
    );
    // View: the modes with ⌘1–3, Basic checked; Decimal Places 0–15 with 8 checked; full
    // screen disabled (a fixed-size window).
    expect(item('View', 'Basic')['checked'], isTrue);
    expect(item('View', 'Scientific')['shortcut'], {'key': '2', 'meta': true});
    final places = item('View', 'Decimal Places')['items'] as List;
    expect(places.length, 16);
    expect(
      places.cast<Map<Object?, Object?>>().where((p) => p['checked'] == true),
      [containsPair('label', '8')],
    );
    expect(role('View', 'fullscreen')['enabled'], isFalse);
    // Window: Close first; the bar adds the system part.
    expect(items('Window').single, containsPair('role', 'close'));
  });

  testWidgets('choices from the bar and ⌘ shortcuts change the mode', (
    tester,
  ) async {
    await pump(tester);
    await choose(tester, item('View', 'Scientific')['id']);
    expect(find.byKey(const ValueKey('calculator scientific')), findsOneWidget);
    // The checkmark followed.
    expect(item('View', 'Scientific')['checked'], isTrue);
    expect(item('View', 'Basic')['checked'], isNull);
    // ⌘3 and ⌘1, bound by the menu bar inside the app.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('calculator programmer')), findsOneWidget);
    // No decimals in the programmer mode: the decimal items are disabled.
    expect(item('View', 'Decimal Places')['enabled'], isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('calculator basic')), findsOneWidget);
    // ⌘1 was not typed as a digit.
    expect(mainLine(tester), '0');
  });

  testWidgets('decimal places, thousands separators, Copy and Paste', (
    tester,
  ) async {
    await pump(tester);
    await type(tester, '2/3=');
    expect(mainLine(tester), '0.66666667');
    final two = (item('View', 'Decimal Places')['items'] as List)
        .cast<Map<Object?, Object?>>()
        .firstWhere((p) => p['label'] == '2');
    await choose(tester, two['id']);
    expect(mainLine(tester), '0.67');
    await choose(tester, role('Edit', 'copy')['id']);
    await tester.pump();
    expect(clipboard, '0.67');
    await choose(tester, item('View', 'Hide Thousands Separators')['id']);
    await choose(tester, role('Edit', 'paste')['id']);
    await tester.pump();
    expect(mainLine(tester), '1234.5');
    await choose(tester, item('View', 'Show Thousands Separators')['id']);
    expect(mainLine(tester), '1,234.5');
  });
}
