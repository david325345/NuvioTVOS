import Foundation

/// How a digit drawing starts, so it never mixes with ordinary swipes.
public enum DrawingMode: String, Codable, CaseIterable, Sendable {
    /// No drawing; a long press on the centre is an ordinary gesture.
    case off
    /// Hold the centre click, draw while holding, release to finish.
    case holdSelect
    /// Long press on the centre, let go, then draw; a pause ends the drawing.
    case longPressThenDraw

    public var title: String {
        switch self {
        case .off: return "Vypnuto"
        case .holdSelect: return "Podržet střed a kreslit"
        case .longPressThenDraw: return "Dlouhý stisk, pak kreslit"
        }
    }
}

/// Every threshold the recognizer uses, adjustable on the Tuning screen.
/// Pad positions are in pad units (the surface is 2 wide, −1…1); swipe and
/// tap movement in points of the system's own (UIKit) touch movement.
public struct Tuning: Codable, Equatable, Sendable {
    /// Longest gap from letting go of the first click (or tap) to the second
    /// one that still makes a double.
    public var doubleWindow: Double = 0.35
    /// A press held this long is a long press.
    public var longPress: Double = 0.50
    /// Shortest swipe, in UIKit points.
    public var swipeMinPoints: Double = 250
    /// A swipe at least this long (UIKit points) is a long swipe.
    public var swipeLongPoints: Double = 900
    /// Slower movements are not swipes.
    public var swipeMaxDuration: Double = 1.0
    /// A light tap is shorter than this…
    public var tapMaxDuration: Double = 0.40
    /// …and moves less than this (UIKit points).
    public var tapMaxMovePoints: Double = 60
    /// Taps farther from the middle than this are left or right.
    public var sideThreshold: Double = 0.30
    /// Turn needed for a circle, in degrees.
    public var circleDegrees: Double = 300
    /// The finger must stay at least this far from the middle while circling.
    public var circleMinRadius: Double = 0.45
    /// A touch this close (before or after) to a click belongs to the click:
    /// clicking on the edge is no swipe and no tap.
    public var clickGuard: Double = 0.15
    /// Pad positions this long before the lift are dropped: they slide
    /// towards the middle as the finger comes off.
    public var liftTrim: Double = 0.07
    public var drawingMode: DrawingMode = .longPressThenDraw
    /// After the long press, how long the first stroke may wait.
    public var drawArmWindow: Double = 2.0
    /// A pause this long after a stroke ends the drawing (long press mode).
    public var strokeGap: Double = 0.8
    /// Lowest score (0…1) a digit needs to count.
    public var digitMinScore: Double = 0.60

    public init() {}
}
