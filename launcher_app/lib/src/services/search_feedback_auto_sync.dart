import 'dart:async';

import 'app_logger.dart';
import 'report_offer_trigger.dart';

/// משוב החיפוש נאסף ומועלה ברקע, בלי שום ממשק. [run] מחזיר מתי לנסות שוב
/// (לפי ההשהיה של התעבורה), ו-null כשאין מה לשלוח.
class SearchFeedbackAutoSync {
  SearchFeedbackAutoSync({
    required this.run,
    required bool Function() isBusy,
  }) {
    _trigger = ReportOfferTrigger(_once, isBusy: isBusy);
  }

  final Future<Duration?> Function() run;
  late final ReportOfferTrigger _trigger;
  Timer? _retry;
  bool _disposed = false;

  bool get hasScheduledRetry => _retry != null;

  void onRunningState({required bool running}) {
    if (!_disposed) _trigger.onRunningState(running: running);
  }

  Future<void> request() async {
    if (!_disposed) await _trigger.request();
  }

  void resume() {
    if (!_disposed) _trigger.resume();
  }

  Future<void> _once() async {
    if (_disposed) return;
    _retry?.cancel();
    _retry = null;
    Duration? delay;
    try {
      delay = await run();
    } catch (error) {
      AppLogger.maybeInstance?.error('סנכרון משוב החיפוש נכשל', error);
    }
    if (_disposed || delay == null) return;
    _retry = Timer(delay, () {
      _retry = null;
      unawaited(request());
    });
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
  }
}
