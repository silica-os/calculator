// The calculator window (kit `App · Calculator`, calculator.md › Window and toolbar): always
// dark, fixed size per mode, toolbar 52 pt unified with the window (the compositor draws the
// window buttons), the Mode button, the display and the keypad. Typed keys light the matching
// key; the window goes gray when it is not the active one.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:silica_ui/silica_ui.dart';

import '../l10n/app_localizations.dart';
import 'display.dart';
import 'engine/calculator.dart';
import 'engine/expression.dart';
import 'engine/format.dart';
import 'engine/programmer.dart';
import 'engine/rational.dart';
import 'engine/rpn.dart';
import 'engine/units.dart';
import 'extras.dart';
import 'history.dart';
import 'key_button.dart';
import 'keys.dart';
import 'metrics.dart';
import 'programmer_panel.dart';
import 'settings.dart';

/// Fixes the window to the size of a mode (fixed sizes per mode, calculator.md): the limits
/// and the size together, so the window cannot be resized and the zoom button is disabled.
Future<bool> requestWindowSize(Size size) => SilicaWindow.setFixedSize(size);

class CalculatorWindow extends StatefulWidget {
  const CalculatorWindow({
    super.key,
    this.initialMode = CalcMode.basic,
    this.history,
    this.settings,
    this.initialExtra = CalcExtra.none,
  });

  final CalcMode initialMode;

  /// Convert or RPN from the start (basic mode only).
  final CalcExtra initialExtra;

  /// What the app keeps (the first-launch tip); null: no tip (tests).
  final AppSettings? settings;

  /// The records of the calculations; null keeps them in memory only (tests).
  final HistoryStore? history;

  @override
  State<CalculatorWindow> createState() => CalculatorWindowState();
}

class CalculatorWindowState extends State<CalculatorWindow> {
  late CalcMode mode = widget.initialMode;

  /// Convert or RPN (basic mode only).
  late CalcExtra extra = widget.initialMode == CalcMode.basic
      ? widget.initialExtra
      : CalcExtra.none;
  final RpnCalculator rpn = RpnCalculator();
  UnitCategory convertCategory = UnitCategory.length;
  late ConvertUnit fromUnit = defaultPair(convertCategory).$1;
  late ConvertUnit toUnit = defaultPair(convertCategory).$2;
  final GlobalKey _modeButtonKey = GlobalKey();
  final DecimalCalculator decimal = DecimalCalculator();
  final ProgrammerCalculator programmer = ProgrammerCalculator();
  final KeyFlash _flash = KeyFlash();
  final FocusNode _focus = FocusNode();

  /// Shift held in the scientific mode shows the 2nd functions while it is down.
  bool _shiftSecond = false;

  late final HistoryStore history = widget.history ?? HistoryStore();

  /// The history sidebar is open (⌃⌘S): the window is 220 pt wider and the display and the
  /// keypad shift right. Not in the programmer mode, which has no history.
  bool showHistory = false;

  /// Whether the window is the wide one (with the history column). The window resize itself
  /// is instant: it widens at once when the sidebar opens (the sidebar slides in over it) and
  /// narrows when the sidebar has slid out ([AmalfiSidebarMotion.close] later).
  bool _wideWindow = false;
  Timer? _narrowTimer;
  bool _wasEvaluated = false;

  /// The wall clock: the history groups the records by day.
  DateTime _now() => DateTime.now();

  /// View › Hide Thousands Separators: results and entries without digit grouping.
  bool thousands = true;

