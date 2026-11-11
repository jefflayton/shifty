import AppKit
import ApplicationServices
import CoreAudio

/// Watches for a Microsoft Teams call and tells `AutoSwitchModel` which
/// project it's for. A call is on while a Teams process takes sound from a
/// microphone, which Core Audio says without any permission. Which project
/// comes from a keyword in one of Teams' window titles, even with Teams
/// behind other windows; reading them needs the Accessibility permission
/// auto-switch already asks for. Without it, a call is seen but names no
/// project, so it offers nothing. A call lasts until Teams has let go of
/// the microphone for `grace`, in case muting or changing devices lets go
/// of it for a moment.
@MainActor
final class MeetingWatcher {
  private let store: ShiftStore
  private let model: AutoSwitchModel
  /// Teams' window titles at the last look, and when the call began.
  private var titles: [String] = []
  private var before: Set<String> = []
  private var inCall = false
  /// When Teams last had the microphone.
  private var heard: Date?
  static let grace: TimeInterval = 60
  /// The titles last logged, so a call's are logged once, to check what
  /// Teams puts in them.
  private var logged: [String] = []

  init(store: ShiftStore, model: AutoSwitchModel) {
    self.store = store
    self.model = model
  }

  /// Looks again, now.
  func check(now: Date = Date()) {
    let prefs = model.preferences
    guard prefs.autoSwitch, prefs.meetingSwitch,
      let teams = NSWorkspace.shared.runningApplications.first(where: {
        Meetings.teams.contains($0.bundleIdentifier ?? "")
      })
    else {
      inCall = false
      titles = []
      let ended = heard
      heard = nil
      return model.observeMeeting(nil, ended: ended, now: now)
    }
    let current = Self.windowTitles(teams)
    if Self.teamsHasMicrophone() { heard = now }
    let calling = heard.map { now.timeIntervalSince($0) < Self.grace } ?? false
    if calling && !inCall { before = Set(titles) }
    inCall = calling
    titles = current
    guard calling else {
      let ended = heard
      heard = nil
      return model.observeMeeting(nil, ended: ended, now: now)
    }
    if current != logged {
      log("meeting: Teams windows:", current)
      logged = current
    }
    let ordered = Meetings.ordered(current, before: before)
    var seen = AutoSwitchModel.MeetingSeen(
      title: ordered.lazy.compactMap(Meetings.name(fromTitle:)).first, target: nil)
    for title in ordered {
      let place: ShiftStore.Place
      do {
        place = try store.place(dir: nil, app: nil, title: title)
      } catch {
        log("meeting place:", error)
        break
      }
      guard place.via == .keyword, let target = place.target else { continue }
      seen = .init(title: Meetings.name(fromTitle: title) ?? title, target: target)
      break
    }
    model.observeMeeting(seen, now: now)
  }

  /// The titles of the app's windows, front to back, if Shifty may read
  /// them.
  static func windowTitles(_ app: NSRunningApplication) -> [String] {
    guard FocusWatcher.canReadWindows else { return [] }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement]
    else { return [] }
    return windows.compactMap { window in
      var title: CFTypeRef?
      guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
        let text = title as? String, !text.isEmpty
      else { return nil }
      return text
    }
  }

  // MARK: The microphone

  /// Whether a Teams process (the app or a helper) is taking sound from a
  /// microphone, from Core Audio's list of processes using audio.
  static func teamsHasMicrophone() -> Bool {
    for process in audioProcesses() where uint32(process, kAudioProcessPropertyIsRunningInput) == 1 {
      if Meetings.isTeams(string(process, kAudioProcessPropertyBundleID)) { return true }
      if let pid = pid(process), let path = FocusWatcher.executablePath(pid),
        Meetings.isTeams(path: path)
      {
        return true
      }
    }
    return false
  }

  private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }

  private static func audioProcesses() -> [AudioObjectID] {
    var address = property(kAudioHardwarePropertyProcessObjectList)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids
  }

  private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> UInt32?
  {
    var address = property(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  private static func pid(_ object: AudioObjectID) -> Int32? {
    var address = property(kAudioProcessPropertyPID)
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      value > 0
    else { return nil }
    return value
  }

  private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = property(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeRetainedValue() as String
  }
}
