import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:error_reports_manager/error_reports_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_app/src/app_report/launcher_crash_session.dart';
import 'package:launcher_app/src/services/app_logger.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String lockPath;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('launcher_session_');
    lockPath = p.join(tmp.path, UncleanExitDetector.lockFileName);
    await LauncherCrashSession.detectAndStartSession(
      logsDirectory: tmp.path,
      version: '0.25',
    );
    expect(File(lockPath).existsSync(), isTrue);
  });

  tearDown(() async {
    LauncherCrashSession.resetForTest();
    await AppLogger.maybeInstance?.flush();
    AppLogger.resetForTest();
    tmp.deleteSync(recursive: true);
  });

  group('exitCleanly', () {
    test('מוחק את הנעילה ויוצא עם 0', () async {
      final codes = <int>[];
      await LauncherCrashSession.exitCleanly(codes.add);
      expect(File(lockPath).existsSync(), isFalse);
      expect(codes, [0]);
    });

    test('Elevation ו-LauncherSelfInstaller יוצאים רק דרכו', () {
      for (final path in [
        'lib/src/services/elevation.dart',
        'lib/src/self_update/launcher_self_installer.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('_defaultQuit() => LauncherCrashSession.exitCleanly()'),
          reason: path,
        );
        expect(source, isNot(contains('exit(0)')), reason: path);
      }
    });
  });

  group('closeWindow', () {
    test('מוחק את הנעילה ואז משמיד את החלון', () async {
      var destroyed = 0;
      final codes = <int>[];
      await LauncherCrashSession.closeWindow(
        destroy: () async {
          // הנעילה כבר נמחקה כשההשמדה מתחילה.
          expect(File(lockPath).existsSync(), isFalse);
          destroyed++;
        },
        exitProcess: codes.add,
      );
      expect(destroyed, 1);
      expect(codes, [0]);
    });

    test('היציאה מהתהליך באה אחרי ההשמדה', () async {
      final order = <String>[];
      await LauncherCrashSession.closeWindow(
        destroy: () async => order.add('destroy'),
        exitProcess: (_) {
          expect(File(lockPath).existsSync(), isFalse);
          order.add('exit');
        },
      );
      expect(order, ['destroy', 'exit']);
    });

    test('השמדה שנכשלה: יוצאים מהתהליך, ה-X לא הופך לאינרטי', () async {
      final codes = <int>[];
      await LauncherCrashSession.closeWindow(
        destroy: () async => throw PlatformException(code: 'x'),
        exitProcess: codes.add,
      );
      expect(File(lockPath).existsSync(), isFalse);
      expect(codes, [0]);
    });
  });

  group('requestClose', () {
    test('בלי שומר: נסגר מיד', () async {
      final codes = <int>[];
      await LauncherCrashSession.requestClose(
        destroy: () async {},
        exitProcess: codes.add,
      );
      expect(File(lockPath).existsSync(), isFalse);
      expect(codes, [0]);
    });

    test('שומר שמסרב: החלון נשאר, הנעילה נשארת', () async {
      LauncherCrashSession.closeGuard = () async => false;
      var destroyed = 0;
      final codes = <int>[];
      await LauncherCrashSession.requestClose(
        destroy: () async => destroyed++,
        exitProcess: codes.add,
      );
      expect(destroyed, 0);
      expect(codes, isEmpty);
      expect(File(lockPath).existsSync(), isTrue);
    });

    test('שומר שמאשר: נסגר רק אחרי שהוא סיים', () async {
      final order = <String>[];
      LauncherCrashSession.closeGuard = () async {
        await Future<void>.delayed(Duration.zero);
        order.add('guard');
        return true;
      };
      await LauncherCrashSession.requestClose(
        destroy: () async => order.add('destroy'),
        exitProcess: (_) => order.add('exit'),
      );
      expect(order, ['guard', 'destroy', 'exit']);
    });

    test('שומר שנכשל: נסגר בכל זאת', () async {
      LauncherCrashSession.closeGuard = () async => throw StateError('x');
      final codes = <int>[];
      await LauncherCrashSession.requestClose(
        destroy: () async {},
        exitProcess: codes.add,
      );
      expect(codes, [0]);
    });

    test('לחיצה שנייה בזמן שהשומר ממתין אינה פותחת שאלה נוספת', () async {
      final answer = Completer<bool>();
      var asked = 0;
      LauncherCrashSession.closeGuard = () {
        asked++;
        return answer.future;
      };
      final codes = <int>[];
      final first = LauncherCrashSession.requestClose(
        destroy: () async {},
        exitProcess: codes.add,
      );
      await LauncherCrashSession.requestClose(
        destroy: () async {},
        exitProcess: codes.add,
      );
      expect(asked, 1);
      expect(codes, isEmpty);
      answer.complete(false);
      await first;
      expect(codes, isEmpty);
    });

    test('אישור יחיד: בקשות חוזרות בזמן שהחלון נסגר אינן שואלות שוב', () async {
      var asked = 0;
      LauncherCrashSession.closeGuard = () async {
        asked++;
        return true;
      };
      final destroying = Completer<void>();
      var destroyed = 0;
      final codes = <int>[];
      Future<void> request() => LauncherCrashSession.requestClose(
            destroy: () {
              destroyed++;
              return destroying.future;
            },
            exitProcess: codes.add,
          );

      final first = request();
      await pumpEventQueue();
      for (var i = 0; i < 3; i++) {
        await request();
        await pumpEventQueue();
      }
      expect(asked, 1);
      expect(destroyed, 1);

      destroying.complete();
      await first;
      expect(codes, [0]);
      expect(asked, 1);
    });

    test('המשך: בקשה חדשה שואלת פעם אחת, ואישור סוגר אחרי אישור יחיד',
        () async {
      final answers = [false, true];
      var asked = 0;
      LauncherCrashSession.closeGuard = () async => answers[asked++];
      final codes = <int>[];
      Future<void> request() => LauncherCrashSession.requestClose(
            destroy: () async {},
            exitProcess: codes.add,
          );

      await request();
      expect(asked, 1);
      expect(codes, isEmpty);

      await request();
      expect(asked, 2);
      expect(codes, [0]);
    });
  });

  group('installCloseHooks', () {
    const channel = MethodChannel('window_manager');
    final calls = <String>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> nativeClose() async {
      const codec = StandardMethodCodec();
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'window_manager',
        codec.encodeMethodCall(
          const MethodCall('onEvent', {'eventName': 'close'}),
        ),
        (_) {},
      );
    }

    test('preventClose נדלק, ואירוע close מוחק את הנעילה וסוגר', () async {
      if (!LauncherCrashSession.isSupported) return;
      final codes = <int>[];
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);
      expect(calls, contains('setPreventClose'));

      await nativeClose();
      await pumpEventQueue();
      expect(File(lockPath).existsSync(), isFalse);
      expect(calls, contains(Platform.isWindows ? 'hide' : 'destroy'));
      expect(codes, [0]);
    });

    test('Windows: יוצאים בלי להתחיל את כיבוי מנוע Flutter', () async {
      if (!Platform.isWindows) return;
      final codes = <int>[];
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);

      await nativeClose();
      await pumpEventQueue();

      expect(calls, contains('hide'));
      expect(calls, isNot(contains('destroy')));
      expect(File(lockPath).existsSync(), isFalse);
      expect(codes, [0]);
    });

    test('Windows: כשל בהסתרה נרשם והיציאה עדיין משלימה', () async {
      if (!Platform.isWindows) return;
      final logger = await AppLogger.init(tmp.path);
      final exited = Completer<int>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'hide') throw PlatformException(code: 'hide-failed');
        return null;
      });
      await LauncherCrashSession.installCloseHooks(
        exitProcess: exited.complete,
      );

      await nativeClose();

      expect(await exited.future, 0);
      expect(File(lockPath).existsSync(), isFalse);
      expect(calls, isNot(contains('destroy')));
      expect(File(logger.filePath).readAsStringSync(), contains('hide-failed'));
    });

    test('Windows: 25 בקשות אחרי אישור מתחילות סגירה אחת בלבד', () async {
      if (!Platform.isWindows) return;
      final hidden = Completer<void>();
      final codes = <int>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'hide') await hidden.future;
        return null;
      });
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);

      for (var i = 0; i < 25; i++) {
        await nativeClose();
      }
      final lifecycleResponse =
          await WidgetsBinding.instance.handleRequestAppExit();
      final hideCalls = calls.where((call) => call == 'hide').length;
      hidden.complete();
      await pumpEventQueue();

      expect(hideCalls, 1);
      expect(lifecycleResponse, AppExitResponse.cancel);
      expect(codes, [0]);
      expect(File(lockPath).existsSync(), isFalse);
    });

    test('Windows: אישור יציאה של Flutter מאפשר את אירוע סגירת החלון שאחריו',
        () async {
      if (!Platform.isWindows) return;
      final codes = <int>[];
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);

      final response = await WidgetsBinding.instance.handleRequestAppExit();
      expect(response, AppExitResponse.exit);
      await nativeClose();
      await pumpEventQueue();

      expect(calls.where((call) => call == 'hide'), hasLength(1));
      expect(codes, [0]);
      expect(File(lockPath).existsSync(), isFalse);
    });

    test('Windows: כל תור הלוג נכתב לפני היציאה, גם שורה שנוספת בהסתרה',
        () async {
      if (!Platform.isWindows) return;
      final logger = await AppLogger.init(tmp.path);
      for (var i = 0; i < 400; i++) {
        logger.info('close-stress-$i');
      }
      final exited = Completer<int>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'hide') {
          logger.info('last-line-during-hide');
        }
        return null;
      });
      await LauncherCrashSession.installCloseHooks(exitProcess: (code) {
        final content = File(logger.filePath).readAsStringSync();
        for (var i = 0; i < 400; i++) {
          expect(content, contains('close-stress-$i\n'));
        }
        expect(content, contains('last-line-during-hide'));
        expect(File(lockPath).existsSync(), isFalse);
        exited.complete(code);
      });

      await nativeClose();

      expect(await exited.future, 0);
      expect(calls, isNot(contains('destroy')));
    });

    test('25 בקשות סגירה בזמן אישור ממתין שואלות פעם אחת ומחכות לתשובה',
        () async {
      if (!LauncherCrashSession.isSupported) return;
      final approval = Completer<bool>();
      final exited = Completer<int>();
      var asked = 0;
      LauncherCrashSession.closeGuard = () {
        asked++;
        return approval.future;
      };
      await LauncherCrashSession.installCloseHooks(
          exitProcess: exited.complete);

      for (var i = 0; i < 25; i++) {
        await nativeClose();
      }
      expect(asked, 1);
      expect(exited.isCompleted, isFalse);
      expect(File(lockPath).existsSync(), isTrue);
      expect(calls, isNot(contains('hide')));
      expect(calls, isNot(contains('destroy')));

      approval.complete(true);

      expect(await exited.future, 0);
      expect(File(lockPath).existsSync(), isFalse);
      expect(calls.where((call) => call == 'hide' || call == 'destroy'),
          hasLength(1));
    });

    test('אירוע close עובר דרך השומר: סירוב משאיר את החלון', () async {
      if (!LauncherCrashSession.isSupported) return;
      final codes = <int>[];
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);
      var asked = 0;
      LauncherCrashSession.closeGuard = () async {
        asked++;
        return false;
      };

      await nativeClose();
      await pumpEventQueue();
      expect(asked, 1);
      expect(calls, isNot(contains('destroy')));
      expect(calls, isNot(contains('hide')));
      expect(codes, isEmpty);
      expect(File(lockPath).existsSync(), isTrue);
    });

    test('ביטול סגירה מאפשר ניסיון נוסף עם אישור', () async {
      if (!LauncherCrashSession.isSupported) return;
      final codes = <int>[];
      var approved = false;
      var asked = 0;
      LauncherCrashSession.closeGuard = () async {
        asked++;
        return approved;
      };
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);

      await nativeClose();
      await pumpEventQueue();
      expect(codes, isEmpty);
      expect(File(lockPath).existsSync(), isTrue);

      approved = true;
      await nativeClose();
      await pumpEventQueue();

      expect(asked, 2);
      expect(codes, [0]);
      expect(calls.where((call) => call == 'hide' || call == 'destroy'),
          hasLength(1));
      expect(File(lockPath).existsSync(), isFalse);
    });

    test('בקשת יציאה (Cmd+Q) עוברת דרך השומר: סירוב מבטל', () async {
      if (!LauncherCrashSession.isSupported) return;
      await LauncherCrashSession.installCloseHooks(exitProcess: (_) {});
      var asked = 0;
      LauncherCrashSession.closeGuard = () async {
        asked++;
        return false;
      };

      final response = await WidgetsBinding.instance.handleRequestAppExit();
      expect(asked, 1);
      expect(response, AppExitResponse.cancel);
      expect(File(lockPath).existsSync(), isTrue);
    });

    test('בקשת יציאה עם שומר שמאשר: נמחקת הנעילה ויוצאים', () async {
      if (!LauncherCrashSession.isSupported) return;
      await LauncherCrashSession.installCloseHooks(exitProcess: (_) {});
      LauncherCrashSession.closeGuard = () async => true;

      final response = await WidgetsBinding.instance.handleRequestAppExit();
      expect(response, AppExitResponse.exit);
      expect(File(lockPath).existsSync(), isFalse);
    });

    test('בקשת יציאה בזמן שהשומר של X ממתין: מבוטלת בלי שאלה נוספת', () async {
      if (!LauncherCrashSession.isSupported) return;
      final codes = <int>[];
      await LauncherCrashSession.installCloseHooks(exitProcess: codes.add);
      final answer = Completer<bool>();
      var asked = 0;
      LauncherCrashSession.closeGuard = () {
        asked++;
        return answer.future;
      };

      final first = LauncherCrashSession.requestClose(
        destroy: () async {},
        exitProcess: codes.add,
      );
      final response = await WidgetsBinding.instance.handleRequestAppExit();
      expect(asked, 1);
      expect(response, AppExitResponse.cancel);
      expect(File(lockPath).existsSync(), isTrue);
      answer.complete(false);
      await first;
      expect(codes, isEmpty);
    });
  });

  group('בדיקת תהליך', () {
    test('Windows: התהליך הנוכחי חי, ותהליך שהסתיים מת', () async {
      if (!Platform.isWindows) return;
      expect(LauncherCrashSession.isProcessAlive(pid), isTrue);

      // ב-Windows pid הוא כפולה של 4, ולכן 99999 אינו יכול להתקיים:
      // OpenProcess נכשל ב-ERROR_INVALID_PARAMETER.
      expect(LauncherCrashSession.isProcessAlive(99999), isFalse);

      // ותהליך שהסתיים. ב-Windows pid ממוחזר מהר, ותהליך אחר עלול לתפוס אותו
      // תחת עומס — לכן מספיק שאחד משלושה נראה מת.
      var sawDead = false;
      for (var i = 0; i < 3 && !sawDead; i++) {
        final child = await Process.start('cmd', ['/c', 'exit']);
        await child.exitCode;
        sawDead = !LauncherCrashSession.isProcessAlive(child.pid);
      }
      expect(sawDead, isTrue);
    });

    test('מק ולינוקס: kill(pid, 0) על התהליך הנוכחי', () {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      expect(LauncherCrashSession.isProcessAlive(pid), isTrue);
    });
  });

  group('סגירה מסודרת לפני שהזיהוי הסתיים', () {
    setUp(() {
      LauncherCrashSession.resetForTest();
      File(lockPath).deleteSync();
    });

    test('לא נכתבת נעילה שתשרוד', () async {
      final begun = LauncherCrashSession.begin(
        logsDirectory: tmp.path,
        version: '0.25',
      );
      // הזיהוי אסינכרוני ועוד לא הסתיים; אין עדיין detector שימחק.
      LauncherCrashSession.markCleanExitSync();
      await begun;
      expect(File(lockPath).existsSync(), isFalse);
    });

    test('נעילה ישנה של קריסה נשארת, ואינה נדרסת בנעילה חדשה', () async {
      File(lockPath).writeAsStringSync(
        jsonEncode({
          'pid': 1,
          'version': '0.24',
          'startedAt': DateTime.utc(2026, 10, 1).toIso8601String(),
          'host': UncleanExitDetector.localHost(),
        }),
      );
      final begun = LauncherCrashSession.begin(
        logsDirectory: tmp.path,
        version: '0.25',
        isProcessAlive: (_) => false,
      );
      LauncherCrashSession.markCleanExitSync();
      await begun;
      final lock = SessionLock.tryParse(File(lockPath).readAsStringSync())!;
      expect(lock.pid, 1);
    });
  });

  test('נעילה ממחשב אחר נדרסת בלי הצעה', () async {
    File(lockPath).writeAsStringSync(
      jsonEncode({
        'pid': 1,
        'version': '0.24',
        'startedAt': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
        'host': 'SOME-OTHER-PC',
      }),
    );
    File(p.join(tmp.path, 'launcher.log')).writeAsStringSync(
      '${DateTime.now().subtract(const Duration(minutes: 30)).toIso8601String()}'
      ' [ERROR] ${LauncherLogFormat.zoneError}\ntype: StateError\n',
    );
    final candidate = await LauncherCrashSession.detectAndStartSession(
      logsDirectory: tmp.path,
      version: '0.25',
      isProcessAlive: (_) => false,
    );
    expect(candidate, isNull);
    final lock = SessionLock.tryParse(File(lockPath).readAsStringSync())!;
    expect(lock.host, UncleanExitDetector.localHost());
  });
}
