import SwiftUI

/// A titled group of rows in the style of System Settings: a quiet heading
/// with an optional trailing control, and rows on a shared rounded fill
/// separated by hairlines.
struct FormSection<Accessory: View, Content: View>: View {
  let title: String
  @ViewBuilder var accessory: Accessory
  @ViewBuilder var content: Content

  init(
    _ title: String,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() },
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        accessory
      }
      .padding(.horizontal, 6)

      VStack(spacing: 0) {
        Group(subviews: content) { rows in
          ForEach(rows) { row in
            if row.id != rows.first?.id {
              Divider().padding(.leading, 10)
            }
            row
              .padding(.horizontal, 10)
              .frame(minHeight: 34)
          }
        }
      }
      .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(.quaternary.opacity(0.6), lineWidth: 0.5)
      )
    }
  }
}

/// A settings row: label at the leading edge, controls at the trailing edge.
struct FormRow<Control: View>: View {
  let label: String
  @ViewBuilder var control: Control

  init(_ label: String, @ViewBuilder control: () -> Control) {
    self.label = label
    self.control = control()
  }

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      control
    }
  }
}

/// The "+" in a section heading.
struct AddButton: View {
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.subheadline.weight(.semibold))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(help)
  }
}

/// The "−" that removes a row.
struct RemoveButton: View {
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "minus.circle.fill")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.borderless)
    .help(help)
  }
}

/// A full-width, menu-style row that highlights on hover, like the items at
/// the bottom of a menu bar extra.
struct MenuRowButton: View {
  let title: String
  var shortcut: String? = nil
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.isEnabled) private var isEnabled

  init(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.shortcut = shortcut
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        if let shortcut {
          Text(shortcut).foregroundStyle(hovered && isEnabled ? .white : .secondary)
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        hovered && isEnabled ? Color.accentColor : .clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .foregroundStyle(hovered && isEnabled ? .white : isEnabled ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

/// A menu-style row that opens a submenu, for settings that are set once and
/// don't need room in the popover.
struct MenuRowMenu<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  @State private var hovered = false

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    Menu {
      content
    } label: {
      HStack {
        Text(title)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(hovered ? .white : .secondary)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        hovered ? Color.accentColor : .clear,
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .foregroundStyle(hovered ? .white : .primary)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .onHover { hovered = $0 }
  }
}
