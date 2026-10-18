// Calculator, the calculator of Silica.

import 'dart:io' show Platform;
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:silica_ui/silica_ui.dart';

import 'l10n/app_localizations.dart';
import 'src/app_info.dart';
import 'src/history.dart';
import 'src/metrics.dart';
import 'src/settings.dart';
import 'src/window.dart';

/// `--mode=basic|scientific|programmer` (passed with the embedder's `--dart-arg`): the
/// starting mode; the window size of that mode goes in the embedder's `--size`.
CalcMode parseMode(List<String> args) {
  for (final a in args) {
    if (!a.startsWith('--mode=')) continue;
    final name = a.substring('--mode='.length);
    for (final m in CalcMode.values) {
      if (m.name == name) return m;
    }
  }
  return CalcMode.basic;
}

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // About Calculator and the standard app menu (silica-ui#99).
  SilicaApp.info = appInfo;
  // The toolbar is unified with the window: Ossido draws only the window buttons.
  SilicaWindow.setFullSizeContent(toolbarHeight).ignore();
  // A single-window utility: it quits with its window and comes back in the same place
  // (APP-LC; Ossido remembers where the window was).
  SilicaApp.quitWhenLastWindowCloses = true;
  runApp(
    CalculatorApp(
      mode: parseMode(args),
      history: HistoryStore.forUser(Platform.environment),
      settings: AppSettings.forUser(Platform.environment),
    ),
  );
}

/// The first system language with a translation, otherwise English.
Locale resolveLocale(List<Locale> preferred) {
  for (final locale in preferred) {
    for (final supported in AppLocalizations.supportedLocales) {
      if (supported.languageCode == locale.languageCode) return supported;
    }
  }
  return const Locale('en');
}

class CalculatorApp extends StatefulWidget {
  const CalculatorApp({
    super.key,
    this.locale,
    this.mode = CalcMode.basic,
    this.extra = CalcExtra.none,
    this.history,
    this.settings,
  });

  /// A fixed language (tests); null: the system languages.
  final Locale? locale;

  /// The starting mode.
  final CalcMode mode;

  /// Convert or RPN from the start (basic mode only).
  final CalcExtra extra;

  /// The saved calculations; null keeps them in memory only (tests).
  final HistoryStore? history;

  /// What the app keeps between launches; null: nothing (tests).
  final AppSettings? settings;

  @override
  State<CalculatorApp> createState() => _CalculatorAppState();
}

class _CalculatorAppState extends State<CalculatorApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) => setState(() {});

  @override
  Widget build(BuildContext context) => Localizations(
    locale: widget.locale ?? resolveLocale(PlatformDispatcher.instance.locales),
    delegates: AppLocalizations.localizationsDelegates,
    child: Directionality(
      textDirection: TextDirection.ltr,
      // Always dark, with the `App/Calculator` palette; the overlay hosts the Mode menu.
      child: AmalfiTheme(
        brightness: Brightness.dark,
        app: 'Calculator',
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (_) => CalculatorWindow(
                initialMode: widget.mode,
                initialExtra: widget.extra,
                history: widget.history,
                settings: widget.settings,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
