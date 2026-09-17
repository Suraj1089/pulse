import SwiftUI

// MARK: - Quit-row dismissal transition

/// Slides the row ~60 pt to the trailing edge while fading to zero.
/// The parent VStack's spring animation simultaneously collapses the freed
/// height, so the rows below float up in one continuous motion.
///
/// Design rationale (Apple HIG):
///   • Spatial: the row moves *away* from the user (trailing = away from content)
///   • Purposeful: the direction reinforces "sending away" a process
///   • Natural: spring physics, no linear easing — matches every native macOS list
struct QuitSweepModifier: ViewModifier {
    /// 0 = identity (fully visible), 1 = fully swept (invisible)
    var progress: Double

    func body(content: Content) -> some View {
        content
            .offset(x: progress * 90)
            .opacity(1 - progress)
            // Subtle vertical shrink gives a sense of the row "leaving the plane"
            .scaleEffect(x: 1.0, y: max(0, 1 - progress * 0.15), anchor: .center)
    }
}

extension AnyTransition {
    /// Asymmetric: no insertion animation (items appear instantly when list
    /// refreshes), but removal sweeps the row out.
    static var quitSweep: AnyTransition {
        .asymmetric(
            insertion: .identity,
            removal: .modifier(
                active:   QuitSweepModifier(progress: 1),
                identity: QuitSweepModifier(progress: 0)
            )
        )
    }
}

// MARK: - Spring constant shared across all quit-row animations

extension Animation {
    /// Smooth, deliberate spring with slightly longer duration so the user
    /// visually registers the swipe and feels the dismissal.
    static var quitSpring: Animation {
        .spring(response: 0.52, dampingFraction: 0.82)
    }
}
