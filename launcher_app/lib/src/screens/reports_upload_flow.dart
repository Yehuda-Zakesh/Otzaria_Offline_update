import 'package:flutter/widgets.dart';
import 'package:otzaria_l10n/otzaria_l10n.dart';

import '../controllers/error_reports_controller.dart';
import '../services/app_logger.dart';
import '../widgets/widgets_exports.dart';

Future<bool> _confirmUploads(
  BuildContext context, {
  required ErrorReportsController errorReports,
  required int reportCount,
}) async {
  if (reportCount > errorReports.batchSize) {
    final t = context.strings.errorReports;
    final approved = await showTwoActionsDialog(
      context: context,
      title: t.uploadLongDialogTitle,
      content: t.uploadLongDialogContent(
        reportCount,
        errorReports.batchSize,
        errorReports.estimateMinutes(reportCount),
      ),
      confirmText: t.uploadLongDialogConfirm,
    );
    if (!approved || !context.mounted) return false;
  }
  return true;
}

enum ReportsUploadSeverity { error, info, success }

class ReportsUploadOutcome {
  const ReportsUploadOutcome(this.message, this.severity);

  final String message;
  final ReportsUploadSeverity severity;

  void show() => switch (severity) {
        ReportsUploadSeverity.error => UiSnack.showError(message),
        ReportsUploadSeverity.info => UiSnack.show(message),
        ReportsUploadSeverity.success => UiSnack.showSuccess(message),
      };
}

/// משוב החיפוש אינו כאן: הוא עולה ברקע בלי ממשק (`SearchFeedbackAutoSync`).
Future<ReportsUploadOutcome?> uploadAllReports(
  BuildContext context, {
  ErrorReportsController? errorReports,
  void Function(bool active)? onActiveChanged,
  void Function(bool uploading)? onUploadingChanged,
}) async {
  if (errorReports == null || errorReports.isUploading) return null;
  if (errorReports.isCollecting) {
    UiSnack.show(AppL10n.strings.errorReports.uploadCollectingBusy);
    return null;
  }
  var announced = false;
  onActiveChanged?.call(true);
  try {
    final reportCount = errorReports.outboxCount;
    if (reportCount <= 0 || !context.mounted) return null;
    if (!await _confirmUploads(
      context,
      errorReports: errorReports,
      reportCount: reportCount,
    )) {
      return null;
    }

    onUploadingChanged?.call(true);
    announced = true;
    final s = AppL10n.strings.errorReports;
    final result = await errorReports.upload();
    final ReportsUploadOutcome outcome;
    if (result == null) {
      outcome = ReportsUploadOutcome(
        s.uploadCollectingBusy,
        ReportsUploadSeverity.info,
      );
    } else {
      final error = result.error;
      final lines = [
        if (error != null) s.uploadFailedSnack(error),
        if (error == null || result.total > 0)
          s.uploadSummary(result.sent, result.rejected, result.remaining),
      ];
      outcome = ReportsUploadOutcome(
        lines.join('\n'),
        error != null
            ? ReportsUploadSeverity.error
            : result.remaining > 0
                ? ReportsUploadSeverity.info
                : ReportsUploadSeverity.success,
      );
    }
    outcome.show();
    return outcome;
  } catch (error) {
    AppLogger.maybeInstance?.error('העלאת הדיווחים נכשלה', error);
    final outcome = ReportsUploadOutcome(
      AppL10n.strings.errorReports.uploadUnexpectedFailure,
      ReportsUploadSeverity.error,
    );
    outcome.show();
    return outcome;
  } finally {
    if (announced) onUploadingChanged?.call(false);
    onActiveChanged?.call(false);
  }
}
