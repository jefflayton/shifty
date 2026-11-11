import AppKit
import Foundation

/// Runs the `rex do` script from `shifty hook rex` on this Mac, one for
/// this Mac's Rex server and one for each remote host in Settings, while
/// auto switch follows Rex (see `RexFollow`). A script that stops, say
/// because a host is out of reach, starts again a little later.
@MainActor
final class RexWatcher {
  /// Why it isn't following Rex, for Settings; nil when it is, or is off.
  static var problem: String?

  /// How long a script that stopped waits to start again.
  static let retryDelay: TimeInterval = 30

  private var running: [String: Process] = [:]
  private var wanted: [String?] = []
  private var pending: DispatchWorkItem?
  private var retries: [String: DispatchWorkItem] = [:]
  private var rex: String?

  /// Follows `hosts` and this Mac's server, or nothing when `follow` is
  /// off. Waits a moment first, so typing a host's name doesn't start a
  /// script for every letter.
  func update(follow: Bool, hosts: [String]) {
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.apply(follow ? RexFollow.servers(hosts: hosts) : []) }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
  }

  /// Stops every script, now.
  func stop() {
    pending?.cancel()
    apply([])
  }

  private static func key(_ server: String?) -> String { server ?? "" }

  private func apply(_ servers: [String?]) {
    wanted = servers
    let keys = Set(servers.map(Self.key))
    for (key, process) in running where !keys.contains(key) {
      running[key] = nil
      process.terminate()
    }
    for (key, retry) in retries where !keys.contains(key) {
      retry.cancel()
      retries[key] = nil
    }
    guard !servers.isEmpty else {
      Self.problem = nil
      return
    }
    if rex == nil { rex = Self.findRex() }
    guard let rex else {
      Self.problem = "Can't find the rex command. Open Rex, then try again."
      return
    }
    let cli = CommandLineTool.bundled
    guard FileManager.default.isExecutableFile(atPath: cli), let script = Self.writeScript(cli: cli)
    else {
      Self.problem = "Can't write the Rex script."
      return
    }
    Self.problem = nil
    for server in servers where running[Self.key(server)] == nil {
      start(rex: rex, script: script, server: server, cli: cli)
    }
  }

  private func start(rex: String, script: String, server: String?, cli: String) {
    let key = Self.key(server)
    retries[key] = nil
    let process = Process()
    process.executableURL = URL(fileURLWithPath: rex)
    process.arguments = RexFollow.arguments(script: script, server: server, cli: cli)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    errors.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      log("rex \(key.isEmpty ? "(this Mac)" : key):", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    process.terminationHandler = { [weak self] done in
      errors.fileHandleForReading.readabilityHandler = nil
      let status = done.terminationStatus
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.stopped(key, process: done, status: status) }
      }
    }
    do {
      try process.run()
      running[key] = process
    } catch {
      log("rex: can't run \(rex):", error)
      self.rex = nil
      retry(key)
    }
  }

  private func stopped(_ key: String, process: Process, status: Int32) {
    guard running[key] === process else { return }
    running[key] = nil
    log("rex \(key.isEmpty ? "(this Mac)" : key): script stopped (\(status))")
    retry(key)
  }

  /// Starts `key`'s script again after `retryDelay`, if it's still wanted.
  private func retry(_ key: String) {
    retries[key]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.wanted.contains(where: { Self.key($0) == key }) else { return }
        self.retries[key] = nil
        self.apply(self.wanted)
      }
    }
    retries[key] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
  }

  /// The script, written to Application Support for `rex do` to read.
  private static func writeScript(cli: String) -> String? {
    let text = ShiftStore.rexScript(cli: cli)
    guard !text.isEmpty,
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    let dir = support.appendingPathComponent("Shifty", isDirectory: true)
    let file = dir.appendingPathComponent("rex-follow.lua")
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try text.write(to: file, atomically: true, encoding: .utf8)
      return file.path
    } catch {
      log("rex: can't write the script:", error)
      return nil
    }
  }

  /// The `rex` command: the one inside Rex.app, else one in a usual place.
  static func findRex() -> String? {
    let files = FileManager.default
    var apps = NSRunningApplication.runningApplications(withBundleIdentifier: RexFollow.bundleID)
      .compactMap(\.bundleURL)
    if let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RexFollow.bundleID)
    {
      apps.append(installed)
    }
    for app in apps {
      if let found = executable(named: "rex", in: app.appendingPathComponent("Contents")) {
        return found
      }
    }
    let home = files.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin/rex", "/opt/homebrew/bin/rex", "/usr/local/bin/rex"]
      .first { files.isExecutableFile(atPath: $0) }
  }

  /// The first executable file called `name` in `dir`, looking a few
  /// levels down, into helper apps too.
  private static func executable(named name: String, in dir: URL) -> String? {
    let files = FileManager.default
    guard
      let walk = files.enumerator(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return nil }
    for case let url as URL in walk {
      if walk.level > 6 { walk.skipDescendants() }
      guard url.lastPathComponent == name,
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
        files.isExecutableFile(atPath: url.path)
      else { continue }
      return url.path
    }
    return nil
  }
}
