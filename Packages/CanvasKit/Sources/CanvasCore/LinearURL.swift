import Foundation

/// Addresses of Linear's own web app, shown in a browser card: which issue
/// a page is about, and where "my issues" is.
public enum LinearURL {
    public static func isLinear(_ url: URL) -> Bool {
        url.host()?.lowercased() == "linear.app"
    }

    /// "ABC-961" for linear.app/<workspace>/issue/ABC-961/<slug>.
    public static func issueID(in url: URL) -> String? {
        guard isLinear(url) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[1] == "issue" else { return nil }
        let id = parts[2].uppercased()
        return id.range(of: #"^[A-Z0-9]+-\d+$"#, options: .regularExpression) != nil ? id : nil
    }

    public static func workspace(in url: URL) -> String? {
        guard isLinear(url) else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first
    }

    /// My issues in a workspace; Linear itself picks one without it.
    public static func myIssues(workspace: String?) -> URL {
        guard let workspace, !workspace.isEmpty else { return URL(string: "https://linear.app/")! }
        return URL(string: "https://linear.app/\(workspace)/my-issues/assigned")!
    }
}
