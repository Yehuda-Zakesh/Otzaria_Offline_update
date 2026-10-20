import 'dart:async';
import 'dart:io';

import 'package:custom_apps_manager/custom_apps_manager.dart';
import 'package:otzaria_downloads/otzaria_downloads.dart' show ElevatedProcess;
import 'package:otzaria_l10n/otzaria_l10n.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// מריץ מדומה — הבדיקות אינן מריצות installer אמיתי על המחשב שמריץ אותן.
class _FakeRunner {
  final calls = <({String executable, List<String> arguments})>[];
  int exitCode = 0;

  /// כך נראה מתקין שהמניפסט שלו `requireAdministrator`.
  bool requiresElevation = false;

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add((executable: executable, arguments: arguments));
    if (requiresElevation) {
      throw ProcessException(executable, arguments,
          'The requested operation requires elevation', 740);
    }
    return ProcessResult(1, exitCode, '', exitCode == 0 ? '' : 'boom');
  }
}

/// ShellExecute מדומה — רושם גם אם ביקשו הרמה ושורה גולמית.
class _FakeShell {
  final calls = <({
    String executable,
    List<String> arguments,
    bool elevate,
    bool rawLastArgument,
  })>[];
  int exitCode = 0;

  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    required bool elevate,
    required bool rawLastArgument,
  }) async {
    calls.add((
      executable: executable,
      arguments: arguments,
      elevate: elevate,
      rawLastArgument: rawLastArgument,
    ));
    return ProcessResult(1, exitCode, '', '');
  }
}

