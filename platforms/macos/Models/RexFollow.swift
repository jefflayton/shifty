import Foundation

/// Following Rex's tabs and sessions, which its window's title can't always
/// tell: a session on a remote host runs its shells there, so the prompt
/// hook never reaches this Mac, and switching side tabs shows no prompt.
/// Shifty runs the `rex do` script from `shifty hook rex` on this Mac, once
/// for this Mac's Rex server and once for each remote host. The script
/// hears the tab and session you switch to and records them in the store
/// (`ShiftStore.rexFocus`), and auto switch reads keywords there.
enum RexFollow {
  static let bundleID = "com.superlogical.rex"

  /// Whether `app` is Rex, or part of it (Rex Server).
  static func isRex(_ app: String?) -> Bool {
    guard let app else { return false }
    return app == bundleID || app.hasPrefix(bundleID + ".")
  }

  /// Host labels (from `rex hosts`) in `text`, split at commas and spaces,
  /// each once, in order.
  static func hosts(_ text: String) -> [String] {
    var out: [String] = []
    for part in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
      let host = String(part)
      if !out.contains(host) { out.append(host) }
    }
    return out
  }

  /// The servers to listen to: this Mac's (nil), then each host's.
  static func servers(hosts: [String]) -> [String?] {
    [nil] + hosts.map { Optional($0) }
  }

  /// The `rex` arguments that run `script` on this Mac for every session on
  /// `server` (nil for this Mac's), calling `cli` with what it hears. It
  /// never starts a server that isn't running.
  static func arguments(script: String, server: String?, cli: String) -> [String] {
    var args = ["--autostart=false"]
    if let server { args += ["-S", server] }
    args += ["do", script, "--all", "shifty=\(cli)"]
    if let server { args.append("server=\(server)") }
    return args
  }

  /// The title to match keywords in: with Rex in front, the tab and session
  /// the script last heard, else the window's own.
  static func title(app: String?, window: String?, focus: ShiftStore.RexFocus?) -> String? {
    guard isRex(app), let focus, !focus.title.isEmpty else { return window }
    return focus.title
  }
}
