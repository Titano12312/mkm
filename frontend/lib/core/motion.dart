import 'package:flutter/widgets.dart';

/// Shared motion tokens.
///
/// Per animate thesis (Operate mode, Windows + Android budget):
/// durations follow distance/complexity, never one duration copied to
/// every transition. Exits run faster than entrances. Transform + opacity
/// only in lists; no blur/filter/shader loops. Curves: standard ease for
/// UI chrome and all feedback pops; overshoot/elastic reserved for the
/// single playful presence cue (call join), never for routine taps.
abstract final class Motion {
  /// Immediate feedback + exits (must stay < entrance).
  static const fastExit = Duration(milliseconds: 120);

  /// Taps, fades, switchers.
  static const fast = Duration(milliseconds: 150);

  /// Rows, bars, list entrances.
  static const base = Duration(milliseconds: 250);

  /// Staggered screen entrances (cap total delay, see login).
  static const enter = Duration(milliseconds: 350);

  /// Elastic hero moments (call join only — not routine buttons).
  static const playful = Duration(milliseconds: 600);

  /// Default ease for chrome movement + feedback.
  /// Matches animate.md confident arrival: cubic-bezier(0.16, 1, 0.3, 1).
  static const standard = Curves.easeOutCubic;

  /// Playful overshoot for the one hero entrance per first-run surface.
  static const entrance = Curves.easeOutBack;

  /// Springy release moments — call presence only, never send/mute pops.
  static const spring = Curves.elasticOut;

  /// Feedback pops use the chrome ease, never spring (latency feel).
  static const feedback = Curves.easeOutCubic;

  /// Honor OS reduced-motion: callers skip loops/overshoot when true.
  /// Covers Android Remove-animations + Windows reduce-motion via
  /// MediaQuery.disableAnimations.
  static bool reduce(BuildContext context) =>
      MediaQuery.of(context).disableAnimations;
}
