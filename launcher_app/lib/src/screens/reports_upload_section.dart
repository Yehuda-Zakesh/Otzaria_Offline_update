import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

import '../controllers/error_reports_controller.dart';
import '../theme/theme_exports.dart';
import '../widgets/widgets_exports.dart';

/// דיווחי הטעויות בלבד; משוב החיפוש אינו נספר ואינו מוצג כאן.
class ReportsUploadSection extends StatelessWidget {
  const ReportsUploadSection({
    super.key,
    required this.errorReports,
    required this.connection,
    required this.isUploadingAll,
    required this.busy,
    required this.onUpload,
  });

  final ErrorReportsController errorReports;
  final bool? connection;
  final bool isUploadingAll;
  final bool busy;
  final Future<void> Function()? onUpload;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: errorReports,
      builder: (context, _) {
        final t = context.strings.errorReports;
        final reports = errorReports;
        if (isUploadingAll || reports.isUploading) {
          final p = reports.progress;
          final wait = p?.waitRemaining;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: AppTokens.spaceMD),
              InfoProgressRow(
                stage: wait != null
                    ? t.uploadWaitingStage((wait.inMilliseconds / 1000).ceil())
                    : t.uploadingStage(p?.done ?? 0, p?.total ?? 0),
                progress: p == null || p.total == 0 ? null : p.done / p.total,
              ),
              const SizedBox(height: AppTokens.spaceSM),
              ActionButton.warning(
                text: t.uploadStopButton,
                icon: FluentIcons.stop_24_regular,
                onPressed: () {
                  if (reports.isUploading) reports.stop();
                },
              ),
            ],
          );
        }
        final total = reports.outboxCount;
        if (total <= 0) return const SizedBox.shrink();
        if (connection != true) {
          return Padding(
            padding: const EdgeInsets.only(top: AppTokens.spaceMD),
            child: Text(
              connection == null
                  ? t.uploadPendingUnchecked(total)
                  : t.uploadPendingOffline(total),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(top: AppTokens.spaceMD),
          child: ActionButton.neutral(
            text: t.uploadButton(total),
            icon: FluentIcons.arrow_upload_24_regular,
            onPressed: busy || onUpload == null ? null : () => onUpload!(),
          ),
        );
      },
    );
  }
}
