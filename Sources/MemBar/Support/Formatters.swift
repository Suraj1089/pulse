import Foundation

enum Formatters {
    /// "idle 42m" / "idle 2h 10m" — used wherever a real `idleSince` date
    /// backs a diagnosis bullet or close-candidate reason.
    static func idleDuration(since date: Date) -> String {
        let minutes = Int(max(0, Date().timeIntervalSince(date)) / 60)
        if minutes < 1 { return "idle <1m" }
        if minutes < 60 { return "idle \(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "idle \(hours)h" : "idle \(hours)h \(remainder)m"
    }
}
