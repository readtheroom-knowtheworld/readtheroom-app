import 'dart:async';

import 'package:flutter/foundation.dart';

/// Runs [body] with console logging silenced in release builds.
///
/// The codebase logs liberally with `print` and `debugPrint`, and some of
/// those lines carry identifiers, tokens or user content. Both reach the
/// device log (logcat / Console.app) in a release build, where other tools
/// and bug-report captures can read them. In release this installs a zone
/// whose `print` is a no-op and replaces [debugPrint] with a no-op, so every
/// log call inside [body] — including async continuations — is dropped.
/// Debug and profile builds are untouched.
///
/// Call it at every isolate entry point: `main`, and each
/// `@pragma('vm:entry-point')` callback that runs in a background isolate.
R runWithReleaseLogging<R>(R Function() body) {
  if (!kReleaseMode) return body();
  debugPrint = (String? message, {int? wrapWidth}) {};
  return runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {},
    ),
  );
}
