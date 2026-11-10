import SwiftUI

/// Settings for following your work with the timer: on or off, how long
/// before it offers, and the hooks that tell it which folder you're in.
struct AutoSwitchSettings: View {
  @Bindable var preferences: Preferences
  @AppStorage("autoSwitch.shell") private var shell: HookShell = .zsh
  @State private var tool = CommandLineTool.status

  /// What the hook line runs: the command once it's in PATH.
  private var command: String {
    tool == .installed ? CommandLineTool.name : CommandLineTool.bundled
  }

  var body: some View {
    Section {
      Toggle("Switch projects as you work", isOn: $preferences.autoSwitch)
      Picker("Offer to switch after", selection: $preferences.autoSwitchDelay) {
        ForEach(Preferences.autoSwitchDelays, id: \.self) { Text(Self.seconds($0)).tag($0) }
      }
      .disabled(!preferences.autoSwitch)
      Picker("Count down for", selection: $preferences.autoSwitchCountdown) {
        ForEach(Preferences.autoSwitchCountdowns, id: \.self) { Text(Self.seconds($0)).tag($0) }
      }
      .disabled(!preferences.autoSwitch)
    } footer: {
      Text(
        "While a timer runs, staying in a repo, folder, or app linked to another project brings up an offer to switch at the top of the screen. When it counts down, the timer switches, from when you got there. Clocked in with no timer, it offers to start one. Link repos, folders, and apps to projects in the Projects window. Places nothing links to change nothing."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }

    Section {
      Picker("Shell", selection: $shell) {
        ForEach(HookShell.allCases) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      CommandLineToolRow(status: $tool, compact: true)
      HStack(alignment: .firstTextBaseline) {
        Text(shell.line(cli: command))
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(shell.line(cli: command), forType: .string)
        }
      }
    } header: {
      Text("Terminals")
    } footer: {
      Text(
        "Add this line to \(shell.config) so the menu bar knows which folder your terminal is in. It works in any terminal, including VS Code's and Zed's."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }

    Section {
      TimelineView(.periodic(from: .now, by: 2)) { _ in
        LabeledContent("Read editor windows") {
          if FocusWatcher.canReadWindows {
            Label("Allowed", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } else {
            Button("Allow…") { FocusWatcher.askToReadWindows() }
          }
        }
      }
    } header: {
      Text("Editors")
    } footer: {
      Text(
        "For VS Code, Zed, and other editors, Shifty reads which folder the front window has open. That needs Accessibility access in System Settings."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  static func seconds(_ s: TimeInterval) -> String {
    s < 60 ? "\(Int(s)) seconds" : s == 60 ? "1 minute" : "\(Int(s / 60)) minutes"
  }
}

/// A shell to set up the prompt hook in.
enum HookShell: String, CaseIterable, Identifiable {
  case zsh, fish, bash, nvim

  var id: Self { self }

  var label: String {
    switch self {
    case .zsh: "zsh"
    case .fish: "fish"
    case .bash: "bash"
    case .nvim: "Neovim"
    }
  }

  var config: String {
    switch self {
    case .zsh: "~/.zshrc"
    case .fish: "~/.config/fish/config.fish"
    case .bash: "~/.bashrc"
    case .nvim: "your init.lua"
    }
  }

  /// The config line that loads `shifty hook` from `cli`: a command name,
  /// or a path, which gets quoted.
  func line(cli: String) -> String {
    let quoted =
      cli.contains("/") ? "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'" : cli
    switch self {
    case .zsh: return "eval \"$(\(quoted) hook zsh)\""
    case .bash: return "eval \"$(\(quoted) hook bash)\""
    case .fish: return "\(quoted) hook fish | source"
    case .nvim: return "load(vim.fn.system({ \(quoted), \"hook\", \"nvim\" }))()"
    }
  }
}

/// Whether the `shifty` command is in your PATH, with a button to put it
/// there or take it out.
struct CommandLineToolRow: View {
  @Binding var status: CommandLineTool.Status
  /// In the Terminals section: only says something when there's something
  /// to do.
  var compact = false

  var body: some View {
    Group {
      switch status {
      case .missing:
        Label(
          "This build of Shifty is missing its command line tool, so hooks can't run. Rebuild it with zig build macos.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      case .installed:
        if !compact {
          LabeledContent("\(CommandLineTool.name) command") {
            HStack {
              Text(CommandLineTool.link).foregroundStyle(.secondary)
              Button("Uninstall") { run { CommandLineTool.uninstall() } }
            }
          }
        }
      case .notInstalled, .taken:
        LabeledContent {
          Button(status == .notInstalled ? "Install…" : "Replace…") {
            run { CommandLineTool.install() }
          }
        } label: {
          Text("\(CommandLineTool.name) command")
          if case .taken(let other) = status {
            Text("\(CommandLineTool.link) is another copy, at \(other).")
          } else {
            Text("Run \(CommandLineTool.name) from any terminal\(compact ? ", and use a shorter line below" : "").")
          }
        }
      }
    }
    .onAppear { status = CommandLineTool.status }
  }

  private func run(_ action: () -> Bool) {
    _ = action()
    status = CommandLineTool.status
  }
}
