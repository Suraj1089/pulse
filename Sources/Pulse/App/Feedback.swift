import AppKit

/// Help › Report a Bug… and Request a Feature… open one of the repository's
/// issue forms (.github/ISSUE_TEMPLATE) in the browser. The bug form comes
/// filled in with the Pulse version, macOS and Mac; the person can change
/// it and decides whether to submit. Pulse itself sends nothing.
enum Feedback {
    enum Form: String {
        case bug = "bug_report.yml"
        case feature = "feature_request.yml"
    }

    /// Query names are the form's field ids; GitHub fills those fields in.
    static func url(for form: Form) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(Updater.repository)/issues/new"
        var items = [URLQueryItem(name: "template", value: form.rawValue)]
        if form == .bug {
            items.append(URLQueryItem(name: "version", value: Updater.currentVersion))
            items.append(URLQueryItem(name: "macos", value: ProcessInfo.processInfo.operatingSystemVersionString))
            items.append(URLQueryItem(name: "mac", value: mac))
        }
        components.queryItems = items
        return components.url!
    }

    static func open(_ form: Form) {
        NSWorkspace.shared.open(url(for: form))
    }

    /// "Apple M2, Mac14,2"; a part the system doesn't report is left out.
    static var mac: String {
        [systemValue("machdep.cpu.brand_string"), systemValue("hw.model")]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
