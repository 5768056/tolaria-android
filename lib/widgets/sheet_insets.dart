import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Breathing room under the last row of a bottom sheet.
///
/// `SafeArea` alone is not enough on Android: when the app runs edge to edge
/// the sheet is laid out down to the very bottom of the screen and
/// `MediaQuery.padding.bottom` is often 0, so the last row — the destructive
/// one — ends up exactly on the gesture / navigation band. A mis-tap there
/// deletes a note. [MediaQueryData.systemGestureInsets] reports that band even
/// when `padding` is zero, so take whichever is larger, then keep a visible
/// gap of our own for devices that report neither (3-button nav hidden in
/// full-screen mode reports 0 for both).
EdgeInsets sheetBottomInset(BuildContext context) {
  final media = MediaQuery.of(context);
  final system = math.max(
    media.padding.bottom,
    math.max(media.viewPadding.bottom, media.systemGestureInsets.bottom),
  );
  return EdgeInsets.only(bottom: math.max(system + 16, 32));
}
