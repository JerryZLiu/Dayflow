import SwiftUI
import UniformTypeIdentifiers

struct EditableCategoryCard: View {
  enum Field: Hashable {
    case name
    case description
  }

  let category: TimelineCategory
  let isEditing: Bool
  @Binding var draftName: String
  @Binding var draftDetails: String
  var onStartEdit: () -> Void
  var onSave: () -> Void
  var onDelete: () -> Void

  @Environment(\.dayflowTheme) private var theme
  @FocusState private var focusedField: Field?

  var body: some View {
    Group {
      if isEditing {
        editingView
          .onAppear {
            focusedField = .name
          }
          .onDisappear {
            focusedField = nil
          }
      } else {
        displayView
      }
    }
  }

  private var editingView: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        TextField("", text: $draftName)
          .font(Font.custom("Figtree", size: 14).weight(.bold))
          .textFieldStyle(.plain)
          .foregroundColor(theme.isDark ? .white : .black)
          .submitLabel(.next)
          .focused($focusedField, equals: .name)
          .onSubmit {
            focusedField = .description
          }

        Spacer(minLength: 12)

        Button {
          focusedField = nil
          onSave()
        } label: {
          Image("CategoriesCheckmark")
            .resizable()
            .frame(width: 20, height: 20)
            .accessibilityLabel("Save category edits")
        }
        .buttonStyle(.plain)

      }

      ZStack(alignment: .topLeading) {
        if draftDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Professional, school, or career-focused tasks (coding, design, meetings).")
            .font(Font.custom("Figtree", size: 12).weight(.medium))
            .foregroundColor(theme.isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.35))
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }

        TextEditor(text: $draftDetails)
          .font(Font.custom("Figtree", size: 12).weight(.medium))
          .foregroundColor(theme.isDark ? .white : .black)
          .padding(.horizontal, 10)
          .padding(.top, 10)
          .padding(.bottom, 12)
          .frame(minHeight: 55)
          .background(theme.isDark ? Color.white.opacity(0.08) : Color.white)
          .focused($focusedField, equals: .description)
          .scrollContentBackground(.hidden)
      }
      .background(
        RoundedRectangle(cornerRadius: 6)
          .stroke(
            theme.isDark ? Color(hex: "4E4E4E") : Color(red: 0.89, green: 0.86, blue: 0.85),
            lineWidth: 0.5)
      )
    }
    .padding(16)
    .frame(alignment: .leading)
    .background(theme.isDark ? Color(hex: "3A3A4C") : Color.white)
    .cornerRadius(8)
    .shadow(
      color: theme.isDark ? Color.black.opacity(0.3) : Color(red: 0.86, green: 0.8, blue: 0.76),
      radius: 3, x: 0, y: 0
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .inset(by: 0.25)
        .stroke(
          theme.isDark ? Color(hex: "4E4E4E") : Color(red: 0.89, green: 0.86, blue: 0.85),
          lineWidth: 0.5)
    )
  }

  private var displayView: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(category.name)
          .font(Font.custom("Figtree", size: 12).weight(.bold))
          .foregroundColor(theme.isDark ? .white : .black)
          .frame(maxWidth: .infinity, alignment: .center)

        Text(
          category.details.isEmpty
            ? "Add a description to help Dayflow understand your workflow." : category.details
        )
        .font(Font.custom("Figtree", size: 12).weight(.medium))
        .foregroundColor(
          theme.isDark ? Color(hex: "BFBFBF") : Color(red: 0.35, green: 0.35, blue: 0.35)
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .lineLimit(2)
      }

      Spacer()

      if !category.isSystem {
        Button {
          onStartEdit()
        } label: {
          Image("CategoriesEdit")
            .resizable()
            .frame(width: 20, height: 20)
            .accessibilityLabel("Edit category")
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        Button {
          onDelete()
        } label: {
          Image("CategoriesDelete")
            .resizable()
            .frame(width: 20, height: 20)
            .accessibilityLabel("Delete category")
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(theme.isDark ? Color(hex: "C3C3C3").opacity(0.1) : Color.white)
    .cornerRadius(4)
    .shadow(color: Color.black.opacity(theme.isDark ? 0 : 0.06), radius: 2, x: 0, y: 0)
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .inset(by: 0.25)
        .stroke(
          theme.isDark ? Color(hex: "4E4E4E") : Color(red: 0.89, green: 0.89, blue: 0.89),
          lineWidth: theme.isDark ? 1 : 0.5)
    )
    .overlay(
      Group {
        if theme.isDark {
          InnerGlow(
            shape: RoundedRectangle(cornerRadius: 4), color: Color.white.opacity(0.1), radius: 4)
        }
      }
    )
    .contentShape(Rectangle())
    .onTapGesture {
      if !category.isSystem {
        onStartEdit()
      }
    }
    .pointingHandCursor(enabled: !category.isSystem)
  }
}

struct ColorAssignmentCard: View {
  let category: TimelineCategory
  var showDetails: Bool = true
  var onColorDrop: (String) -> Void

  @Environment(\.dayflowTheme) private var theme
  @State private var isTargeted = false

  private func colorSwatch(_ hex: String) -> some View {
    let color = Color(hex: hex.isEmpty ? "#E5E7EB" : hex)
    return Rectangle()
      .foregroundColor(.clear)
      .frame(width: 18, height: 18)
      .background(color)
      .cornerRadius(6)
      .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .inset(by: 0.75)
          .stroke(.white, lineWidth: 1.5)
      )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 14) {
        colorSwatch(category.colorHex)

        VStack(alignment: .leading, spacing: 4) {
          Text(category.name)
            .font(Font.custom("Figtree", size: 12).weight(.bold))
            .foregroundColor(theme.isDark ? .white : .black)

          if showDetails
            && !category.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            Text(category.details)
              .font(Font.custom("Figtree", size: 12).weight(.medium))
              .foregroundColor(
                theme.isDark ? Color(hex: "BFBFBF") : Color(red: 0.35, green: 0.35, blue: 0.35)
              )
              .lineLimit(2)
          }
        }

        Spacer()
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .center)
    .background(theme.isDark ? Color(hex: "C3C3C3").opacity(0.1) : Color.white)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isTargeted
            ? (theme.isDark ? theme.accent : Color(red: 0.6, green: 0.5, blue: 0.4))
            : (theme.isDark ? Color(hex: "4E4E4E") : Color(red: 0.89, green: 0.89, blue: 0.89)),
          lineWidth: isTargeted ? 1.5 : (theme.isDark ? 1 : 0.8))
    )
    .cornerRadius(8)
    .shadow(color: Color.black.opacity(theme.isDark ? 0 : 0.06), radius: 2, x: 0, y: 1)
    .contentShape(Rectangle())
    .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
      guard let provider = providers.first else { return false }
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
        let value: String? = {
          if let data = item as? Data { return String(data: data, encoding: .utf8) }
          if let string = item as? String { return string }
          if let ns = item as? NSString { return ns as String }
          return nil
        }()
        if let hex = value {
          DispatchQueue.main.async {
            onColorDrop(hex)
          }
        }
      }
      return true
    }
  }
}
