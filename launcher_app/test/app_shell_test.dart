import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:error_reports_manager/error_reports_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:launcher_app/src/app_report/launcher_crash_session.dart';
import 'package:launcher_app/src/controllers/error_reports_controller.dart';
import 'package:launcher_app/src/controllers/launcher_update_controller.dart';
import 'package:launcher_app/src/controllers/library_module_controller.dart';
import 'package:launcher_app/src/controllers/otzaria_module_controller.dart';
import 'package:launcher_app/src/controllers/search_feedback_controller.dart';
import 'package:launcher_app/src/screens/app_shell.dart';
import 'package:launcher_app/src/screens/custom_apps/custom_apps_settings_card.dart';
import 'package:launcher_app/src/screens/faq/faq_floating_button.dart';
import 'package:launcher_app/src/screens/home_screen.dart';
import 'package:launcher_app/src/screens/library_screen.dart';
import 'package:launcher_app/src/screens/otzaria_screen.dart';
import 'package:launcher_app/src/screens/plugins/plugins_screen.dart';
import 'package:launcher_app/src/screens/reports_upload_section.dart';
import 'package:launcher_app/src/screens/settings_screen.dart';
import 'package:launcher_app/src/services/app_logger.dart';
import 'package:launcher_app/src/services/mirror_download_undo.dart';
import 'package:launcher_app/src/services/notices_seen_store.dart';
import 'package:launcher_app/src/services/sleep_inhibitor.dart';
import 'package:launcher_app/src/settings/app_settings.dart';
import 'package:launcher_app/src/settings/safer_mode.dart';
import 'package:launcher_app/src/settings/settings_controller.dart';
import 'package:launcher_app/src/widgets/widgets_exports.dart';
import 'package:otzaria_l10n/otzaria_l10n.dart';
import 'package:otzaria_manager/otzaria_manager.dart';
import 'package:path/path.dart' as p;
import 'package:plugins_manager/plugins_manager.dart';

import 'test_harness.dart';
import 'test_support.dart';

