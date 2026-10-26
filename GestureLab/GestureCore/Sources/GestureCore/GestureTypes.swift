import Foundation

/// A point on the remote's touch surface: x and y from −1 to 1, y pointing up
/// (GameController's absolute d-pad values).
public struct PadPoint: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to other: PadPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A button press the remote reports: the clickpad centre, the four
/// directions (ring clicks on the silver remote, edge taps on the black one)
/// and Play/Pause. Menu/Back is not a gesture: it leaves the test screen.
public enum RemoteButton: String, Codable, CaseIterable, Sendable {
    case select, up, down, left, right, playPause

    public var title: String {
        switch self {
        case .select: return "na střed"
        case .up: return "nahoru"
        case .down: return "dolů"
        case .left: return "vlevo"
        case .right: return "vpravo"
        case .playPause: return "Play/Pause"
        }
    }
}

public enum ClickKind: String, Codable, Sendable {
    case single, double, long
}

public enum SwipeDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var title: String {
        switch self {
        case .left: return "doleva"
        case .right: return "doprava"
        case .up: return "nahoru"
        case .down: return "dolů"
        }
    }
}

/// Where a touch rested: one of eight directions from the middle, or the middle.
public enum PadSide: String, Codable, CaseIterable, Sendable {
    case left, center, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    public var title: String {
        switch self {
        case .left: return "vlevo"
        case .center: return "uprostřed"
        case .right: return "vpravo"
        case .top: return "nahoře"
        case .bottom: return "dole"
        case .topLeft: return "vlevo nahoře"
        case .topRight: return "vpravo nahoře"
        case .bottomLeft: return "vlevo dole"
        case .bottomRight: return "vpravo dole"
        }
    }
}

/// Everything Gesture Lab tells apart.
public enum RemoteGesture: Hashable, Codable, Sendable {
    case click(RemoteButton, ClickKind)
    case swipe(SwipeDirection, long: Bool)
    case tap(PadSide, double: Bool)
    /// A finger resting still (no click) for a while.
    case hold(PadSide)
    case circle(clockwise: Bool)
    case digit(Int)

    public var title: String {
        switch self {
        case let .click(button, kind):
            switch kind {
            case .single: return "Klik \(button.title)"
            case .double: return "Dvojklik \(button.title)"
            case .long: return "Dlouhý stisk \(button.title)"
            }
        case let .swipe(direction, long):
            return (long ? "Dlouhý tah " : "Tah ") + direction.title
        case let .tap(side, double):
            return (double ? "Dvojí dotyk " : "Dotyk ") + side.title
        case let .hold(side):
            return "Přidržení " + side.title
        case let .circle(clockwise):
            return clockwise ? "Kroužek po směru hodin" : "Kroužek proti směru hodin"
        case let .digit(value):
            return "Číslice \(value)"
        }
    }

    /// The double version of a single click or tap, which the single one has
    /// to wait for when it is bound.
    public var doubled: RemoteGesture? {
        switch self {
        case let .click(button, .single): return .click(button, .double)
        case let .tap(side, false): return .tap(side, double: true)
        default: return nil
        }
    }
}
