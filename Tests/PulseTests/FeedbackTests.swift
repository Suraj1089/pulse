import XCTest
@testable import Pulse

/// Help › Report a Bug… / Request a Feature… open GitHub issue forms.
final class FeedbackTests: XCTestCase {
    func testBugReportOpensTheFormFilledIn() throws {
        let url = try XCTUnwrap(URLComponents(url: Feedback.url(for: .bug), resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/Suraj1089/pulse/issues/new")
        let fields = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["template"], "bug_report.yml")
        XCTAssertEqual(fields["version"], Updater.currentVersion)
        XCTAssertEqual(fields["macos"], ProcessInfo.processInfo.operatingSystemVersionString)
        XCTAssertFalse(fields["mac", default: ""].isEmpty, "chip and model")

        // GitHub fills in only fields whose id matches a query name.
        let form = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        let yaml = try String(contentsOf: form, encoding: .utf8)
        for name in fields.keys where name != "template" {
            XCTAssertTrue(yaml.contains("id: \(name)\n"), "bug_report.yml has no field '\(name)'")
        }
    }

    func testFeatureRequestOpensTheEmptyForm() throws {
        let url = try XCTUnwrap(URLComponents(url: Feedback.url(for: .feature), resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.path, "/Suraj1089/pulse/issues/new")
        XCTAssertEqual(url.queryItems, [URLQueryItem(name: "template", value: "feature_request.yml")])
    }
}