void main() {
  test('בחירת חבילה לפי שם מציעה רק EXE, MSI ו-ZIP', () {
    for (final name in ['Setup.exe', 'Setup.MSI', 'portable.ZIP']) {
      expect(CustomAppInstaller.supportsPackageName(name), isTrue);
    }
    for (final name in ['sources.tar.xz', 'app.exe.sha256', 'app.dmg']) {
      expect(CustomAppInstaller.supportsPackageName(name), isFalse);
    }
  });

  late String root;
  late String downloads;
  late _FakeRunner runner;
  late _FakeShell elevated;
  late CustomAppInstaller installer;
  late bool alreadyElevated;

  setUp(() {
    alreadyElevated = false;
    root = tempMirrorRoot();
    downloads = p.join(root, 'Downloads');
    runner = _FakeRunner();
    elevated = _FakeShell();
    installer = CustomAppInstaller(
      processRunner: runner.call,
      shellRunner: elevated.call,
      isElevated: () async => alreadyElevated,
      downloadsDir: downloads,
    );
  });

  /// קובץ עם הסימן שמזהה framework מסוים — סוג ההתקנה נקבע מהתוכן, ולכן
  /// בדיקה עם קובץ ריק לא הייתה בודקת כלום.
  String writeBytes(String name, List<int> bytes) {
    final path = p.join(root, 'mirror', name);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return path;
  }

  String innoSetup() => writeBytes(
        'setup.exe',
        [...'MZ'.codeUnits, ...List.filled(200, 0), ...'Inno Setup'.codeUnits],
      );

  String zipArchive([String name = 'portable.zip']) =>
      writeBytes(name, [0x50, 0x4B, 0x03, 0x04, ...'payload'.codeUnits]);

  String msi() => writeBytes(
        'app.msi',
        [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0],
      );

  group('קודי הצלחה של MSI', () {
    for (final code in [3010, 1641]) {
      test('$code הוא הצלחה שדורשת אתחול', () async {
        runner.exitCode = code;

        final outcome = await installer.install(
          descriptor: descriptor(),
          installerPath: msi(),
        );

        expect(outcome.kind, CustomInstallerKind.msi);
        expect(elevated.calls, isEmpty);
      });

      test('$code אינו הצלחה ב-Inno', () async {
        runner.exitCode = code;

        await expectLater(
          installer.install(
              descriptor: descriptor(), installerPath: innoSetup()),
          throwsA(isA<AppDescriptorException>()),
        );
      });
    }

    test('3010 מהרצה מורמת הוא הצלחה', () async {
      runner.exitCode = 1603;
      elevated.exitCode = 3010;

      final outcome = await installer.install(
          descriptor: descriptor(), installerPath: msi());

      expect(outcome.kind, CustomInstallerKind.msi);
    });
  });

  group('סוג ההתקנה נקבע מהקובץ, לא מהרשומה', () {
    test('התקנה רגילה של MSI משאירה את msiexec ואת קודי ההצלחה', () async {
      runner.exitCode = 3010;
      final app = AppDescriptor.fromJson({
        ...descriptor().toJson(),
        'install': {'interactive': true},
      });
      final path = msi();

      await installer.install(descriptor: app, installerPath: path);

      expect(runner.calls.single.executable, 'msiexec');
      expect(runner.calls.single.arguments, ['/i', path]);
    });

    AppDescriptor interactiveApp() => AppDescriptor.fromJson({
          ...descriptor().toJson(),
          'install': {'interactive': true},
        });

    for (final code in [1603, 1625, 1925]) {
      test('התקנה רגילה של MSI שנכשלה ב-$code אינה נפתחת שוב מורמת', () async {
        runner.exitCode = code;

        await expectLater(
          installer.install(descriptor: interactiveApp(), installerPath: msi()),
          throwsA(isA<AppDescriptorException>()
              .having((e) => e.message, 'message', contains('$code'))),
        );
        expect(runner.calls, hasLength(1));
        expect(elevated.calls, isEmpty);
      });
    }

    test('ביטול אשף MSI (1602) מדווח כביטול ואינו מורץ שוב', () async {
      runner.exitCode = 1602;

      await expectLater(
        installer.install(descriptor: interactiveApp(), installerPath: msi()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.installerCancelled,
        )),
      );
      expect(runner.calls, hasLength(1));
      expect(elevated.calls, isEmpty);
    });

    test('MSI שקט: 1603 ואז 1602 מההרצה המורמת מדווח כביטול', () async {
      runner.exitCode = 1603;
      elevated.exitCode = 1602;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: msi()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.installerCancelled,
        )),
      );
      expect(elevated.calls.single.elevate, isTrue);
    });

    test('ביטול אשף MSI אחרי הרמה בעקבות 740 מדווח כביטול', () async {
      runner.requiresElevation = true;
      elevated.exitCode = 1602;

      await expectLater(
        installer.install(descriptor: interactiveApp(), installerPath: msi()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.installerCancelled,
        )),
      );
      expect(elevated.calls.single.elevate, isTrue);
      expect(elevated.calls.single.arguments, ['/i', msi()]);
    });

    test('התקנה רגילה אינה מריצה ארכיון או קובץ נייד', () async {
      for (final portable in [false, true]) {
        final app = AppDescriptor.fromJson({
          ...descriptor().toJson(),
          'install': {'interactive': true, 'portable': portable},
        });
        final outcome = await installer.install(
          descriptor: app,
          installerPath: portable ? innoSetup() : zipArchive(),
        );
        expect(outcome.copiedPath, isNotNull);
      }
      expect(runner.calls, isEmpty);
      expect(elevated.calls, isEmpty);
    });

    for (final elevate in [false, true]) {
      test('התקנה רגילה של Inno אינה שולחת דגלים, הרמה=$elevate', () async {
        runner.requiresElevation = elevate;
        final app = AppDescriptor.fromJson({
          ...descriptor(installDir: r'C:\Apps\X').toJson(),
          'install': {'dir': r'C:\Apps\X', 'interactive': true},
        });

        final outcome = await installer.install(
          descriptor: app,
          installerPath: innoSetup(),
        );

        expect(runner.calls.single.arguments, isEmpty);
        expect(outcome.kind, CustomInstallerKind.innoSetup);
        if (elevate) {
          expect(elevated.calls.single.arguments, isEmpty);
          expect(elevated.calls.single.elevate, isTrue);
        }
      });
    }

    test('Inno מזוהה, ומורצות הדגלים השקטים שלו', () async {
      await installer.install(
        descriptor: descriptor(installDir: r'C:\Apps\X'),
        installerPath: innoSetup(),
      );

      expect(runner.calls.single.arguments, contains('/VERYSILENT'));
      expect(runner.calls.single.arguments.last, r'/DIR=C:\Apps\X');
    });

    test('NSIS מזוהה, ו-/D= נשאר אחרון', () async {
      final path = writeBytes(
        'setup.exe',
        [...'MZ'.codeUnits, ...List.filled(200, 0), ...'Nullsoft'.codeUnits],
      );

      await installer.install(
        descriptor: descriptor(installDir: r'C:\Apps\X'),
        installerPath: path,
      );

      expect(runner.calls.single.arguments.first, '/S');
      expect(runner.calls.single.arguments.last, r'/D=C:\Apps\X');
    });

    test('MSI מזוהה ומורץ דרך msiexec', () async {
      final path = writeBytes(
        'app.msi',
        [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0],
      );

      await installer.install(descriptor: descriptor(), installerPath: path);

      expect(runner.calls.single.executable, 'msiexec');
    });

    // הנפילה הזו אינה כישלון — היא הסיבה שאין בורר סוג בממשק.
    test('קובץ שלא זוהה — מורץ בלי דגלים, והמשתמש מסיים בעצמו', () async {
      final path = writeBytes('mystery.exe', List.filled(2048, 0x41));

      await installer.install(descriptor: descriptor(), installerPath: path);

      expect(runner.calls.single.executable, path);
      expect(runner.calls.single.arguments, isEmpty);
    });

    test('interactive מסומן כלא-שקט', () {
      expect(CustomInstallerKind.interactive.isSilent, isFalse);
      expect(CustomInstallerKind.innoSetup.isSilent, isTrue);
      expect(CustomInstallerKind.zipPortable.isSilent, isFalse);
    });
  });

  test('קובץ התקנה חסר — נופל לפני שמריצים כלום', () async {
    await expectLater(
      installer.install(
        descriptor: descriptor(),
        installerPath: p.join(root, 'אין-כזה.exe'),
      ),
      throwsA(isA<AppDescriptorException>()),
    );
    expect(runner.calls, isEmpty);
  });

  for (final interactive in [false, true]) {
    test('ארכיון המקור של Audacity אינו מורץ, אשף=$interactive', () async {
      const name = 'audacity-sources-4.0.1.tar.xz';
      final path = writeBytes(name, [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]);
      final app = AppDescriptor.fromJson({
        ...descriptor().toJson(),
        'install': {'interactive': interactive},
      });

      await expectLater(
        installer.install(descriptor: app, installerPath: path),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          allOf(contains(name), contains('EXE'), contains('MSI')),
        )),
      );
      expect(runner.calls, isEmpty);
      expect(elevated.calls, isEmpty);
    });
  }

  test('קוד יציאה שאינו אפס — ההודעה נושאת אותו ואת הפלט', () async {
    runner.exitCode = 1603;

    await expectLater(
      installer.install(descriptor: descriptor(), installerPath: innoSetup()),
      throwsA(
        isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          allOf(contains('1603'), contains('boom')),
        ),
      ),
    );
  });

  group('מתקין שדורש מנהל', () {
    test('שגיאה 740 — מורץ שוב עם UAC, באותה פקודה בדיוק', () async {
      runner.requiresElevation = true;
      final path = innoSetup();

      await installer.install(
        descriptor: descriptor(installDir: r'C:\Apps\X'),
        installerPath: path,
      );

      expect(elevated.calls.single.executable, path);
      expect(elevated.calls.single.arguments, runner.calls.single.arguments);
      expect(elevated.calls.single.elevate, isTrue);
    });

    test('סירוב ל-UAC — הודעה משלו, לא "קוד 1223"', () async {
      runner.requiresElevation = true;
      elevated.exitCode = ElevatedProcess.cancelledCode;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: innoSetup()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.installerElevationDeclined,
        )),
      );
    });

    test('כשל של ההרצה המורמת — נושא את קוד היציאה', () async {
      runner.requiresElevation = true;
      elevated.exitCode = 1603;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: innoSetup()),
        throwsA(isA<AppDescriptorException>()
            .having((e) => e.message, 'message', contains('1603'))),
      );
    });

    test('MSI שנכשל ב-1603 בלי הרשאות — מורץ שוב מורם', () async {
      runner.exitCode = 1603;

      final outcome = await installer.install(
          descriptor: descriptor(), installerPath: msi());

      expect(runner.calls.single.executable, 'msiexec');
      expect(elevated.calls.single.executable, 'msiexec');
      expect(elevated.calls.single.arguments, runner.calls.single.arguments);
      expect(elevated.calls.single.elevate, isTrue);
      expect(outcome.kind, CustomInstallerKind.msi);
    });

    test('MSI שנכשל ב-1625 בלי הרשאות — מורץ שוב מורם', () async {
      runner.exitCode = 1625;

      final outcome = await installer.install(
          descriptor: descriptor(), installerPath: msi());

      expect(elevated.calls.single.arguments, runner.calls.single.arguments);
      expect(elevated.calls.single.elevate, isTrue);
      expect(outcome.kind, CustomInstallerKind.msi);
    });

    for (final code in [1603, 1625, 1925]) {
      test('MSI שנכשל ב-$code כשהתהליך כבר מורם — אינו מורץ שוב', () async {
        alreadyElevated = true;
        runner.exitCode = code;

        await expectLater(
          installer.install(descriptor: descriptor(), installerPath: msi()),
          throwsA(isA<AppDescriptorException>().having(
            (e) => e.message,
            'message',
            allOf(contains('$code'), contains('boom')),
          )),
        );
        expect(elevated.calls, isEmpty);
      });
    }

    test('MSI שנכשל גם מורם — נושא את שני קודי היציאה', () async {
      runner.exitCode = 1925;
      elevated.exitCode = 1603;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: msi()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain
              .installerElevatedRetryFailed(1925, 1603, 'stderr: '),
        )),
      );
    });

    test('MSI ב-1625 שנכשל גם מורם — נושא את שני קודי היציאה', () async {
      runner.exitCode = 1625;
      elevated.exitCode = 1625;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: msi()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain
              .installerElevatedRetryFailed(1625, 1625, 'stderr: '),
        )),
      );
    });

    test('סירוב ל-UAC בניסיון החוזר של MSI — קוד היציאה הראשון נשמר', () async {
      runner.exitCode = 1603;
      elevated.exitCode = ElevatedProcess.cancelledCode;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: msi()),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.installerElevatedRetryDeclined(1603),
        )),
      );
    });

    test('Inno שנכשל ב-1603 אינו מורץ שוב', () async {
      runner.exitCode = 1603;

      await expectLater(
        installer.install(descriptor: descriptor(), installerPath: innoSetup()),
        throwsA(isA<AppDescriptorException>()),
      );
      expect(elevated.calls, isEmpty);
    });

    test('שגיאת הרצה אחרת אינה מורמת', () async {
      final failing = CustomAppInstaller(
        processRunner: (exe, args) async =>
            throw ProcessException(exe, args, 'not found', 2),
        shellRunner: elevated.call,
      );

      await expectLater(
        failing.install(descriptor: descriptor(), installerPath: innoSetup()),
        throwsA(isA<ProcessException>()),
      );
      expect(elevated.calls, isEmpty);
    });
  });

  // NSIS מעתיק את כל מה שאחרי `/D=` — כולל `"` סוגר שהיה נכנס לנתיב.
  group('NSIS עם רווח בתיקיית היעד', () {
    String nsisSetup() => writeBytes(
          'setup.exe',
          [...'MZ'.codeUnits, ...List.filled(200, 0), ...'Nullsoft'.codeUnits],
        );

    test('עובר דרך ShellExecute עם /D= גולמי, בלי הרמה מפורשת', () async {
      await installer.install(
        descriptor: descriptor(installDir: r'C:\Program Files\X'),
        installerPath: nsisSetup(),
      );

      expect(runner.calls, isEmpty);
      final call = elevated.calls.single;
      expect(call.arguments.last, r'/D=C:\Program Files\X');
      expect(call.rawLastArgument, isTrue);
      // ShellExecute מקפיץ UAC לבד כשהמניפסט דורש; runas היה מבקש תמיד.
      expect(call.elevate, isFalse);
    });

    test('סירוב ל-UAC גם כאן מקבל את ההודעה שלו', () async {
      elevated.exitCode = ElevatedProcess.cancelledCode;

      await expectLater(
        installer.install(
          descriptor: descriptor(installDir: r'C:\Program Files\X'),
          installerPath: nsisSetup(),
        ),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.installerElevationDeclined,
        )),
      );
    });

    test('נתיב בלי רווח — Process.run רגיל, כמו קודם', () async {
      await installer.install(
        descriptor: descriptor(installDir: r'C:\Apps\X'),
        installerPath: nsisSetup(),
      );

      expect(runner.calls, hasLength(1));
      expect(elevated.calls, isEmpty);
    });

    // Inno מבין מרכאות, ולכן `/DIR=` עם רווח נשאר במסלול הרגיל.
    test('Inno עם רווח אינו מושפע', () async {
      await installer.install(
        descriptor: descriptor(installDir: r'C:\Program Files\X'),
        installerPath: innoSetup(),
      );

      expect(runner.calls, hasLength(1));
      expect(elevated.calls, isEmpty);
    });
  });

  group('ארכיון — יורד לתיקיית ההורדות ואינו "מותקן"', () {
    test('מועתק לתיקיית ההורדות, בלי להריץ תהליך', () async {
      final outcome = await installer.install(
        descriptor: descriptor(),
        installerPath: zipArchive(),
      );

      expect(runner.calls, isEmpty);
      expect(outcome.kind, CustomInstallerKind.zipPortable);
      expect(outcome.isArchive, isTrue);
      expect(outcome.copiedPath, p.join(downloads, 'portable.zip'));
      expect(File(outcome.copiedPath!).existsSync(), isTrue);
    });

    test('אינו דורש מיקום התקנה — אין ל-ZIP כזה', () async {
      expect(descriptor().installDir, isNull);
      await installer.install(
        descriptor: descriptor(),
        installerPath: zipArchive(),
      );
      expect(File(p.join(downloads, 'portable.zip')).existsSync(), isTrue);
    });

    test('תיקיית ההורדות נוצרת אם אינה קיימת', () async {
      expect(Directory(downloads).existsSync(), isFalse);
      await installer.install(
        descriptor: descriptor(),
        installerPath: zipArchive('a.zip'),
      );
      expect(Directory(downloads).existsSync(), isTrue);
    });

    // דריסה שקטה של קובץ בהורדות היא בדיוק מה שמשתמש לא מצפה לו.
    test('קובץ קיים אינו נדרס — נוצר שם פנוי', () async {
      writeFile(p.join(downloads, 'portable.zip'), 'הישן');

      final outcome = await installer.install(
        descriptor: descriptor(),
        installerPath: zipArchive(),
      );

      expect(p.basename(outcome.copiedPath!), 'portable (2).zip');
      expect(
          File(p.join(downloads, 'portable.zip')).readAsStringSync(), 'הישן');
    });
  });

  group('קובץ נייד — התוכנה עצמה, ולא מתקין שלה', () {
    String portableExe() => innoSetup();

    test('מועתק ליעד שנבחר, בלי להריץ כלום', () async {
      final target = p.join(root, 'Tools');

      final outcome = await installer.install(
        descriptor: descriptor(portableFile: true),
        installerPath: portableExe(),
        copyToDir: target,
      );

      expect(runner.calls, isEmpty);
      expect(outcome.kind, CustomInstallerKind.portableFile);
      expect(outcome.isCopyOnly, isTrue);
      expect(outcome.isArchive, isFalse);
      expect(outcome.copiedPath, p.join(target, 'setup.exe'));
      expect(File(outcome.copiedPath!).existsSync(), isTrue);
    });

    test('בלי יעד — נופל לתיקיית ההורדות ולא לשום מקום מומצא', () async {
      final outcome = await installer.install(
        descriptor: descriptor(portableFile: true),
        installerPath: portableExe(),
      );

      expect(outcome.copiedPath, p.join(downloads, 'setup.exe'));
    });

    test('קובץ קיים אינו נדרס', () async {
      final target = p.join(root, 'Tools');
      writeFile(p.join(target, 'setup.exe'), 'הישן');

      final outcome = await installer.install(
        descriptor: descriptor(portableFile: true),
        installerPath: portableExe(),
        copyToDir: target,
      );

      expect(p.basename(outcome.copiedPath!), 'setup (2).exe');
      expect(File(p.join(target, 'setup.exe')).readAsStringSync(), 'הישן');
    });

    test('עדכון מחליף את קובץ ההרצה המוכר במקום ליצור עותק', () async {
      final target = p.join(root, 'Tools');
      writeFile(p.join(target, 'MyApp.exe'), 'הישן');

      final outcome = await installer.install(
        descriptor: descriptor(
          portableFile: true,
          detect: const AppDetectRules(exeName: 'MyApp.exe'),
        ),
        installerPath: portableExe(),
        copyToDir: target,
      );

      expect(outcome.copiedPath, p.join(target, 'MyApp.exe'));
      expect(
        File(outcome.copiedPath!).readAsBytesSync(),
        File(portableExe()).readAsBytesSync(),
      );
      expect(
        Directory(target).listSync().map((e) => p.basename(e.path)),
        ['MyApp.exe'],
      );
    });

    test('קובץ מוכר שפתוח כרגע — הודעה ייעודית, וה-.part נמחק', () async {
      final target = p.join(root, 'Tools');
      final existing = p.join(target, 'MyApp.exe');
      writeFile(existing, 'הישן');
      final locked = CustomAppInstaller(
        processRunner: runner.call,
        shellRunner: elevated.call,
        isElevated: () async => false,
        replaceFile: (source, to) async => throw FileSystemException(
          'Cannot rename file to $to',
          source.path,
          const OSError('Access is denied.', 5),
        ),
        downloadsDir: downloads,
      );

      await expectLater(
        locked.install(
          descriptor: descriptor(
            portableFile: true,
            detect: const AppDetectRules(exeName: 'MyApp.exe'),
          ),
          installerPath: portableExe(),
          copyToDir: target,
        ),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.portableFileInUse(
            'MyApp.exe',
            'Access is denied.',
          ),
        )),
      );
      expect(File('$existing.part').existsSync(), isFalse);
      expect(File(existing).readAsStringSync(), 'הישן');
      expect(
        Directory(target).listSync().map((e) => p.basename(e.path)),
        ['MyApp.exe'],
      );
    });

    test('קובץ מוכר שנכשל בלי OSError — הודעת החריגה מצורפת', () async {
      final target = p.join(root, 'Tools');
      writeFile(p.join(target, 'MyApp.exe'), 'הישן');
      final failing = CustomAppInstaller(
        processRunner: runner.call,
        shellRunner: elevated.call,
        isElevated: () async => false,
        replaceFile: (source, to) async =>
            throw FileSystemException('Cannot rename file', source.path),
        downloadsDir: downloads,
      );

      await expectLater(
        failing.install(
          descriptor: descriptor(
            portableFile: true,
            detect: const AppDetectRules(exeName: 'MyApp.exe'),
          ),
          installerPath: portableExe(),
          copyToDir: target,
        ),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          AppL10n.strings.customAppsDomain.portableFileInUse(
            'MyApp.exe',
            'Cannot rename file',
          ),
        )),
      );
    });

    test('כשל החלפה כשהקובץ המוכר אינו קיים — שגיאת העתקה רגילה', () async {
      final target = p.join(root, 'Tools');
      final failing = CustomAppInstaller(
        processRunner: runner.call,
        shellRunner: elevated.call,
        isElevated: () async => false,
        replaceFile: (source, to) async =>
            throw FileSystemException('Cannot rename file', source.path),
        downloadsDir: downloads,
      );

      await expectLater(
        failing.install(
          descriptor: descriptor(
            portableFile: true,
            detect: const AppDetectRules(exeName: 'MyApp.exe'),
          ),
          installerPath: portableExe(),
          copyToDir: target,
        ),
        throwsA(isA<AppDescriptorException>().having(
          (e) => e.message,
          'message',
          startsWith(AppL10n.strings.customAppsDomain.fileCopyFailed('')),
        )),
      );
      expect(Directory(target).listSync(), isEmpty);
    });

    test('שם מוכר שאינו exe או נושא תיקייה — רק שם הקובץ נלקח', () async {
      final target = p.join(root, 'Tools');

      final pdf = await installer.install(
        descriptor: descriptor(
          portableFile: true,
          detect: const AppDetectRules(exeName: 'MyApp.pdf'),
        ),
        installerPath: portableExe(),
        copyToDir: target,
      );
      expect(p.basename(pdf.copiedPath!), 'setup.exe');

      final nested = await installer.install(
        descriptor: descriptor(
          portableFile: true,
          detect: const AppDetectRules(exeName: r'..\..\Evil.exe'),
        ),
        installerPath: portableExe(),
        copyToDir: target,
      );
      expect(nested.copiedPath, p.join(target, 'Evil.exe'));
    });

    test('היעד אינו חל על ארכיון', () async {
      final outcome = await installer.install(
        descriptor: descriptor(),
        installerPath: zipArchive(),
        copyToDir: p.join(root, 'Tools'),
      );

      expect(outcome.copiedPath, p.join(downloads, 'portable.zip'));
    });

    test('קובץ נייד מסומן כלא-שקט — נפתח דיאלוג בחירת יעד', () {
      expect(CustomInstallerKind.portableFile.isSilent, isFalse);
      expect(CustomInstallerKind.portableFile.isCopyOnly, isTrue);
      expect(CustomInstallerKind.zipPortable.isCopyOnly, isTrue);
      expect(CustomInstallerKind.innoSetup.isCopyOnly, isFalse);
    });
  });

  test('בלי הזרקה, תיקיית ההורדות נגזרת מתיקיית הבית', () {
    final resolved =
        CustomAppInstaller(processRunner: runner.call).downloadsDir;
    expect(p.basename(resolved), 'Downloads');
  });
}
