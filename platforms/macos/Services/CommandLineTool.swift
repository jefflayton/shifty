import AppKit

/// The `shifty` command, bundled in the app at Contents/Helpers, and the
/// link in /usr/local/bin that puts it in your PATH, as Xcode and VS Code
/// install theirs. The link points into the app, so an update (which
/// replaces the app in place) keeps it current. Dev builds install as
/// `shifty-dev`, beside a release's `shifty`.
@MainActor
enum CommandLineTool {
  enum Status: Equatable {
    /// This build has no bundled tool.
    case missing
    case notInstalled
    case installed
    /// Something else has the name, like a `zig build cli` link or an
    /// older app's.
    case taken(by: String)
  }

  static var isDev: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false }
  static var name: String { isDev ? "shifty-dev" : "shifty" }
  static var bundled: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shifty").path
  }
  static let directory = "/usr/local/bin"
  static var link: String { "\(directory)/\(name)" }

  static var status: Status {
    let files = FileManager.default
    guard files.isExecutableFile(atPath: bundled) else { return .missing }
    guard let dest = try? files.destinationOfSymbolicLink(atPath: link) else {
      return files.fileExists(atPath: link) ? .taken(by: link) : .notInstalled
    }
    let resolved = URL(fileURLWithPath: dest, relativeTo: URL(fileURLWithPath: directory))
      .standardizedFileURL.path
    return resolved == URL(fileURLWithPath: bundled).standardizedFileURL.path
      ? .installed : .taken(by: resolved)
  }

  /// Links the bundled tool into /usr/local/bin, asking for an
  /// administrator's password if the folder needs one. Replaces whatever
  /// had the name. Returns whether it worked.
  @discardableResult
  static func install() -> Bool {
    let files = FileManager.default
    do {
      try files.createDirectory(atPath: directory, withIntermediateDirectories: true)
      if (try? files.destinationOfSymbolicLink(atPath: link)) != nil || files.fileExists(atPath: link) {
        try files.removeItem(atPath: link)
      }
      try files.createSymbolicLink(atPath: link, withDestinationPath: bundled)
      return true
    } catch {
      // /usr/local/bin is usually root's.
      return asAdmin(
        "mkdir -p \(quote(directory)) && ln -sfn \(quote(bundled)) \(quote(link))",
        prompt: "Shifty wants to install the \(name) command in \(directory).")
    }
  }

  @discardableResult
  static func uninstall() -> Bool {
    guard status == .installed else { return true }
    do {
      try FileManager.default.removeItem(atPath: link)
      return true
    } catch {
      return asAdmin(
        "rm -f \(quote(link))", prompt: "Shifty wants to remove the \(name) command.")
    }
  }

  /// Runs a shell command as root after macOS asks for a password.
  private static func asAdmin(_ command: String, prompt: String) -> Bool {
    let source =
      "do shell script \"\(escape(command))\" with prompt \"\(escape(prompt))\" with administrator privileges"
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { log("command line tool:", error) }
    return error == nil
  }

  /// For a shell: in single quotes.
  private static func quote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// For an AppleScript string.
  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }
}