String _appShellSource() => File(
      'lib/src/screens/app_shell.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  late Directory tempDir;
  late SettingsController settings;
  final shell = stringsOf().shell;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('app_shell_test');
    await AppLogger.init(tempDir.path);
    settings = SettingsController(dataDir: tempDir.path);
    // בדיקת התהליך הייתה מריצה כאן `tasklist` אמיתי (ואיתו טיימר תלוי
    // שמפיל את הבדיקה), ולכן היא מוזרקת.
    await settings.update(const AppSettings(autoCheckUpdates: false));
  });

  tearDown(() async {
    settings.dispose();
    AppLogger.resetForTest();
    await deleteTempDir(tempDir);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    RunningOtzariaLocator locator = const _NeverRunningLocator(),
    AppLanguage language = AppLanguage.hebrew,
    MemoryNoticesStore? notices,
    bool readOnly = false,
    bool driveFull = false,
    SleepInhibitor? sleepInhibitor,
    SearchFeedbackController? searchFeedback,
    ErrorReportsController? errorReports,
  }) async {
    useViewSize(tester, const Size(1400, 1000));
    await tester.pumpWidget(
      wrap(
        AppShell(
          dataDir: tempDir.path,
          settings: settings,
          runningLocator: locator,
          readOnly: readOnly,
          driveFull: driveFull,
          sleepInhibitor: sleepInhibitor,
          searchFeedback: searchFeedback,
          errorReports: errorReports,
          // ברירת המחדל: ההסבר החד-פעמי כבר הוצג, כדי שלא יצוץ באמצע בדיקה
          // שאינה שלו.
          noticesStore: notices ??
              MemoryNoticesStore(seen: {NoticesSeenStore.errorReportsIntro}),
          // כפתורי החלון מדברים עם ערוץ פלטפורמה שאינו קיים בבדיקות widget.
          showWindowButtons: false,
        ),
        language: language,
      ),
    );
    await tester.pump();
  }

  /// [IndexedStack] מסתיר את מי שאינו נבחר, ולכן החיפוש חייב לכלול offstage —
  /// אחרת "לא נמצא" היה יכול להיות "נבנה אבל מוסתר".
  Finder screen(Type type) => find.byType(type, skipOffstage: false);

  testWidgets('מניעת שינה נשמרת עד סיום כל הפעולות ומשוחררת בסגירה',
      (tester) async {
    var acquired = 0;
    var released = 0;
    final inhibitor = SleepInhibitor(acquire: () {
      acquired++;
      return () => released++;
    });
    await pumpShell(tester, sleepInhibitor: inhibitor, readOnly: true);
    final home = tester.widget<HomeScreen>(screen(HomeScreen));
    expect(acquired, 0);

    void changed() => settings.notifyListeners();

    home.library.status = LibraryModuleStatus.updating;
    changed();
    expect(inhibitor.isActive, isTrue);
    home.otzaria.status = OtzariaModuleStatus.installing;
    changed();
    home.library.status = LibraryModuleStatus.error;
    changed();
    expect(acquired, 1);
    expect(released, 0);
    home.otzaria.status = OtzariaModuleStatus.error;
    changed();
    expect(released, 1);

    home.library.downloadStatus = MirrorDownloadStatus.downloading;
    changed();
    expect(inhibitor.isActive, isTrue);
    home.library.downloadStatus = MirrorDownloadStatus.done;
    changed();
    expect(inhibitor.isActive, isFalse);

    home.otzaria.downloadStatus = OtzariaDownloadStatus.downloading;
    changed();
    home.otzaria.downloadStatus = OtzariaDownloadStatus.error;
    changed();
    expect(inhibitor.isActive, isFalse);

    home.launcherUpdate.status = LauncherUpdateStatus.downloading;
    changed();
    expect(inhibitor.isActive, isTrue);
    home.launcherUpdate.status = LauncherUpdateStatus.error;
    changed();
    expect(inhibitor.isActive, isFalse);

    home.launcherUpdate.status = LauncherUpdateStatus.installing;
    changed();
    expect(inhibitor.isActive, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(inhibitor.isActive, isFalse);
    expect(acquired, 5);
    expect(released, 5);
    expect(tester.takeException(), isNull);
  });

  /// ב-[NavRailItem] רק הסמל לחיץ; התווית יושבת מתחתיו כאחות שלו.
  Future<void> tapNav(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(NavRailItem, label),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pump();
  }

  testWidgets('בעלייה נבנה דף הבית בלבד — שאר המסכים כלל לא בעץ', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(screen(HomeScreen), findsOneWidget);
    // חנות התוספים היא היקרה מכולן (רשת כרטיסים עם תמונה לכל תוסף), וזו
    // בדיוק הסיבה שה-IndexedStack אינו בונה את כל ילדיו.
    expect(screen(PluginsScreen), findsNothing);
    expect(screen(OtzariaScreen), findsNothing);
    expect(screen(LibraryScreen), findsNothing);
    expect(screen(SettingsScreen), findsNothing);
  });

  testWidgets('כפתור השאלות הנפוצות צף בפינה השמאלית התחתונה של דף הבית', (
    tester,
  ) async {
    await pumpShell(tester);

    Rect buttonRect() => tester.getRect(find.byType(FaqFloatingButton));
    final windowSize = tester.view.physicalSize / tester.view.devicePixelRatio;

    expect(find.byType(FaqFloatingButton), findsOneWidget);
    // בעברית סרגל הניווט מימין, ולכן הכפתור פיזית שמאל-למטה.
    expect(buttonRect().left, lessThan(windowSize.width / 2));
    expect(buttonRect().bottom, greaterThan(windowSize.height / 2));

    // במסך אחר הוא מוסתר — אבל נשאר בעץ, אחרת ההבהוב והבועה החד-פעמיים היו
    // חוזרים בכל חזרה לדף הבית.
    await tapNav(tester, shell.navSettings);
    expect(find.byType(FaqFloatingButton), findsNothing);
    expect(find.byType(FaqFloatingButton, skipOffstage: false), findsOneWidget);

    await tapNav(tester, shell.navHome);
    expect(find.byType(FaqFloatingButton), findsOneWidget);
  });

  testWidgets('באנגלית הכפתור עובר לימין — הוא כיסה את סרגל הניווט שמשמאל', (
    tester,
  ) async {
    await pumpShell(tester, language: AppLanguage.english);

    final rect = tester.getRect(find.byType(FaqFloatingButton));
    final windowSize = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(rect.right, greaterThan(windowSize.width / 2));
    expect(rect.bottom, greaterThan(windowSize.height / 2));
  });

  testWidgets('כיבוי בהגדרות מוציא את הכפתור מהעץ לגמרי', (tester) async {
    // `runAsync` ולא `await` ישר: השמירה כותבת לדיסק, וקריאת `dart:io` אינה
    // מסתיימת בתוך ה-fake-async של `testWidgets` — ראו AGENTS §3.
    await tester.runAsync(
      () => settings.update(
        const AppSettings(autoCheckUpdates: false, showFaqButton: false),
      ),
    );
    await pumpShell(tester);

    expect(find.byType(FaqFloatingButton, skipOffstage: false), findsNothing);
  });

  testWidgets('מסך שנכנסים אליו נבנה, ונשאר בעץ גם אחרי מעבר משם', (
    tester,
  ) async {
    await pumpShell(tester);

    await tapNav(tester, shell.navPlugins);
    expect(screen(PluginsScreen), findsOneWidget);
    // שאר המסכים עדיין לא נבנו — הבנייה היא לפי ביקור, לא מראש.
    expect(screen(LibraryScreen), findsNothing);

    await tapNav(tester, shell.navHome);
    // נשאר בעץ עם המצב שלו — זו כל הנקודה של IndexedStack מדורג.
    expect(screen(PluginsScreen), findsOneWidget);
    expect(screen(HomeScreen), findsOneWidget);
  });

  testWidgets('מסך מוסתר אינו מריץ אנימציות — רק המוצג מקבל טיקרים', (
    tester,
  ) async {
    await pumpShell(tester);
    bool ticking(Type type) =>
        TickerMode.valuesOf(tester.element(screen(type))).enabled;

    expect(ticking(HomeScreen), isTrue);

    await tapNav(tester, shell.navPlugins);
    expect(ticking(PluginsScreen), isTrue);
    expect(ticking(HomeScreen), isFalse);

    await tapNav(tester, shell.navHome);
    expect(ticking(HomeScreen), isTrue);
    expect(ticking(PluginsScreen), isFalse);
  });

  testWidgets('כל חמשת המסכים נבנים אחרי ביקור בכולם', (tester) async {
    await pumpShell(tester);

    for (final label in [
      shell.navApp,
      shell.navLibrary,
      shell.navPlugins,
      shell.navSettings,
    ]) {
      await tapNav(tester, label);
    }

    expect(screen(HomeScreen), findsOneWidget);
    expect(screen(OtzariaScreen), findsOneWidget);
    expect(screen(LibraryScreen), findsOneWidget);
    expect(screen(PluginsScreen), findsOneWidget);
    expect(screen(SettingsScreen), findsOneWidget);
  });

  testWidgets('אין דיאלוג בעלייה — גם לא זה של עדכוני התוספים', (tester) async {
    await pumpShell(tester);
    await tester.pump();

    // הדיאלוג של "יש עדכונים לתוספים" יושב ב-PluginsScreen, שלא נבנה עדיין;
    // זו התוצאה הנלווית המכוונת של הבנייה המדורגת.
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(screen(PluginsScreen), findsNothing);
  });

  group('הסבר חד-פעמי על דיווחי הטעויות', () {
    final t = stringsOf().errorReports;

    /// `pump` ולא `pumpAndSettle` — ראו ההערה בראש הקובץ. הראשון מריץ את
    /// `endOfFrame`, השני בונה את הדיאלוג, והשלישי מסיים את האנימציה שלו.
    Future<void> settleDialog(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('הרצה ראשונה: החלון מופיע אחרי הפריים ונרשם רק בסגירה', (
      tester,
    ) async {
      final notices = MemoryNoticesStore();
      await pumpShell(tester, notices: notices);
      await settleDialog(tester);

      expect(find.text(t.introDialogTitle), findsOneWidget);
      expect(find.text(t.introDialogContent), findsOneWidget);
      expect(notices.marked, isEmpty);

      await tester.tap(find.text(t.introDialogConfirm));
      await settleDialog(tester);

      expect(find.text(t.introDialogTitle), findsNothing);
      expect(notices.marked, [NoticesSeenStore.errorReportsIntro]);
    });

    testWidgets('כונן נעול: מופיע בנוסח שמסביר שאי אפשר לאסוף', (tester) async {
      await pumpShell(tester, notices: MemoryNoticesStore(), readOnly: true);
      await settleDialog(tester);

      expect(find.text(t.introDialogContentReadOnly), findsOneWidget);
      expect(find.text(t.introDialogContent), findsNothing);
    });

    testWidgets('כונן מלא: מופיע בנוסח שמבקש לפנות מקום', (tester) async {
      await pumpShell(
        tester,
        notices: MemoryNoticesStore(),
        readOnly: true,
        driveFull: true,
      );
      await settleDialog(tester);

      expect(find.text(t.introDialogContentReadOnlyDriveFull), findsOneWidget);
      expect(find.text(t.introDialogContentReadOnly), findsNothing);
    });

    testWidgets('כבר הוצג במחשב הזה → אין חלון', (tester) async {
      await pumpShell(tester);
      await settleDialog(tester);

      expect(find.text(t.introDialogTitle), findsNothing);
    });
  });

  testWidgets('בקשת מיקוד מחנות התוספים מעבירה את התצוגה אליה', (tester) async {
    await pumpShell(tester);

    // כניסה ויציאה — המסך נשאר בעץ, ולכן הודעת העדכונים שלו יכולה לצוץ
    // כשהמשתמש כבר בדף הבית. בחירת תוסף מתוכה מבקשת מיקוד, וזו הבקשה כאן.
    await tapNav(tester, shell.navPlugins);
    await tapNav(tester, shell.navHome);

    int? shownScreen() => tester
        .widget<IndexedStack>(find.byType(IndexedStack, skipOffstage: false))
        .index;
    expect(shownScreen(), LauncherScreen.home.index);

    tester.widget<PluginsScreen>(screen(PluginsScreen)).onRequestFocus!();
    await tester.pump();

    expect(shownScreen(), LauncherScreen.plugins.index);
  });

  testWidgets('סרגל הזהות מציג את שם התוכנה ואת הסמל', (tester) async {
    await pumpShell(tester);

    expect(find.text(shell.appTitle), findsOneWidget);
    final logo = tester.widget<Image>(find.byType(Image).first);
    expect(logo.semanticLabel, shell.otzariaLogoLabel);
    // מחווני המצב שהיו בסרגל העליון הוסרו — הם יושבים בדף הבית.
    expect(find.byType(StatusChip), findsWidgets);
  });

  testWidgets('בעלייה אין שום חיווי שגיאה, והבדיקה ברשת כבויה', (tester) async {
    await pumpShell(tester);
    await tester.pump();

    expect(find.byType(InfoErrorRow), findsNothing);
    expect(find.text(stringsOf().common.error), findsNothing);
    expect(find.text(stringsOf().home.onlineNeverChecked), findsOneWidget);
  });

  testWidgets('checkOnline שנכשל (אין רשת) אינו מציג שגיאה אלא "אין חיבור"', (
    tester,
  ) async {
    // הבדיקה הקלה היא מטא-דאטה בלבד, וכשל בה הוא תוצאה **תקינה** —
    // המחשב המנותק הוא מקרה השימוש המרכזי של התוכנה.
    HttpOverrides.global = NoNetworkHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    // שמירת ההגדרות כותבת לדיסק — חייבת לרוץ מחוץ ל-fake-async.
    await tester.runAsync(
      () => settings.update(const AppSettings(autoCheckUpdates: true)),
    );

    await pumpShell(tester);
    // ההצצה לתוספים ממתינה לבדיקה המקומית — היא שקובעת לאילו גרסאות אוצריא
    // לשאול על בילדי התוספים. זו סדרת קריאות `dart:io`, וכל אחת מתקדמת רק
    // ב-runAsync בעוד המיקרו-משימות שלה נשטפות ב-pump שאחריו.
    final offline = find.text(stringsOf().home.onlineOffline);
    for (var i = 0; i < 40 && offline.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(seconds: 1));
    }

    expect(offline, findsOneWidget);
    expect(find.byType(InfoErrorRow), findsNothing);
    expect(find.text(stringsOf().common.error), findsNothing);
    // לא נמצא עדכון ברשת, ולכן גם אין הצעה להוריד.
    expect(find.text(stringsOf().home.downloadNowButton), findsNothing);
  });

  testWidgets('אוצריא שנסגרה מזוהה בזמן שהלאנצ\'ר פתוח — בלי הפעלה מחדש שלו', (
    tester,
  ) async {
    // הבדיקה המקומית כבויה כאן בכוונה: היא קוראת מהדיסק ולא מסתיימת בתוך
    // ה-fake-async, ואז מצב התהליך היה נקבע רק אחרי סיום הבדיקה.
    await tester.runAsync(
      () => settings.update(const AppSettings(autoCheckUpdates: false)),
    );
    final locator = _MutableLocator(isRunning: true);

    await pumpShell(tester, locator: locator);
    await tester.pump();
    expect(find.text(stringsOf().home.otzariaRunningTitle), findsOneWidget);

    // המשתמש סוגר את אוצריא. הרענון המחזורי אמור להבחין בזה מעצמו.
    locator.isRunning = false;
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    expect(find.text(stringsOf().home.otzariaRunningTitle), findsNothing);

    // ומכאן הטיימר צריך להיכבות: אחרת `tasklist` (~300ms) היה רץ כל 3
    // שניות לנצח, על אוצריא שכבר סגורה.
    final probesWhenClosed = locator.probes;
    await tester.pump(const Duration(seconds: 12));
    expect(locator.probes, probesWhenClosed);
  });

  test('כל סיום של משימה ארוכה מעיר את ההצעה שנדחתה', () {
    final source = _appShellSource();
    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, greaterThan(-1), reason: signature);
      return source.substring(start, source.indexOf('\n  }\n', start));
    }

    expect(body('void _rebuild() {'), contains('_offers.resume()'));
    expect(
      source,
      contains('setState(() => _elevationPending = false);\n'
          '        _offers.resume();'),
    );
    expect(source, contains('Future<bool> closeOtzaria() => _offers.holdFor('));
    expect(source, contains('_downloads.isPreparing'));
    expect(source, contains('blocked: () => _blockedByReadOnly()'));
  });

  testWidgets('הניווט מסמן את הפריט הנבחר ומחליף את המסך המוצג', (
    tester,
  ) async {
    await pumpShell(tester);

    NavRailItem item(String label) =>
        tester.widget<NavRailItem>(find.widgetWithText(NavRailItem, label));

    expect(item(shell.navHome).isSelected, isTrue);
    expect(item(shell.navSettings).isSelected, isFalse);

    await tapNav(tester, shell.navSettings);

    expect(item(shell.navHome).isSelected, isFalse);
    expect(item(shell.navSettings).isSelected, isTrue);
    expect(screen(SettingsScreen), findsOneWidget);
  });

  // Custom-app management writes to mirror/apps on the drive (issue #25).
  for (final readOnly in [true, false]) {
    testWidgets('settings custom-apps card with readOnly=$readOnly', (
      tester,
    ) async {
      await pumpShell(tester, readOnly: readOnly);
      await tapNav(tester, shell.navSettings);

      final card = find.byType(CustomAppsSettingsCard, skipOffstage: false);
      expect(card, findsOneWidget);
      final button = tester.widget<ActionButton>(
        find.descendant(of: card, matching: find.byType(ActionButton)),
      );
      expect(button.onPressed == null, readOnly);
      expect(
        find.descendant(
          of: card,
          matching: find.text(
            stringsOf().readOnlyDrive.customAppsManageDisabled,
          ),
        ),
        readOnly ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('settings custom-apps card on a full drive asks to free space', (
    tester,
  ) async {
    await pumpShell(tester, readOnly: true, driveFull: true);
    await tapNav(tester, shell.navSettings);

    final card = find.byType(CustomAppsSettingsCard, skipOffstage: false);
    final t = stringsOf().readOnlyDrive;
    expect(
      find.descendant(
        of: card,
        matching: find.text(t.customAppsManageDisabledDriveFull),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: card,
        matching: find.text(t.customAppsManageDisabled),
      ),
      findsNothing,
    );
  });

  testWidgets('ביטול הורדה מנקה את שתי תיקיות המראה של התוספים', (
    tester,
  ) async {
    await pumpShell(tester);

    final dynamic state = tester.state(find.byType(AppShell));
    final dirs = List<String>.from(state.downloadMirrorDirs as List);
    final mirrorRoot = p.join(tempDir.path, 'mirror');
    final pluginDirs = PluginsManager.mirrorDirsIn(mirrorRoot);

    expect(pluginDirs, hasLength(2));
    expect(dirs, containsAll(pluginDirs));

    await tester.runAsync(() async {
      final undo = await MirrorDownloadUndo.capture(dirs);
      final written = [
        for (final dir in pluginDirs) File(p.join(dir, 'new', 'asset.bin')),
      ];
      for (final file in written) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('x');
      }

      await undo.revert();

      for (final file in written) {
        expect(file.existsSync(), isFalse, reason: file.path);
      }
    });
  });

  test('Ctrl+R ו-F5 מרעננים, ולא בזמן משימה ארוכה', () {
    final source = _appShellSource();
    expect(source, contains('LogicalKeyboardKey.keyR, control: true'));
    expect(source, contains('LogicalKeyboardKey.f5'));
    final body = source.substring(
      source.indexOf('Future<void> _refreshFromKeyboard()'),
      source.indexOf('Widget build(BuildContext context)',
          source.indexOf('Future<void> _refreshFromKeyboard()')),
    );
    expect(body, contains('if (_longTaskRunning) return;'));
  });

  group('חיווט הזרימות שהוצאו מהמסגרת', () {
    final source = _appShellSource();

    String bodyOf(String signature, String until) {
      final start = source.indexOf(signature);
      expect(start, greaterThan(-1), reason: signature);
      final end = source.indexOf(until, start);
      expect(end, greaterThan(start), reason: until);
      return source.substring(start, end);
    }

    test('ההתקנה האוטומטית נשענת על בדיקת תהליך טרייה ועל חסימת היציאה', () {
      final wiring = bodyOf(
        'late final AutoInstallFlow _autoInstall',
        'late final DialogQueue _dialogs',
      );
      expect(wiring, contains('isOtzariaRunning: refreshProcessState,'));
      expect(wiring, contains('isDownloading: () => _downloads.isDownloading'));
      expect(wiring, contains('exitPending: () => _exitPending'));
      expect(wiring, isNot(contains('_otzariaIsRunning')));
    });

    test('דילוג בגלל אוצריא פתוחה מדווח בדיאלוג', () {
      final body = bodyOf(
        'Future<void> _autoInstallIfEnabled() async {',
        'downloadMirrorDirs',
      );
      expect(body, contains('_autoInstall.run('));
      expect(body, contains('widget.settings.settings.autoInstall'));
      expect(body, contains('showSingleActionDialog'));
      expect(body, contains('autoInstallSkippedTitle'));
      expect(body, isNot(contains('useWizard: true')));
    });

    test('הבדיקה המקוונת שלפני ההורדה מרעננת רק את מה שהתיישן', () {
      final body = bodyOf(
        'Future<void> _refreshStaleOnlineChecks(AppSettings s)',
        'Future<bool> _confirmSemanticSearch()',
      );
      expect(body, contains('StaleOnlineChecks.of('));
      expect(body, contains('if (stale.app) _otzaria.checkOnline()'));
      expect(body, contains('if (stale.library) _library.checkOnline()'));
      expect(body, contains('if (stale.plugins) _plugins.checkOnline()'));
      expect(body, contains('_plugins.storeAppCheckedAt'));
      expect(body, contains('_library.onlineCheckError'));
    });

    test("ההורדה נחסמת בפעולה ארוכה ובהורדת הלאנצ'ר, והניקוי נדחה בה", () {
      final host = bodyOf(
        'class _ShellDownloadHost implements MirrorDownloadHost',
        'class _ShellLauncherHost',
      );
      expect(
        host,
        contains(
          '_shell._longTaskRunning || _shell._launcherUpdate.isDownloading',
        ),
      );
      expect(
        host,
        contains(
          'bool get launcherDownloading => _shell._launcherUpdate.isDownloading',
        ),
      );
      expect(host, contains('_shell._refreshStaleOnlineChecks(s)'));
      expect(host, contains('_shell._sweepMirrorJunk()'));
    });

    test('ההחלפה של קובץ ההרצה נחסמת בכל פעולה שיציאה קוטעת', () {
      final host = bodyOf(
        'class _ShellLauncherHost implements LauncherUpdateHost',
        'class _NavRail',
      );
      expect(host, contains('wouldInterrupt => _shell._exitWouldInterrupt'));
      expect(host, contains('_shell._searchFeedback.stopAndWait()'));
      expect(host, contains('_shell._blockedByReadOnly()'));
      expect(host, contains('isReadOnly => _shell.widget.readOnly'));
      final flow = bodyOf(
        'late final LauncherUpdateFlow _launcherFlow',
        'late final AutoInstallFlow _autoInstall',
      );
      expect(flow, contains('downloads: _downloads,'));
    });

    test('ביטול משחזר את המראה ומרענן את המודולים', () {
      final body = bodyOf(
        'Future<DownloadRollback> _captureDownloadRollback()',
        'void _rebuild()',
      );
      expect(body, contains('CancelledDownloadRollback.capture('));
      expect(body, contains('mirrorDirs: downloadMirrorDirs'));
    });
  });

  group('משוב החיפוש: איסוף והעלאה ברקע, בלי ממשק', () {
    late _ShellFeedback transport;
    late List<String> snacks;
    DebugPrintCallback? previousPrint;

    setUp(() {
      transport = _ShellFeedback();
      snacks = [];
      previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message?.startsWith('UiSnack') ?? false) snacks.add(message!);
      };
    });

    // נבדק בסוף גוף הבדיקה, לפני tearDown — לכן משוחזר כאן.
    void restorePrint() => debugPrint = previousPrint!;

    SearchFeedbackController feedbackFor(_MutableLocator locator) =>
        SearchFeedbackController(
          transport: transport,
          resolveSource: () async {
            final probe = await locator.probe();
            return probe.isRunning || !transport.consent ? null : 'source';
          },
        );

    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    void expectSilent(WidgetTester tester) {
      restorePrint();
      expect(find.byType(AlertDialog), findsNothing);
      expect(snacks, isEmpty);
      expect(find.text(stringsOf().errorReports.uploadButton(2)), findsNothing);
      expect(
        find.textContaining(stringsOf().errorReports.uploadPendingOffline(2)),
        findsNothing,
      );
      expect(
        find.textContaining(stringsOf().errorReports.uploadPendingUnchecked(2)),
        findsNothing,
      );
    }

    testWidgets('בעלייה, גם כשהבדיקה האוטומטית כבויה: נאסף ומועלה בלי לחיצה', (
      tester,
    ) async {
      final locator = _MutableLocator(isRunning: false);
      await pumpShell(
        tester,
        locator: locator,
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => transport.uploads > 0);

      expect(transport.collections, 1);
      expect(transport.uploads, 1);
      expect(settings.settings.autoCheckUpdates, isFalse);
      expect(transport.sent, 2);
      expectSilent(tester);
    });

    testWidgets('אינו ממתין להסבר הדיווחים הפתוח ואינו מופיע בו', (
      tester,
    ) async {
      final locator = _MutableLocator(isRunning: false);
      await pumpShell(
        tester,
        locator: locator,
        notices: MemoryNoticesStore(),
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => transport.uploads > 0);

      restorePrint();
      expect(
          find.text(stringsOf().errorReports.introDialogTitle), findsOneWidget);
      expect(transport.sent, 2);
      expect(snacks, isEmpty);
    });

    testWidgets('בלי הסכמה באוצריא אין איסוף ואין העלאה', (tester) async {
      transport.consent = false;
      final locator = _MutableLocator(isRunning: false);
      await pumpShell(
        tester,
        locator: locator,
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => false);

      expect(transport.collections, 0);
      expect(transport.uploads, 0);
      expect(transport.sourceEvents, 2);
      expectSilent(tester);
    });

    testWidgets('אוצריא פתוחה: ממתין, ואוסף מעצמו כשהיא נסגרת', (tester) async {
      final locator = _MutableLocator(isRunning: true);
      await pumpShell(
        tester,
        locator: locator,
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => false);
      expect(transport.collections, 0);
      expect(transport.sourceEvents, 2);

      locator.isRunning = false;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester, () => transport.uploads > 0);

      expect(transport.collections, 1);
      expect(transport.sent, 2);
      expectSilent(tester);
    });

    testWidgets('כונן לקריאה בלבד: אין איסוף, העלאה או כתיבה, ואין הודעה', (
      tester,
    ) async {
      transport.carriedEvents = 3;
      final locator = _MutableLocator(isRunning: false);
      await pumpShell(
        tester,
        locator: locator,
        readOnly: true,
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => false);
      locator.isRunning = true;
      await tester.runAsync(
        () => tester
            .widget<HomeScreen>(screen(HomeScreen))
            .otzaria
            .refreshRunningState(force: true),
      );
      await tester.pump();
      locator.isRunning = false;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester, () => false);

      expect(transport.collections, 0);
      expect(transport.uploads, 0);
      restorePrint();
      expect(transport.counts, 0);
      expect(snacks, isEmpty);
    });

    testWidgets('אין רשת: הנתונים נשמרים, וניסיון חוזר רק אחרי ההשהיה', (
      tester,
    ) async {
      transport.online = false;
      final locator = _MutableLocator(isRunning: false);
      await pumpShell(
        tester,
        locator: locator,
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => transport.uploads > 0);
      expect(transport.uploads, 1);
      expect(transport.carriedEvents, 2);

      await tester.pump(const Duration(minutes: 1));
      await settle(tester, () => false);
      expect(transport.uploads, 1);

      transport.online = true;
      await tester.pump(const Duration(minutes: 2));
      await settle(tester, () => transport.uploads > 1);
      expect(transport.uploads, 2);
      expect(transport.carriedEvents, 0);
      expectSilent(tester);
    });

    testWidgets('פירוק המסגרת מבטל את הניסיון החוזר', (tester) async {
      transport.online = false;
      final locator = _MutableLocator(isRunning: false);
      await pumpShell(
        tester,
        locator: locator,
        searchFeedback: feedbackFor(locator),
      );
      await settle(tester, () => transport.uploads > 0);
      await tester.pumpWidget(const SizedBox.shrink());
      transport.online = true;
      await tester.pump(const Duration(hours: 1));
      restorePrint();
      expect(transport.uploads, 1);
      expect(transport.closed, isTrue);
    });
  });

  group('דיווחי הטעויות לצד משוב החיפוש', () {
    final t = stringsOf().errorReports;
    late _ShellFeedback transport;
    late _ShellReportQueue queue;
    late ErrorReportsController reports;

    setUp(() {
      transport = _ShellFeedback();
      queue = _ShellReportQueue();
      reports = ErrorReportsController(
        outbox: queue.outbox,
        resolveQueue: () async => queue,
      );
    });

    SearchFeedbackController feedbackFor(_MutableLocator locator) =>
        SearchFeedbackController(
          transport: transport,
          resolveSource: () async {
            final probe = await locator.probe();
            return probe.isRunning ? null : 'source';
          },
        );

    Future<void> settle(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 120 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pumpBoth(WidgetTester tester, _MutableLocator locator) async {
      await pumpShell(
        tester,
        locator: locator,
        errorReports: reports,
        searchFeedback: feedbackFor(locator),
      );
      final otzaria = tester.widget<HomeScreen>(screen(HomeScreen)).otzaria;
      await settle(
          tester, () => otzaria.status != OtzariaModuleStatus.checking);
      expect(otzaria.status, isNot(OtzariaModuleStatus.checking));
      otzaria.launchPath = 'x';
    }

    Future<void> openAndClose(
      WidgetTester tester,
      _MutableLocator locator,
    ) async {
      final otzaria = tester.widget<HomeScreen>(screen(HomeScreen)).otzaria;
      locator.isRunning = true;
      await tester.runAsync(() => otzaria.refreshRunningState(force: true));
      await tester.pump();
      expect(otzaria.isRunning, isTrue);
      locator.isRunning = false;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester, () => false);
    }

    final dialog = find.text(t.collectDialogTitle);

    testWidgets('שני מחזורים: סירוב, איסוף מוצלח, ואז דיווח בודד מוצע', (
      tester,
    ) async {
      final locator = _MutableLocator(isRunning: true);
      await pumpBoth(tester, locator);
      queue.pending = 3;
      transport.sourceEvents = 2;

      locator.isRunning = false;
      await tester.pump(const Duration(seconds: 4));
      await settle(tester, () => dialog.evaluate().isNotEmpty);
      expect(dialog, findsOneWidget);
      expect(find.text(t.collectDialogContent(3)), findsOneWidget);
      await tester.tap(find.text(t.collectLater));
      await settle(tester, () => dialog.evaluate().isEmpty);
      expect(queue.outbox.reports, isEmpty);
      expect(transport.sent, 2);

      queue.pending = 4;
      transport.sourceEvents = 1;
      await openAndClose(tester, locator);
      await settle(tester, () => dialog.evaluate().isNotEmpty);
      expect(dialog, findsOneWidget);
      expect(find.text(t.collectDialogContent(4)), findsOneWidget);
      await tester.tap(find.text(t.collectConfirm));
      await settle(tester, () => queue.outbox.reports.length == 4);
      expect(queue.outbox.reports, hasLength(4));
      expect(queue.pending, 0);
      expect(transport.sent, 3);

      queue.pending = 1;
      await openAndClose(tester, locator);
      await settle(tester, () => dialog.evaluate().isNotEmpty);
      expect(dialog, findsOneWidget);
      expect(find.text(t.collectDialogContent(1)), findsOneWidget);
      await tester.tap(find.text(t.collectConfirm));
      await settle(tester, () => queue.outbox.reports.length == 5);
      expect(queue.outbox.reports, hasLength(5));
      expect(queue.collects, 2);
    });

    testWidgets('משוב לבדו: בלי דיאלוג, כפתור, טקסט המתנה או סיכום דיווחים', (
      tester,
    ) async {
      final locator = _MutableLocator(isRunning: false);
      await pumpBoth(tester, locator);
      await settle(tester, () => transport.uploads > 0);

      expect(transport.sent, 2);
      expect(queue.collects, 0);
      expect(dialog, findsNothing);
      expect(find.byType(ReportsUploadSection), findsOneWidget);
      expect(find.text(t.uploadButton(2)), findsNothing);
      expect(find.textContaining(t.uploadPendingOffline(2)), findsNothing);
      expect(find.textContaining(t.uploadPendingUnchecked(2)), findsNothing);
      expect(reports.outboxCount, 0);
    });

    testWidgets('העלאת משוב שנתקעה אינה מונעת הצעת דיווחים, ללא כפילות', (
      tester,
    ) async {
      final gate = Completer<void>();
      transport.uploadGate = gate;
      final locator = _MutableLocator(isRunning: false);
      await pumpBoth(tester, locator);
      queue.pending = 2;
      await settle(tester, () => transport.uploads > 0);
      expect(transport.uploads, 1);

      await openAndClose(tester, locator);
      await settle(tester, () => dialog.evaluate().isNotEmpty);
      expect(dialog, findsOneWidget);
      expect(transport.uploads, 1);
      expect(transport.collections, 1);

      gate.complete();
      await tester.tap(find.text(t.collectLater));
      await settle(tester, () => transport.sent > 0);
      expect(transport.sent, 2);
      expect(transport.uploads, 1);
    });

    testWidgets('פירוק בזמן העלאת משוב: אין פעילות אחריו', (tester) async {
      final gate = Completer<void>();
      transport.uploadGate = gate;
      final locator = _MutableLocator(isRunning: false);
      await pumpBoth(tester, locator);
      await settle(tester, () => transport.uploads > 0);

      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      transport.online = false;
      await settle(tester, () => false);
      await tester.pump(const Duration(hours: 1));
      expect(transport.uploads, 1);
      expect(transport.collections, 1);
      expect(transport.closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('פעולות שיציאה מהתהליך קוטעת', () {
    final source = _appShellSource();
    final start = source.indexOf('bool get _longTaskRunning');
    final getters = source.substring(
      start,
      source.indexOf('Future<void> installLauncherUpdate()', start),
    );

    test('הגטרים נמצאים', () {
      expect(start, greaterThan(-1));
      expect(getters, contains('bool get _exitWouldInterrupt'));
    });

    test('כוללות התקנה, למידה והורדה של תוכנות מותאמות וייצוא החנות', () {
      expect(getters, contains('_customApps.isBusy'));
      expect(getters, contains('_customApps.isLearning'));
      expect(getters, contains('_customApps.isDownloadingAll'));
      expect(getters, contains('_plugins.isExporting'));
    });

    test('כוללות את ההמתנה ל-UAC ואת החלפת קובץ ההרצה', () {
      expect(
        getters,
        contains(
          'bool get _exitPending =>'
          ' _elevationPending || _launcherUpdate.isInstalling;',
        ),
      );
      expect(
        getters.substring(0, getters.indexOf('bool get _exitWouldInterrupt')),
        contains('_exitPending'),
      );
    });

    test('כוללות איסוף והעלאה של דיווחים', () {
      expect(getters, contains('_errorReports.isCollecting'));
      expect(getters, contains('_errorReports.isUploading'));
      final interrupt = getters.substring(
        getters.indexOf('bool get _exitWouldInterrupt'),
      );
      expect(interrupt, isNot(contains('_searchFeedback')));
    });
  });

  group('חסימת הסנכרון והייצוא בזמן פעולה אחרת', () {
    final source = _appShellSource();
    final start = source.indexOf('bool get _pluginSyncBlockedElsewhere');
    final getter = source.substring(
      start,
      source.indexOf('bool get _exitPending', start),
    );

    test('הגטר כולל הורדה, החלפת מסד, התקנת אוצריא ותוכנות מותאמות', () {
      expect(start, greaterThan(-1));
      expect(getter, contains('_downloads.isDownloading'));
      expect(getter, contains('_library.isApplying'));
      expect(getter, contains('LibraryModuleStatus.updating'));
      expect(getter, contains('OtzariaModuleStatus.installing'));
      expect(getter, contains('_customApps.isBusy'));
    });

    test('מסך התוספים מקבל אותו', () {
      final screen = source.substring(source.indexOf('PluginsScreen('));
      final args =
          screen.substring(0, screen.indexOf('LauncherScreen.settings'));
      expect(args, contains('busyElsewhere: _pluginSyncBlockedElsewhere'));
    });
  });

  group('_maybeOfferElevation', () {
    final source = _appShellSource();
    final start = source.indexOf('Future<void> _maybeOfferElevation()');
    final body = source.substring(
      start,
      source.indexOf('void _syncRunningPoll()', start),
    );

    test('גוף המתודה נמצא', () {
      expect(start, greaterThan(-1));
      expect(body, contains('Elevation.restartElevated()'));
    });

    test('נדחית בזמן פעולה ארוכה, לפני הדיאלוג ואחריו', () {
      final dialog = body.indexOf('showTwoActionsDialog');
      final restart = body.indexOf('Elevation.restartElevated()');
      expect(body.indexOf('_exitWouldInterrupt'), lessThan(dialog));
      final afterDialog = body.indexOf('_exitWouldInterrupt', dialog);
      expect(afterDialog, greaterThan(dialog));
      expect(afterDialog, lessThan(restart));
      expect(
        body.substring(afterDialog, restart),
        contains('_offeredElevation = false'),
      );
    });

    test('משוב ברקע נעצר בסדר אחרי האישור, לפני בדיקת החסימה', () {
      final dialog = body.indexOf('showTwoActionsDialog');
      final stop = body.indexOf('_searchFeedback.stopAndWait()', dialog);
      expect(stop, greaterThan(dialog));
      expect(stop, lessThan(body.indexOf('_exitWouldInterrupt', dialog)));
    });

    test('מסמנת המתנה ל-UAC סביב restartElevated ומאפסת בכשל', () {
      final pending = body.indexOf('setState(() => _elevationPending = true)');
      final restart = body.indexOf('Elevation.restartElevated()');
      expect(pending, greaterThan(-1));
      expect(pending, lessThan(restart));
      final reset = body.indexOf('_elevationPending = false', restart);
      expect(reset, greaterThan(restart));
      expect(body.substring(restart, reset), contains('finally'));
    });

    test(
      'ממשק המסגרת וההורדה חסומים בזמן ההמתנה ל-UAC או החלפת קובץ ההרצה',
      () {
        expect(source, contains('absorbing: _exitPending'));
        expect(source, contains('excluding: _exitPending'));
        final guard = source.substring(
          source.indexOf('bool get _longTaskRunning'),
          source.indexOf('bool get _exitPending'),
        );
        expect(guard, contains('_exitPending'));
        final host = source.substring(
          source.indexOf('class _ShellDownloadHost'),
          source.indexOf('class _ShellLauncherHost'),
        );
        expect(host, contains('bool get isBlocked =>'));
        expect(host, contains('_shell._longTaskRunning'));
        final wait = source.substring(
          source.indexOf('late final DialogQueue _dialogs'),
          source.indexOf('void initState()'),
        );
        expect(
          wait,
          contains(
            '_exitPending || !(ModalRoute.of(context)?.isCurrent ?? true)',
          ),
        );
      },
    );

    test('מוצעת שוב בסיום איסוף או העלאה של דיווחים', () {
      expect('..addListener(_onReportsChange)'.allMatches(source).length, 2);
      expect('removeListener(_onReportsChange)'.allMatches(source).length, 2);
      final listener = source.substring(
        source.indexOf('void _onReportsChange()'),
        source.indexOf('Future<void> _maybeAnnouncePlugins()'),
      );
      expect(listener, contains('_maybeOfferElevation()'));
      expect(listener, isNot(contains('setState')));
    });

    test('מוצעת שוב בסוף ההורדה', () {
      final host = source.substring(
        source.indexOf('class _ShellDownloadHost'),
        source.indexOf('class _ShellLauncherHost'),
      );
      final cancelled = host.substring(
        host.indexOf('void downloadCancelled('),
        host.indexOf('void downloadEnded()'),
      );
      final ended = host.substring(
        host.indexOf('void downloadEnded()'),
        host.indexOf('void downloadFinished('),
      );
      expect(cancelled, contains('_shell._maybeOfferElevation()'));
      expect(ended, contains('_shell._maybeOfferElevation()'));
    });
  });

  group('מצב סייפר — הכניסה להגדרות', () {
    /// מפעיל את הנעילה על ההגדרות שהמסגרת כבר מחזיקה. `runAsync` כי הכתיבה
    /// לדיסק אינה מסתיימת בתוך ה-fake-async.
    Future<void> lockSettings(WidgetTester tester) => tester.runAsync(
          () => settings.update(
            AppSettings(
              autoCheckUpdates: false,
              saferModeEnabled: true,
              saferModePassword: SaferModePassword.encode('1234'),
            ),
          ),
        );

    testWidgets('לחיצה על ההגדרות פותחת דיאלוג סיסמה ואינה בונה את המסך', (
      tester,
    ) async {
      await lockSettings(tester);
      await pumpShell(tester);

      await tapNav(tester, shell.navSettings);
      await tester.pump();

      expect(find.text(stringsOf().saferMode.verifyTitle), findsOneWidget);
      // המסך עצמו כלל לא נבנה — גם לא מוסתר מאחורי הדיאלוג.
      expect(screen(SettingsScreen), findsNothing);
    });

    testWidgets('ביטול הדיאלוג משאיר את המשתמש בדף הבית', (tester) async {
      await lockSettings(tester);
      await pumpShell(tester);

      await tapNav(tester, shell.navSettings);
      await tester.pump();
      await tester.tap(find.text(stringsOf().common.cancel));
      await tester.pump();

      expect(screen(SettingsScreen), findsNothing);
      expect(screen(HomeScreen), findsOneWidget);
    });

    testWidgets('סיסמה שגויה אינה פותחת את המסך', (tester) async {
      await lockSettings(tester);
      await pumpShell(tester);

      await tapNav(tester, shell.navSettings);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.text(stringsOf().common.confirm));
      await tester.pump();

      expect(screen(SettingsScreen), findsNothing);
      // הדיאלוג נשאר פתוח — מי שטעה מנסה שוב.
      expect(find.text(stringsOf().saferMode.verifyTitle), findsOneWidget);
    });

    testWidgets('הסיסמה הנכונה פותחת, וכניסה חוזרת אינה נשאלת שוב', (
      tester,
    ) async {
      await lockSettings(tester);
      await pumpShell(tester);

      await tapNav(tester, shell.navSettings);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text(stringsOf().common.confirm));
      await tester.pump();

      expect(screen(SettingsScreen), findsOneWidget);

      // אימות אחד מחזיק להרצה — יציאה וחזרה אינן מבקשות סיסמה שוב.
      await tapNav(tester, shell.navHome);
      await tapNav(tester, shell.navSettings);
      await tester.pump();

      expect(find.text(stringsOf().saferMode.verifyTitle), findsNothing);
      expect(screen(SettingsScreen), findsOneWidget);
    });

    testWidgets('בלי סיסמה שמורה המתג אינו נועל כלום', (tester) async {
      // קובץ שנערך ביד יכול להדליק את המתג בלי סיסמה — וזה אינו נועל.
      await tester.runAsync(
        () => settings.update(
          const AppSettings(autoCheckUpdates: false, saferModeEnabled: true),
        ),
      );
      await pumpShell(tester);

      await tapNav(tester, shell.navSettings);
      await tester.pump();

      expect(find.text(stringsOf().saferMode.verifyTitle), findsNothing);
      expect(screen(SettingsScreen), findsOneWidget);
    });
  });

  group("בדיקת עדכון הלאנצ'ר מהמראה", () {
    Future<LauncherUpdateStatus> statusAfterStart(WidgetTester tester) async {
      LauncherUpdateController launcher() =>
          tester.widget<HomeScreen>(screen(HomeScreen)).launcherUpdate;
      for (var i = 0;
          i < 40 && launcher().status == LauncherUpdateStatus.idle;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      return launcher().status;
    }

    testWidgets('רצה בעלייה גם כשבדיקת העדכונים האוטומטית כבויה', (
      tester,
    ) async {
      await pumpShell(tester);
      expect(await statusAfterStart(tester), isNot(LauncherUpdateStatus.idle));
    });

    testWidgets('כונן לקריאה בלבד: אינה רצה', (tester) async {
      await pumpShell(tester, readOnly: true);
      expect(await statusAfterStart(tester), LauncherUpdateStatus.idle);
    });

    final source = _appShellSource();

    test('הבדיקה הידנית ברשת קוראת גם את המראה, לפני ההצצה', () {
      final start = source.indexOf('Future<void> checkOnline() async {');
      final body = source.substring(
        start,
        source.indexOf('Future.wait', start),
      );
      expect(start, greaterThan(-1));
      expect(body, contains('await _launcherFlow.checkMirror()'));
    });
  });

  group('סגירת החלון בזמן פעולה ארוכה', () {
    for (final language in AppLanguage.values) {
      for (final installingLibrary in [true, false]) {
        testWidgets(
            '$language: אישור וביטול סגירה בזמן '
            '${installingLibrary ? 'עדכון ספרייה' : 'התקנת אוצריא'}',
            (tester) async {
          await pumpShell(tester, language: language, readOnly: true);
          addTearDown(LauncherCrashSession.resetForTest);
          final home = tester.widget<HomeScreen>(screen(HomeScreen));
          if (installingLibrary) {
            home.library.status = LibraryModuleStatus.updating;
          } else {
            home.otzaria.status = OtzariaModuleStatus.installing;
          }
          final t = AppL10n.stringsFor(language).shell;
          for (final approved in [false, true]) {
            bool? result;
            final pending = LauncherCrashSession.closeGuard!()
                .then((allowed) => result = allowed);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));

            expect(find.text(t.closeWhileBusyTitle), findsOneWidget);
            expect(find.text(t.closeWhileInstallingPrompt), findsOneWidget);
            expect(result, isNull);

            await tester.tap(find.text(approved
                ? t.closeWhileInstallingConfirm
                : t.closeWhileBusyKeepGoing));
            await tester.pump(const Duration(milliseconds: 300));

            expect(await pending, approved);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('המסגרת רושמת שומר סגירה שמאשר כשאין פעולה, ומסירה בפירוק', (
      tester,
    ) async {
      await pumpShell(tester);
      final guard = LauncherCrashSession.closeGuard;
      expect(guard, isNotNull);
      expect(await guard!(), isTrue);

      await tester.pumpWidget(const SizedBox());
      expect(LauncherCrashSession.closeGuard, isNull);
    });

    final source = _appShellSource();
    final start = source.indexOf('Future<bool> _confirmClose() async {');
    final body = source.substring(start, source.indexOf('\n  }\n', start));

    test('גוף השומר נמצא', () => expect(start, greaterThan(-1)));

    test('שואל רק בזמן פעולה ארוכה', () {
      expect(body, contains('!_longTaskRunning) return true'));
      expect(body, contains('showWarningDialog'));
    });

    test('הורדה מבוטלת ומחכים לשחזור לפני הסגירה', () {
      expect(body, contains('await _downloads.cancelAndWait()'));
    });
  });
}

/// "אוצריא סגורה", בלי להריץ `tasklist` — ראו ה-setUp.
class _NeverRunningLocator extends RunningOtzariaLocator {
  const _NeverRunningLocator();

  @override
  Future<RunningOtzariaProbe> probe() async =>
      (isRunning: false, launchPath: null);
}

/// אוצריא שנסגרת באמצע הבדיקה: [isRunning] מוחלף בין בדיקה לבדיקה.
/// [probes] סופר דגימות, כדי לאמת גם שהרענון המחזורי **נכבה**.
class _MutableLocator extends RunningOtzariaLocator {
  _MutableLocator({required this.isRunning});

  bool isRunning;
  int probes = 0;

  @override
  Future<RunningOtzariaProbe> probe() async {
    probes++;
    return (isRunning: isRunning, launchPath: null);
  }

  @override
  Future<bool?> waitForExit(Duration timeout) async => null;
}

/// תור משוב בזיכרון לבדיקות המסגרת — בלי דיסק ובלי רשת.
class _ShellFeedback extends SearchFeedbackTransport {
  _ShellFeedback()
      : super('unused',
            client: MockClient((_) async => http.Response('{}', 200)));

  bool consent = true;
  bool online = true;
  bool closed = false;
  int sourceEvents = 2;
  int carriedEvents = 0;
  int collections = 0;
  int uploads = 0;
  int counts = 0;
  int sent = 0;
  DateTime? storedRetryAt;
  Completer<void>? uploadGate;

  @override
  Future<int> pendingForCollection(String sourceDirectory) async =>
      sourceEvents;

  @override
  Future<int> count() async {
    counts++;
    return carriedEvents;
  }

  @override
  Future<int> collect(String sourceDirectory,
      {required Future<bool> Function() mayCollect}) async {
    collections++;
    if (!await mayCollect()) return 0;
    final collected = sourceEvents;
    carriedEvents += collected;
    sourceEvents = 0;
    return collected;
  }

  @override
  Future<DateTime?> retryAt() async => storedRetryAt;

  @override
  Future<SearchFeedbackUploadResult> upload() async {
    uploads++;
    await uploadGate?.future;
    if (!online) {
      storedRetryAt = DateTime.now().add(const Duration(minutes: 2));
      return (sent: 0, rejected: 0, remaining: carriedEvents);
    }
    sent += carriedEvents;
    carriedEvents = 0;
    storedRetryAt = null;
    return (sent: sent, rejected: 0, remaining: 0);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

/// תור הדיווחים של אוצריא בזיכרון: איסוף מעביר את [pending] ל-[outbox].
class _ShellReportQueue implements OtzariaReportQueue {
  final outbox = _ShellOutbox();
  int pending = 0;
  int collects = 0;

  @override
  Future<int> countSendable() async => pending;

  @override
  Future<QueueCollectResult> collectTo(ReportOutbox outbox) async {
    collects++;
    final n = pending;
    for (var i = 0; i < n; i++) {
      await outbox.write(
        'r${this.outbox.reports.length}',
        utf8.encode(jsonEncode(OutboxReport.fileJson(
          reportId: 'r${this.outbox.reports.length}',
          bookTitle: 'ספר',
          createdAt: '2026-09-01T10:00:00Z',
          body: const {},
        ))),
      );
    }
    pending = 0;
    return (collected: n, error: null);
  }
}

class _ShellOutbox implements ReportOutbox {
  final reports = <OutboxReport>[];

  @override
  Future<List<OutboxReport>> list() async => List.of(reports);

  @override
  Future<int> count() async => reports.length;

  @override
  Future<Uint8List> requestBody(OutboxReport report) async =>
      Uint8List.fromList(utf8.encode('{}'));

  @override
  Future<void> remove(OutboxReport report) async =>
      reports.removeWhere((r) => r.reportId == report.reportId);

  @override
  Future<void> write(String reportId, Uint8List fileBytes) async {
    reports.removeWhere((r) => r.reportId == reportId);
    reports.add(OutboxReport.fromJson(
      jsonDecode(utf8.decode(fileBytes)) as Map<String, dynamic>,
      filePath: reportId,
    ));
  }

  @override
  Future<void> discard(String reportId) async =>
      reports.removeWhere((r) => r.reportId == reportId);
}