  bool _active = _isActive(WidgetsBinding.instance.lifecycleState);
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      final active = _isActive(state);
      if (active != _active) setState(() => _active = active);
    },
  );

  static bool _isActive(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    unawaited(requestWindowSize(_sizeOf(mode, false)));
    rpn.addListener(_changed);
    if (widget.settings case final settings? when !settings.tipShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showTip(settings));
    }
    _wasEvaluated = decimal.evaluated;
    decimal.addListener(_decimalChanged);
    programmer.addListener(_changed);
    history.addListener(_changed);
  }

  @override
  void dispose() {
    _narrowTimer?.cancel();
    _lifecycle.dispose();
    decimal.removeListener(_decimalChanged);
    programmer.removeListener(_changed);
    rpn.removeListener(_changed);
    history.removeListener(_changed);
    _focus.dispose();
    _flash.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  /// A result ("=") goes into the history, once.
  void _decimalChanged() {
    if (decimal.evaluated && !_wasEvaluated) {
      history.add(
        renderTokens(decimal.previous, _style),
        formatNumber(decimal.result, _style, places: decimal.places),
        _now(),
      );
    }
    _wasEvaluated = decimal.evaluated;
    _changed();
  }

  /// The window of [m] with or without the history sidebar.
  Size _sizeOf(CalcMode m, bool history) {
    final base = windowSize[m]!;
    final size = m == CalcMode.basic
        ? Size(base.width, extraHeight[extra]!)
        : base;
    return history && m != CalcMode.programmer
        ? Size(size.width + HistoryMetrics.width, size.height)
        : size;
  }

  /// The first-launch tip over the Mode button (shown once).
  void _showTip(AppSettings settings) {
    if (!mounted) return;
    final box = _modeButtonKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final l = AppLocalizations.of(context);
    settings
      ..tipShown = true
      ..save();
    unawaited(
      showAmalfiPopover(
        context: context,
        anchor: box.localToGlobal(Offset.zero) & box.size,
        builder: (context, dismiss) => AmalfiPopoverText(
          title: l.tipTitle,
          body: l.tipBody,
          action: AmalfiLinkButton(
            key: const ValueKey('tip dismiss'),
            label: l.tipDismiss,
            onPressed: dismiss,
          ),
        ),
      ),
    );
  }

  /// Convert and RPN mode are toggles of the basic mode: choosing one leaves the others.
  void toggleExtra(CalcExtra e) {
    final next = extra == e && mode == CalcMode.basic ? CalcExtra.none : e;
    setState(() {
      mode = CalcMode.basic;
      extra = next;
      if (next == CalcExtra.rpn) showHistory = false;
    });
    _syncWindow();
  }

  void _pickUnit(Rect anchor, bool from) {
    final language = Localizations.localeOf(context).languageCode;
    unawaited(
      showAmalfiPopover(
        context: context,
        anchor: anchor,
        padding: const EdgeInsets.all(12),
        builder: (context, dismiss) => UnitPicker(
          current: from ? fromUnit : toUnit,
          language: language,
          onChosen: (u) {
            dismiss();
            setState(() {
              if (u.category != convertCategory) {
                // Another category: both units follow it.
                convertCategory = u.category;
                final pair = defaultPair(u.category);
                fromUnit = from ? u : pair.$1;
                toUnit = from ? pair.$2 : u;
                if (fromUnit == toUnit)
                  toUnit = pair.$1 == u ? pair.$2 : pair.$1;
              } else if (from) {
                fromUnit = u;
              } else {
                toUnit = u;
              }
            });
          },
        ),
      ),
    );
  }

  /// The swap button: the units trade places and the result becomes the typed value.
  void _swapUnits() {
    final result = _converted();
    setState(() {
      final t = fromUnit;
      fromUnit = toUnit;
      toUnit = t;
    });
    if (result != null) decimal.setValue(result);
  }

  Rational? _converted() {
    if (decimal.error) return null;
    try {
      return Rational.fromDouble(
        convertValue(decimal.currentValue().toDouble(), fromUnit, toUnit),
      );
    } on CalcError {
      return null;
    }
  }

  /// View › Show / Hide History (⌃⌘S) and the toolbar button.
  void toggleHistory() {
    if (mode == CalcMode.programmer) return;
    setState(() => showHistory = !showHistory);
    _syncWindow(slide: true);
  }

  /// Sizes the window to the history state. With [slide], a closing sidebar keeps the wide window
  /// until it has slid out, so the content is not cut off while it moves.
  void _syncWindow({bool slide = false}) {
    _narrowTimer?.cancel();
    _narrowTimer = null;
    final wide = showHistory && mode != CalcMode.programmer;
    if (!wide && slide && _wideWindow) {
      _narrowTimer = Timer(AmalfiSidebarMotion.close, () {
        _narrowTimer = null;
        if (!mounted) return;
        setState(() => _wideWindow = false);
        unawaited(requestWindowSize(_sizeOf(mode, false)));
      });
      return;
    }
    setState(() => _wideWindow = wide);
    unawaited(requestWindowSize(_sizeOf(mode, wide)));
  }

  NumberStyle get _style {
    final style = NumberStyle.forLanguage(
      Localizations.localeOf(context).languageCode,
    );
    return thousands ? style : NumberStyle(decimal: style.decimal, group: '');
  }

  /// View › Hide / Show Thousands Separators (`calculator.thousands`).
  void toggleThousands() => setState(() => thousands = !thousands);

  /// View › Decimal Places (`calculator.decimal_places`).
  void setPlaces(int places) => decimal.setPlaces(places);

  void setMode(CalcMode next) {
    if (next == mode) return;
    // The mode switch is instant: size and keypad change in one frame (silica-reference CA-01).
    setState(() {
      mode = next;
      extra = CalcExtra.none;
    });
    _syncWindow();
  }

  List<List<KeySpec>> _keys(KeyTexts texts) => switch (mode) {
    CalcMode.basic when extra == CalcExtra.rpn => rpnKeys(rpn, _style, texts),
    CalcMode.basic => basicKeys(decimal, _style, texts),
    CalcMode.scientific => scientificKeys(decimal, _style, texts),
    CalcMode.programmer => programmerKeys(programmer, texts),
  };

  Future<void> copy() async {
    final text = mode == CalcMode.programmer
        ? programmer.copyText()
        : extra == CalcExtra.rpn
        ? rpn.copyText(_style, places: decimal.places)
        : decimal.copyText(_style);
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null) return;
    if (mode == CalcMode.programmer) {
      programmer.paste(text);
    } else if (extra == CalcExtra.rpn) {
      rpn.paste(text, _style);
    } else {
      decimal.paste(text, _style);
    }
  }

  /// The key a typed character stands for: its id and what it does.
  (String, VoidCallback)? _typedRpn(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return ('equals', rpn.enter);
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.delete) {
      return ('clear', rpn.clear);
    }
    if (key == LogicalKeyboardKey.backspace)
      return ('backspace', rpn.backspace);
    final ch = event.character;
    if (ch == null || ch.isEmpty) return null;
    if (RegExp(r'^[0-9]$').hasMatch(ch)) return (ch, () => rpn.digit(ch));
    return switch (ch) {
      '.' || ',' => ('decimal', rpn.decimalPoint),
      '+' => ('add', () => rpn.operator(BinOp.add)),
      '-' => ('subtract', () => rpn.operator(BinOp.subtract)),
      '*' || 'x' => ('multiply', () => rpn.operator(BinOp.multiply)),
      '/' || ':' => ('divide', () => rpn.operator(BinOp.divide)),
      '%' => ('percent', rpn.percent),
      '=' => ('equals', rpn.enter),
      _ => null,
    };
  }

  (String, VoidCallback)? _typed(KeyEvent event) {
    if (mode == CalcMode.basic && extra == CalcExtra.rpn) {
      return _typedRpn(event);
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      return (
        'equals',
        mode == CalcMode.programmer ? programmer.equals : decimal.equals,
      );
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.delete) {
      return (
        'clear',
        mode == CalcMode.programmer ? programmer.clear : decimal.clear,
      );
    }
    if (key == LogicalKeyboardKey.backspace) {
      return (
        'backspace',
        mode == CalcMode.programmer ? programmer.backspace : decimal.backspace,
      );
    }
    final ch = event.character;
    if (ch == null || ch.isEmpty) return null;
    if (mode == CalcMode.programmer) {
      final upper = ch.toUpperCase();
      if (programmer.acceptsDigit(upper)) {
        return ('digit $upper', () => programmer.digits(upper));
      }
      return switch (ch) {
        '+' => ('add', () => programmer.operator(ProgOp.add)),
        '-' => ('subtract', () => programmer.operator(ProgOp.subtract)),
        '*' || 'x' => ('multiply', () => programmer.operator(ProgOp.multiply)),
        '/' || ':' => ('divide', () => programmer.operator(ProgOp.divide)),
        '&' => ('and', () => programmer.operator(ProgOp.and)),
        '|' => ('or', () => programmer.operator(ProgOp.or)),
        '^' => ('xor', () => programmer.operator(ProgOp.xor)),
        '~' => ('not', () => programmer.unary(ProgUnary.not)),
        '%' => ('mod', () => programmer.operator(ProgOp.modulo)),
        '(' => ('open', programmer.open),
        ')' => ('close', programmer.close),
        '=' => ('equals', programmer.equals),
        _ => null,
      };
    }
    if (RegExp(r'^[0-9]$').hasMatch(ch)) return (ch, () => decimal.digit(ch));
    return switch (ch) {
      '.' || ',' => ('decimal', decimal.decimalPoint),
      '+' => ('add', () => decimal.operator(BinOp.add)),
      '-' => ('subtract', () => decimal.operator(BinOp.subtract)),
      '*' || 'x' => ('multiply', () => decimal.operator(BinOp.multiply)),
      '/' || ':' => ('divide', () => decimal.operator(BinOp.divide)),
      '%' => ('percent', () => decimal.postfix(Postfix.percent)),
      '=' => ('equals', decimal.equals),
      '^' when mode == CalcMode.scientific => (
        'power',
        () => decimal.operator(BinOp.power),
      ),
      '(' when mode == CalcMode.scientific => ('open', decimal.open),
      ')' when mode == CalcMode.scientific => ('close', decimal.close),
      '!' when mode == CalcMode.scientific => (
        'factorial',
        () => decimal.postfix(Postfix.factorial),
      ),
      _ => null,
    };
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    final shift =
        event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight;
    if (shift && mode == CalcMode.scientific) {
      if (event is KeyDownEvent && !decimal.second) {
        _shiftSecond = true;
        decimal.toggleSecond();
      } else if (event is KeyUpEvent && _shiftSecond) {
        _shiftSecond = false;
        if (decimal.second) decimal.toggleSecond();
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // ⌘ shortcuts are the menu bar's (SilicaMenuBar binds them); Ctrl stays an alternative.
    if (keys.isMetaPressed) return KeyEventResult.ignored;
    if (keys.isControlPressed) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.keyC) {
        unawaited(copy());
      } else if (key == LogicalKeyboardKey.keyV) {
        unawaited(paste());
      } else if (key == LogicalKeyboardKey.digit1) {
        setMode(CalcMode.basic);
      } else if (key == LogicalKeyboardKey.digit2) {
        setMode(CalcMode.scientific);
      } else if (key == LogicalKeyboardKey.digit3) {
        setMode(CalcMode.programmer);
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    final typed = _typed(event);
    if (typed == null) return KeyEventResult.ignored;
    typed.$2();
    _flash.flash(typed.$1);
    return KeyEventResult.handled;
  }

  /// The menus in Silica's menu bar (silica-desktop#25; calculator.md › Menus): the app menu,
  /// Edit with Copy and Paste (the others disabled, as on the reference), View with the
  /// modes, the thousands separators and the decimal places, Window with Close, Help.
  List<PlatformMenuItem> menus(AppLocalizations l) {
    final decimals = mode != CalcMode.programmer;
    return [
      SilicaMenus.app(l.appTitle),
      SilicaMenus.edit(
        l.menuEdit,
        copy: () => unawaited(copy()),
        paste: () => unawaited(paste()),
      ),
      SilicaMenu(
        label: l.menuView,
        menus: [
          PlatformMenuItemGroup(
            members: [
              for (final (m, label, key) in [
                (CalcMode.basic, l.modeBasic, LogicalKeyboardKey.digit1),
                (
                  CalcMode.scientific,
                  l.modeScientific,
                  LogicalKeyboardKey.digit2,
                ),
                (
                  CalcMode.programmer,
                  l.modeProgrammer,
                  LogicalKeyboardKey.digit3,
                ),
              ])
                SilicaMenuItem(
                  label: label,
                  checked: m == mode,
                  shortcut: SingleActivator(key, meta: true),
                  onSelected: () => setMode(m),
                ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              SilicaMenuItem(
                label: l.menuConvert,
                checked: extra == CalcExtra.convert,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyC,
                  meta: true,
                  alt: true,
                ),
                onSelected: () => toggleExtra(CalcExtra.convert),
              ),
              SilicaMenuItem(
                label: l.menuRpn,
                checked: extra == CalcExtra.rpn,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyR,
                  meta: true,
                ),
                onSelected: () => toggleExtra(CalcExtra.rpn),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: [
              SilicaMenuItem(
                label: thousands ? l.hideThousands : l.showThousands,
                enabled: decimals,
                onSelected: toggleThousands,
              ),
              SilicaMenu(
                label: l.decimalPlaces,
                enabled: decimals,
                menus: [
                  for (var p = 0; p <= maxPlaces; p++)
                    SilicaMenuItem(
                      label: '$p',
                      checked: decimal.places == p,
                      onSelected: () => setPlaces(p),
                    ),
                ],
              ),
            ],
          ),
          // A fixed-size window has no full screen (CA-01: the item is disabled).
          PlatformMenuItemGroup(
            members: [
              SilicaMenuItem(
                label: showHistory && decimals ? l.hideHistory : l.showHistory,
                enabled: decimals && extra != CalcExtra.rpn,
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyS,
                  control: true,
                  meta: true,
                ),
                onSelected: toggleHistory,
              ),
              const SilicaMenuItem.system(
                SilicaMenuItemRole.fullScreen,
                enabled: false,
              ),
            ],
          ),
        ],
      ),
      SilicaMenus.window(l.menuWindow, close: true),
      // Help is silica_ui's standard menu (silica-ui#99).
    ];
  }

  List<AmalfiMenuEntry> _modeMenu(AppLocalizations l) => [
    for (final (m, label, key) in [
      (CalcMode.basic, l.modeBasic, '1'),
      (CalcMode.scientific, l.modeScientific, '2'),
      (CalcMode.programmer, l.modeProgrammer, '3'),
    ])
      AmalfiMenuAction(
        label,
        shortcut: '⌘$key',
        checked: m == mode,
        onSelected: () => setMode(m),
      ),
    const AmalfiMenuDivider(),
    AmalfiMenuAction(
      l.menuConvert,
      shortcut: '⌥⌘C',
      checked: extra == CalcExtra.convert,
      onSelected: () => toggleExtra(CalcExtra.convert),
    ),
    AmalfiMenuAction(
      l.menuRpn,
      shortcut: '⌘R',
      checked: extra == CalcExtra.rpn,
      onSelected: () => toggleExtra(CalcExtra.rpn),
    ),
  ];

  /// The Mode button's menu, below the button and ending with it (Escape or a click outside
  /// closes it).
  void _openModeMenu(BuildContext button, AppLocalizations l) {
    final box = button.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    const width = 200.0;
    final topLeft = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(button);
    final x = math.max(
      4.0,
      math.min(topLeft.dx + box.size.width - width, screen.width - width - 4),
    );
    unawaited(
      showAmalfiMenu(
        context: button,
        position: Offset(x, topLeft.dy + box.size.height + 4),
        entries: _modeMenu(l),
        width: width,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AmalfiTheme.of(context);
    final size = _sizeOf(mode, _wideWindow);
    final texts = KeyTexts(
      clearAll: l.keyClearAll,
      clear: l.keyClear,
      secondTooltip: l.secondTooltip,
    );
    final rows = _keys(texts);
    final width = keyWidth[mode]!;
    final top = mode == CalcMode.basic
        ? extraKeypadTop[extra]!
        : keypadTop[mode]!;
    final convertMode = mode == CalcMode.basic && extra == CalcExtra.convert;
    final rpnMode = mode == CalcMode.basic && extra == CalcExtra.rpn;
    final programmerMode = mode == CalcMode.programmer;
    final sidebar = showHistory && !programmerMode && !rpnMode;
    final error = programmerMode ? programmer.error : decimal.error;
    return SilicaMenuBar(
      menus: menus(l),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: ValueKey('calculator ${mode.name}'),
            width: size.width,
            height: size.height,
            // A real toplevel: the compositor draws the shadow (`shadow: false`).
            child: AmalfiWindow(
              active: _active,
              shadow: false,
              child: ColoredBox(
                color: theme.colors.calculator.window,
                child: AmalfiSidebarRevealBuilder(
                  visible: sidebar,
                  builder: (context, progress) {
                    // The sidebar slides in from the leading edge and the display, keypad and
                    // toolbar items follow its trailing edge; a window that is not the wide
                    // one has no slide (a mode without history).
                    final reveal = _wideWindow ? progress : 0.0;
                    final dx = HistoryMetrics.width * reveal;
                    // The window is the wide one while the sidebar slides out: the content keeps
                    // its width and so stays clear of the window's right edge.
                    final slack = _wideWindow ? HistoryMetrics.width - dx : 0.0;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // The window background moves the window; the toolbar, the display and the
                        // sidebar carry their own drag areas, as these cover the background.
                        const Positioned.fill(
                          key: ValueKey('window drag area'),
                          child: WindowDragArea(child: SizedBox.expand()),
                        ),
                        // Kit `History`: the sidebar runs under the toolbar (full height).
                        if (reveal > 0) ...[
                          Positioned(
                            left: dx - HistoryMetrics.width,
                            top: 0,
                            bottom: 0,
                            width: HistoryMetrics.width,
                            child: HistorySidebar(store: history, now: _now),
                          ),
                        ],
                        // Kit `Toolbar Basic|Sci|Prog`: the controls piece (the compositor draws
                        // the window buttons there), the History toggle (not in the programmer
                        // mode), a spacer and the Mode button.
                        Positioned(
                          left: 0,
                          right: slack,
                          top: 0,
                          child: WindowDragArea(
                            key: const ValueKey('toolbar drag area'),
                            child: AmalfiToolbar(
                              surface: AmalfiToolbarSurface.none,
                              padding: const EdgeInsets.only(right: 8),
                              active: _active,
                              children: [
                                // Open, the toggle moves into the sidebar's title bar, 8 from its
                                // edge (a 44 pt piece at x 168 of the 220 pt sidebar, as in Mail).
                                SizedBox(
                                  width:
                                      controlsWidth +
                                      (HistoryMetrics.width -
                                              historyToggleInset -
                                              controlsWidth) *
                                          reveal,
                                ),
                                if (!programmerMode && !rpnMode)
                                  AmalfiToolbarPiece(
                                    child: AmalfiToolbarButton(
                                      key: const ValueKey('history button'),
                                      semanticLabel: l.sidebarButton,
                                      icon: const AmalfiSymbol('sidebar'),
                                      onPressed: toggleHistory,
                                    ),
                                  ),
                                const AmalfiSpacerPiece(),
                                AmalfiToolbarPiece(
                                  child: Builder(
                                    key: _modeButtonKey,
                                    builder: (button) => AmalfiToolbarButton(
                                      key: const ValueKey('mode button'),
                                      semanticLabel: l.modeButton,
                                      icon: const AmalfiSymbol('ellipsis'),
                                      onPressed: () => _openModeMenu(button, l),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: displayPadding + dx,
                          right: displayPadding + slack,
                          top: 0,
                          height: top,
                          child: WindowDragArea(
                            key: const ValueKey('display drag area'),
                            child: convertMode
                                ? ConvertDisplay(
                                    from: fromUnit,
                                    to: toUnit,
                                    fromText: error
                                        ? l.error
                                        : decimal.mainText(_style),
                                    toText: switch (_converted()) {
                                      final r? => formatNumber(
                                        r,
                                        _style,
                                        places: decimal.places,
                                      ),
                                      null => l.error,
                                    },
                                    onFromUnit: (a) => _pickUnit(a, true),
                                    onToUnit: (a) => _pickUnit(a, false),
                                    onSwap: _swapUnits,
                                  )
                                : rpnMode
                                ? RpnDisplay(
                                    lines: [
                                      rpn.error
                                          ? l.error
                                          : rpn.lineText(
                                              0,
                                              _style,
                                              places: decimal.places,
                                            ),
                                      for (var i = 1; i < 4; i++)
                                        rpn.lineText(
                                          i,
                                          _style,
                                          places: decimal.places,
                                        ),
                                    ],
                                    onSwap: rpn.swap,
                                    onRollDown: rpn.rollDown,
                                    onRollUp: rpn.rollUp,
                                    onDrop: rpn.drop,
                                  )
                                : Display(
                                    main: error
                                        ? l.error
                                        : programmerMode
                                        ? programmer.mainText()
                                        : decimal.mainText(_style),
                                    upper: programmerMode
                                        ? null
                                        : decimal.upperText(_style),
                                    suffix: programmerMode && !error
                                        ? '${programmer.base}'
                                        : null,
                                    indicator: programmerMode
                                        ? programmer.character()
                                        : mode == CalcMode.scientific &&
                                              decimal.angle == AngleUnit.radians
                                        ? l.radiansIndicator
                                        : null,
                                  ),
                          ),
                        ),
                        if (programmerMode)
                          Positioned.fill(
                            child: ProgrammerPanel(
                              calc: programmer,
                              showBinaryLabel: l.showBinary,
                              hideBinaryLabel: l.hideBinary,
                            ),
                          ),
                        for (var r = 0; r < rows.length; r++)
                          for (var c = 0; c < rows[r].length; c++)
                            Positioned(
                              left: keypadLeft + dx + c * columnPitch(mode),
                              top: top + r * rowPitch,
                              child: KeyButton(
                                id: rows[r][c].id,
                                role: rows[r][c].role,
                                width: width,
                                active: _active,
                                flash: _flash,
                                toggled: rows[r][c].toggled,
                                onPressed: rows[r][c].action,
                                child: rows[r][c].label,
                              ),
                            ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
