import Foundation

/// Go › Back and Forward (⌃- and ⌃⇧-), as in VS Code: the places the caret
/// jumped from. A jump is a switch to another file, or a caret move of more
/// than `jumpLines` lines that typing, folding and the arrow and page keys
/// didn't make: Find, Go to Line, a search result, a click, ⌘↓.
/// EditorViewController decides what is a jump; this keeps the places.
///
/// Memory: at most `limit` places each way, recorded only on a jump. A place
/// holds its document weakly, with the file's path to reopen it once closed,
/// and a character offset; nothing runs between jumps.
struct NavigationHistory {
    struct Place {
        weak var document: Document?
        let url: URL?
        let location: Int
    }

    static let limit = 50
    static let jumpLines = 10

    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []

    /// A jump away from `place`: Back returns there, and the places Forward
    /// had are dropped.
    mutating func record(_ place: Place) {
        forward.removeAll()
        if let last = back.last, last.document != nil, last.document === place.document, last.location == place.location { return }
        NavigationHistory.push(place, onto: &back)
    }

    /// The last place before `current` that `reachable` accepts (others are
    /// dropped); Forward then returns to `current`.
    mutating func goBack(from current: Place?, where reachable: (Place) -> Bool) -> Place? {
        while let place = back.popLast() {
            guard reachable(place) else { continue }
            if let current { NavigationHistory.push(current, onto: &forward) }
            return place
        }
        return nil
    }

    /// The place Back last left, the other way round.
    mutating func goForward(from current: Place?, where reachable: (Place) -> Bool) -> Place? {
        while let place = forward.popLast() {
            guard reachable(place) else { continue }
            if let current { NavigationHistory.push(current, onto: &back) }
            return place
        }
        return nil
    }

    private static func push(_ place: Place, onto places: inout [Place]) {
        places.append(place)
        if places.count > limit { places.removeFirst(places.count - limit) }
    }
}
