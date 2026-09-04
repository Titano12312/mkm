import 'package:flutter/widgets.dart';

/// Shared motion tokens.
///
/// Per ui-ux-pro-max guidance: durations follow distance/complexity, never
/// one duration copied to every transition. Curves: standard ease for UI
/// chrome, overshoot/elastic reserved for playful entrances (Discord-like).
abstract final class Motion {
  /// Taps, fades, switchers.
  static const fast = Duration(milliseconds: 150);

  /// Rows, bars, list entrances.
  static const base = Duration(milliseconds: 250);

  /// Staggered screen entrances.
  static const enter = Duration(milliseconds: 350);

  /// Elastic hero moments (logo, call join).
  static const playful = Duration(milliseconds: 600);

  /// Default ease for chrome movement.
  static const standard = Curves.easeOutCubic;

  /// Playful overshoot for entrances.
  static const entrance = Curves.easeOutBack;

  /// Springy release moments.
  static const spring = Curves.elasticOut;

  /// Honor OS reduced-motion: callers skip loops/overshoot when true.
  static bool reduce(BuildContext context) =>
      MediaQuery.of(context).disableAnimations;
}
