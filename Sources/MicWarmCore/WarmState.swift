import Foundation

/// What the menu-bar app shows. Each case has its own Fire circle glyph.
public enum WarmState: String, CaseIterable {
    /// Mic held open, signal flowing. Full flame.
    case warm
    /// Signal went flat and the session is restarting. Low flame with sparks; the stone ring spins.
    case recovering
    /// Mic released by the user. The fire is out, smoke rising.
    case paused
    /// Microphone permission missing. Hollow flame, struck through.
    case needsAccess = "needs-access"

    /// Whether the glyph animates in this state (when Reduce Motion is off).
    public var isAnimated: Bool { self == .recovering }

    /// Spoken by VoiceOver for the status item.
    public var accessibilityLabel: String {
        switch self {
        case .warm: return "Mic Warm: warm"
        case .recovering: return "Mic Warm: recovering"
        case .paused: return "Mic Warm: paused"
        case .needsAccess: return "Mic Warm: needs microphone access"
        }
    }
}
