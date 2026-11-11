import AppKit
import ApplicationServices
import Darwin

/// Watches where you're working and tells `AutoSwitchModel`: the app in
/// front, the folder it has open, and its window's title. A terminal's
/// folder comes from the shell hook's record (`shifty hook`); an editor's
/// from its window. The title is how a project's keywords find it, like a
/// Rex session or tab named for it. Reading windows needs the
/// Accessibility permission. Shifty's own windows don't count.
@MainActor
final class FocusWatcher {
  private let store: ShiftStore
  private let model: AutoSwitchModel
  private var timer: Timer?
  private var observer: NSObjectProtocol?
  /// Which app owns each shell; shells don't change hands.
  private var owners: [Int32: String?] = [:]
  /// Repo and folder tops seen, by name, to read an editor's title by.
  private var roots: [String: String] = [:]

  init(store: ShiftStore, model: AutoSwitchModel) {
    self.store = store
    self.model = model
  }

  func start() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    timer.tolerance = 0.5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    check()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observer = nil
  }

  /// Looks again, now.
  func check(now: Date = Date()) {
    let tracking = model.tracking
    guard model.preferences.autoSwitch else { return model.observe(nil, place: "", now: now) }
    tracking.reload(now: now)
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    else { return model.tick(now: now) }
    let bundle = app.bundleIdentifier
    let window = Self.focusedWindow(app)
    let title = window.flatMap { Self.attribute($0, kAXTitleAttribute) as? String }
    let dir = window.flatMap { editorDirectory($0, title: title) }
      ?? terminalDirectory(bundle, title: title)
    let place: ShiftStore.Place
    do {
      place = try store.place(dir: dir, app: bundle, title: title)
    } catch {
      log("auto-switch place:", error)
      return model.tick(now: now)
    }
    if let top = place.root ?? place.folder {
      roots[(top as NSString).lastPathComponent] = top
    }
    let name = Self.name(of: place, dir: dir, title: title, appName: app.localizedName)
    let seen = AutoSwitchModel.Seen(name: name, dir: dir, app: bundle, title: title, place: place)
    if seen != model.seen { model.seen = seen }
    model.observe(place.target, place: name, now: now)
  }

  /// What to call where you are: the part of the title a keyword matched
  /// (a Rex session's name, say), else the repo or folder, else the app.
  static func name(
    of place: ShiftStore.Place, dir: String?, title: String? = nil, appName: String?
  ) -> String {
    if place.via == .keyword, let keyword = place.keyword {
      let parts = title.map(Self.titleParts) ?? []
      return parts.first { part in part.localizedCaseInsensitiveContains(keyword) } ?? keyword
    }
    if place.via == .app || (place.root == nil && place.folder == nil && dir == nil) {
      return appName ?? "this app"
    }
    let path = place.folder ?? place.root ?? dir ?? ""
    return (path as NSString).lastPathComponent
  }

  // MARK: Terminals

  /// The folder of this app's shell that its window's title names, else
  /// of the one that last showed a prompt. A terminal with tabs, like Rex,
  /// shows no prompt when you switch tabs, but its title often names the
  /// folder or the session.
  private func terminalDirectory(_ bundle: String?, title: String?) -> String? {
    guard let bundle, let spots = try? store.spots() else { return nil }
    let live = spots.filter { kill($0.pid, 0) == 0 && Self.owns(bundle, owner(of: $0)) }
    if let title, let named = Self.folder(inTitle: title, known: Self.byName(live.map(\.dir))) {
      return named
    }
    return live.first?.dir
  }

  /// Folders by their names; where two share a name, the first.
  static func byName(_ dirs: [String]) -> [String: String] {
    var out: [String: String] = [:]
    for dir in dirs {
      let name = (dir as NSString).lastPathComponent
      if out[name] == nil { out[name] = dir }
    }
    return out
  }

  /// The app a shell belongs to: the nearest app above it, else what its
  /// environment says.
  private func owner(of spot: ShiftStore.Spot) -> String? {
    if let known = owners[spot.pid] { return known }
    let found = Self.appAbove(spot.pid) ?? (spot.bundle.isEmpty ? nil : spot.bundle)
      ?? Self.terminals[spot.term]
    owners[spot.pid] = found
    return found
  }

  /// Whether the app in front, `front`, is (or is part of) `owner`. A
  /// terminal's shells can belong to a helper app, like Rex Server
  /// (`com.superlogical.rex.server`) for Rex or Code Helper for VS Code.
  static func owns(_ front: String, _ owner: String?) -> Bool {
    guard let owner else { return false }
    return owner == front || owner.hasPrefix(front + ".")
  }

  /// `$TERM_PROGRAM`s, for shells no app is above (in tmux, say).
  static let terminals: [String: String] = [
    "Apple_Terminal": "com.apple.Terminal",
    "iTerm.app": "com.googlecode.iterm2",
    "ghostty": "com.mitchellh.ghostty",
    "WezTerm": "com.github.wez.wezterm",
    "vscode": "com.microsoft.VSCode",
    "zed": "dev.zed.Zed",
    "rex": "com.superlogical.rex",
  ]

  /// The bundle id of the nearest app above `pid`, walking its parents.
  static func appAbove(_ pid: Int32) -> String? {
    var pid = pid
    for _ in 0..<32 {
      guard pid > 1 else { return nil }
      if let path = executablePath(pid), let range = path.range(of: ".app/Contents/") {
        let app = String(path[..<range.lowerBound]) + ".app"
        if let id = Bundle(path: app)?.bundleIdentifier { return id }
      }
      guard let parent = parent(of: pid) else { return nil }
      pid = parent
    }
    return nil
  }

  private static func executablePath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(cString: buf)
  }

  private static func parent(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }

  // MARK: Editors

  /// Whether Shifty may read other apps' windows.
  static var canReadWindows: Bool { AXIsProcessTrusted() }

  /// Asks for the Accessibility permission, opening System Settings to it.
  static func askToReadWindows() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  /// The app's focused window, if Shifty may read it.
  static func focusedWindow(_ app: NSRunningApplication) -> AXUIElement? {
    guard canReadWindows else { return nil }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = attribute(element, kAXFocusedWindowAttribute),
      CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    return (window as! AXUIElement)
  }

  /// The folder a window has open: its document's, else a repo or folder
  /// named in its title, like VS Code's "file — folder".
  private func editorDirectory(_ window: AXUIElement, title: String?) -> String? {
    if let doc = Self.attribute(window, kAXDocumentAttribute) as? String,
      let url = URL(string: doc), url.isFileURL
    {
      var isDir: ObjCBool = false
      let path = url.path
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
        return isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
      }
    }
    guard let title else { return nil }
    let known = roots.merging(Self.vsCodeFolders()) { a, _ in a }
    return Self.folder(inTitle: title, known: known)
  }

  /// The folder whose name is a part of `title` ("a — b — c"), from
  /// `known` folders by name.
  static func folder(inTitle title: String, known: [String: String]) -> String? {
    for name in titleParts(title) {
      if let path = known[name] { return path }
    }
    return nil
  }

  /// A title's parts ("a — b - c"), without the marks editors add for
  /// unsaved changes.
  static func titleParts(_ title: String) -> [String] {
    title.components(separatedBy: " — ").flatMap { $0.components(separatedBy: " - ") }
      .map {
        $0.trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "●•*"))
          .trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty }
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  /// VS Code's (and Cursor's) open folders, by name, from the window state
  /// it saves.
  private static func vsCodeFolders() -> [String: String] {
    var out: [String: String] = [:]
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")
    for app in ["Code", "Cursor"] {
      let file = support.appendingPathComponent("\(app)/User/globalStorage/storage.json")
      guard let data = try? Data(contentsOf: file),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let state = json["windowsState"] as? [String: Any]
      else { continue }
      var windows = (state["openedWindows"] as? [[String: Any]]) ?? []
      if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
      for w in windows {
        guard let folder = w["folder"] as? String, let url = URL(string: folder), url.isFileURL
        else { continue }
        out[url.lastPathComponent] = url.path
      }
    }
    return out
  }
}
