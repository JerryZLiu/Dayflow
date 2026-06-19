import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ColorOrganizerRoot: View {
  enum PresentationStyle {
    case embedded
    case sheet
  }

  enum FlowMode {
    case detailsAndColors
    case colorsOnly
  }

  var presentationStyle: PresentationStyle = .embedded
  var flowMode: FlowMode = .detailsAndColors
  var onBack: (() -> Void)?
  var onDismiss: (() -> Void)?
  var completionButtonTitle: String?
  var showsTitles: Bool = true
  var analyticsSurface: String? = nil
  @EnvironmentObject private var categoryStore: CategoryStore

  private enum CategorySetupStage: String, Hashable {
    case details
    case colors
  }

  @State private var stage: CategorySetupStage
  @State private var editingCategoryID: UUID?
  @State private var draftName: String = ""
  @State private var draftDetails: String = ""
  @State private var numPoints: Int = 3
  @State private var normalizedRadius: Double = 0.7
  @State private var currentAngle: Double = -Double.pi / 2
  @State private var isDraggingColor: Bool = false
  @State private var showFirstTimeHints: Bool = !UserDefaults.standard.bool(
    forKey: CategoryStore.StoreKeys.hasUsedApp)
  @State private var pendingScrollTarget: UUID? = nil
  @State private var isAddButtonHovered: Bool = false
  @State private var trackedStages: Set<CategorySetupStage> = []
  @State private var addCount = 0
  @State private var deleteCount = 0
  @State private var renameCount = 0
  @State private var detailsUpdateCount = 0
  @State private var colorChangeCount = 0
  @State private var didAdjustPalette = false

  init(
    presentationStyle: PresentationStyle = .embedded,
    flowMode: FlowMode = .detailsAndColors,
    onBack: (() -> Void)? = nil,
    onDismiss: (() -> Void)? = nil,
    completionButtonTitle: String? = nil,
    showsTitles: Bool = true,
    analyticsSurface: String? = nil
  ) {
    self.presentationStyle = presentationStyle
    self.flowMode = flowMode
    self.onBack = onBack
    self.onDismiss = onDismiss
    self.completionButtonTitle = completionButtonTitle
    self.showsTitles = showsTitles
    self.analyticsSurface = analyticsSurface
    _stage = State(initialValue: flowMode == .colorsOnly ? .colors : .details)
  }

  private var categories: [TimelineCategory] {
    categoryStore.editableCategories
  }

  private var isOnboardingAnalyticsEnabled: Bool {
    analyticsSurface == "onboarding"
  }

  private var onboardingRole: String {
    UserDefaults.standard.string(forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
      ?? "unknown"
  }

  private var onboardingPreset: String {
    UserDefaults.standard.string(forKey: CategoryStore.StoreKeys.onboardingAppliedCategoryPreset)
      ?? "unknown"
  }

  private var supportsDetailsStage: Bool {
    flowMode == .detailsAndColors
  }

  private var spectrumColors: [String] {
    (0..<8).map { i in
      let angleOffset = Double(i) * (.pi * 2) / 8.0
      let angle = currentAngle + angleOffset
      let hue = angle * 180.0 / .pi
      let lightness = 15 + 75 * normalizedRadius
      return hslToHex(hue, 100, lightness)
    }
  }

  var body: some View {
    ZStack {
      backgroundView
      contentCard
    }
    .onAppear {
      trackStageViewIfNeeded(stage)
    }
    .onChange(of: stage) { _, newStage in
      trackStageViewIfNeeded(newStage)
    }
    .onDisappear {
      commitPendingEditsIfNeeded()
    }
  }

  private var contentCard: some View {
    GeometryReader { proxy in
      let isCompact = proxy.size.width < 960
      let innerHorizontalPadding: CGFloat = isCompact ? 28 : 64
      let outerHorizontalPadding: CGFloat = isCompact ? 16 : 40
      let stackSpacing: CGFloat = isCompact ? 32 : 48
      let columnSpacing: CGFloat = isCompact ? 24 : 56
      let verticalSpacing = showsTitles ? stackSpacing / 2 : 24

      VStack(spacing: verticalSpacing) {
        if stage == .details && showsTitles {
          Text("Customize your categories")
            .font(Font.custom("Instrument Serif", size: 44))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .center)
        }

        if stage == .details {
          HStack(alignment: .top, spacing: columnSpacing) {
            instructionsPanel(isCompact: isCompact, showTitles: showsTitles)
              .frame(minWidth: 200, maxWidth: isCompact ? 240 : 280, alignment: .leading)
              .layoutPriority(1)

            categoryEditorPanel(isCompact: isCompact)
              .layoutPriority(0)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(alignment: .top, spacing: columnSpacing) {
            colorPickerPanel(isCompact: isCompact, showTitles: showsTitles)
              .frame(minWidth: 220, maxWidth: isCompact ? 260 : 320, alignment: .leading)
              .layoutPriority(1)

            colorAssignmentPanel(isCompact: isCompact)
              .layoutPriority(0)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, innerHorizontalPadding)
      .padding(.vertical, isCompact ? 32 : 40)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(
        Group {
          if presentationStyle == .sheet {
            RoundedRectangle(cornerRadius: 20)
              .fill(Color.white)
              .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)
          }
        }
      )
      .padding(.horizontal, outerHorizontalPadding)
      .padding(.vertical, presentationStyle == .sheet ? 24 : 0)
    }
  }

  private func instructionsPanel(isCompact: Bool, showTitles: Bool) -> some View {
    VStack(alignment: .leading, spacing: showTitles ? 20 : 16) {
      if showTitles {
        VStack(alignment: .leading, spacing: 6) {
          Text("Part 1 of 2")
            .font(Font.custom("Figtree", size: 14).weight(.bold))
            .foregroundColor(Color(red: 0.98, green: 0.43, blue: 0))
            .frame(maxWidth: .infinity, alignment: .leading)

          Text("Edit title and description")
            .font(Font.custom("Instrument Serif", size: 30))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      VStack(alignment: .leading, spacing: 16) {
        instructionRow(
          icon: "CategoriesOrganize",
          text:
            "Dayflow organizes your activities by the category titles and descriptions you provide."
        )
        .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)

        instructionRow(
          icon: "CategoriesTextSelect",
          text:
            "Try to provide as much details in the descriptions as you can to help Dayflow understand your workflow and habits."
        )
        .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)
      }

      Text(
        "This step is optional. You can customize the categories or create new ones anytime while using Dayflow."
      )
      .font(Font.custom("Figtree", size: 12).weight(.medium))
      .foregroundColor(Color(red: 0.48, green: 0.48, blue: 0.48))
      .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)
    }
  }

  private func instructionRow(icon: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(icon)
        .resizable()
        .frame(width: 28, height: 28)

      Text(text)
        .font(Font.custom("Figtree", size: 14).weight(.medium))
        .foregroundColor(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func colorPickerPanel(isCompact: Bool, showTitles: Bool) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      if showTitles {
        VStack(alignment: .leading, spacing: 6) {
          Text("Part 2 of 2")
            .font(Font.custom("Figtree", size: 14).weight(.bold))
            .foregroundColor(Color(red: 0.98, green: 0.43, blue: 0))
            .frame(maxWidth: .infinity, alignment: .leading)

          Text("Edit colors")
            .font(Font.custom("Instrument Serif", size: 30))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      VStack(spacing: 12) {
        ZStack {
          DotPattern(width: 10, height: 10)
            .frame(width: 224, height: 224)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)

          ColorPickerView(
            size: 224,
            padding: 20,
            bulletRadius: 24,
            spreadFactor: 0.4,
            minSpread: .pi / 1.5,
            maxSpread: .pi / 3,
            minLight: 15,
            maxLight: 90,
            showColorWheel: false,
            numPoints: numPoints,
            onColorChange: { _ in },
            onRadiusChange: { updatePaletteRadius($0) },
            onAngleChange: { updatePaletteAngle($0) }
          )
        }
        .frame(width: 224, height: 224)

      }

      VStack(alignment: .leading, spacing: 12) {
        Text(
          isDraggingColor
            ? "Drop on a category →"
            : "Click and drag on the canvas above to change the color palette. Then drag a color onto a category."
        )
        .font(Font.custom("Figtree", size: 13).weight(.medium))
        .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))

        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8
        ) {
          ForEach(Array(spectrumColors.enumerated()), id: \.offset) { index, hex in
            ColorSwatch(
              hex: hex,
              showHint: showFirstTimeHints && index == 0,
              onDragStart: {
                isDraggingColor = true
                showFirstTimeHints = false
              }
            )
          }
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
          isDraggingColor = false
          return false
        }
      }
    }
  }

  private var canAddMoreCategories: Bool {
    categories.count < 20
  }

  private var addCategoryButton: some View {
    Button {
      createNewCategory()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(Color(red: 0.49, green: 0.33, blue: 0.16))

        Text("Create a new category")
          .font(Font.custom("Figtree", size: 14).weight(.bold))
          .foregroundColor(Color(red: 0.49, green: 0.33, blue: 0.16))
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        LinearGradient(
          gradient: Gradient(stops: [
            .init(color: Color(red: 1, green: 0.94, blue: 0.79), location: 0),
            .init(color: Color(red: 1, green: 0.72, blue: 0.43), location: 1),
          ]),
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .inset(by: 0.5)
          .stroke(Color(red: 0.95, green: 0.71, blue: 0.56), lineWidth: 1)
      )
      .opacity(canAddMoreCategories ? 1 : 0.45)
    }
    .buttonStyle(.plain)
    .disabled(!canAddMoreCategories)
    .scaleEffect(isAddButtonHovered ? 1.02 : 1.0)
    .animation(.easeOut(duration: 0.18), value: isAddButtonHovered)
    .shadow(
      color: Color.black.opacity(isAddButtonHovered ? 0.18 : 0.1),
      radius: isAddButtonHovered ? 6 : 3, x: 0, y: isAddButtonHovered ? 3 : 1
    )
    .onHover { hovering in
      if canAddMoreCategories {
        isAddButtonHovered = hovering
      } else {
        isAddButtonHovered = false
      }
    }
    .pointingHandCursor(enabled: canAddMoreCategories)
  }

  private func colorAssignmentPanel(isCompact: Bool) -> some View {
    let containerHeight: CGFloat = (isCompact ? 404 : 494) * 0.75

    return VStack(alignment: .leading, spacing: 16) {
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.white.opacity(0.2))
          .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

        RoundedRectangle(cornerRadius: 16)
          .stroke(Color(red: 0.94, green: 0.91, blue: 0.87), lineWidth: 1)
          .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

        ScrollView(showsIndicators: false) {
          VStack(spacing: 8) {
            ForEach(categories) { category in
              ColorAssignmentCard(
                category: category,
                showDetails: supportsDetailsStage,
                onColorDrop: { hex in
                  assignColor(hex, to: category)
                  isDraggingColor = false
                }
              )
            }
          }
          .padding(.horizontal, 16)
          .padding(.top, 16)
          .padding(.bottom, 24)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .frame(maxWidth: isCompact ? .infinity : 708)
      .frame(height: containerHeight, alignment: .topLeading)

      Text("This step is optional. You can change the colors anytime while using Dayflow.")
        .font(Font.custom("Figtree", size: 12).weight(.medium))
        .foregroundColor(Color(red: 0.48, green: 0.48, blue: 0.48))
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 16) {
        SetupSecondaryButton(title: "Back") {
          if supportsDetailsStage {
            withAnimation(.easeInOut(duration: 0.25)) {
              isDraggingColor = false
              stage = .details
            }
          } else {
            onBack?()
          }
        }

        SetupContinueButton(title: completionButtonTitle ?? "Next", isEnabled: !categories.isEmpty)
        {
          trackColorsCompletion()
          categoryStore.persist()
          onDismiss?()
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
  }

  private func categoryEditorPanel(isCompact: Bool) -> some View {
    let containerHeight: CGFloat = (isCompact ? 404 : 494) * 0.75

    return ScrollViewReader { proxy in
      VStack(alignment: .leading, spacing: 24) {
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.2))
            .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

          RoundedRectangle(cornerRadius: 16)
            .stroke(Color(red: 0.94, green: 0.91, blue: 0.87), lineWidth: 1)
            .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

          ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
              if categories.isEmpty {
                emptyState
              } else {
                ForEach(categories) { category in
                  EditableCategoryCard(
                    category: category,
                    isEditing: editingCategoryID == category.id,
                    draftName: editingCategoryID == category.id
                      ? $draftName : .constant(category.name),
                    draftDetails: editingCategoryID == category.id
                      ? $draftDetails : .constant(category.details),
                    onStartEdit: { startEditing(category) },
                    onSave: { saveEdits(for: category) },
                    onDelete: { deleteCategory(category) }
                  )
                  .id(category.id)
                }
              }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 16)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxWidth: isCompact ? .infinity : 708)
        .frame(height: containerHeight, alignment: .topLeading)
        .onChange(of: pendingScrollTarget) { _, target in
          guard let target else { return }
          withAnimation(.easeOut(duration: 0.35)) {
            proxy.scrollTo(target, anchor: .bottom)
          }
          DispatchQueue.main.async { pendingScrollTarget = nil }
        }

        HStack(spacing: 16) {
          if supportsDetailsStage == false, let onBack {
            SetupSecondaryButton(title: "Back") {
              commitPendingEditsIfNeeded()
              onBack()
            }
          }

          addCategoryButton
          Spacer()
          SetupContinueButton(title: "Next", isEnabled: !categories.isEmpty) {
            commitPendingEditsIfNeeded()
            trackDetailsCompletion()
            categoryStore.persist()
            withAnimation(.easeInOut(duration: 0.25)) {
              stage = .colors
            }
          }
        }
      }
      .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
    }
  }

  private var emptyState: some View {
    Text("Add a category to get started.")
      .font(Font.custom("Figtree", size: 13).weight(.medium))
      .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()
      .background(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(red: 0.89, green: 0.89, blue: 0.89), lineWidth: 0.5)
      )
  }

  @ViewBuilder
  private var backgroundView: some View {
    switch presentationStyle {
    case .embedded:
      Color.clear
    case .sheet:
      Color.black.opacity(0.16)
        .ignoresSafeArea()
    }
  }

  private struct SetupSecondaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovered = false

    init(title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
      self.title = title
      self.isEnabled = isEnabled
      self.action = action
    }

    var body: some View {
      Button(action: isEnabled ? action : {}) {
        Text(title)
          .font(Font.custom("Figtree", size: 16).weight(.semibold))
          .foregroundColor(Color(red: 0.26, green: 0.26, blue: 0.26))
          .padding(.horizontal, 59)
          .padding(.vertical, 18)
          .frame(width: 160, alignment: .center)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.white.opacity(0.85))
              .overlay(
                RoundedRectangle(cornerRadius: 12)
                  .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 1)
              )
          )
          .opacity(isEnabled ? 1.0 : 0.4)
      }
      .buttonStyle(.plain)
      .scaleEffect(isPressed ? 0.96 : (isHovered && isEnabled ? 1.02 : 1.0))
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPressed)
      .animation(.easeOut(duration: 0.2), value: isHovered)
      .onHover { hovering in
        if isEnabled {
          isHovered = hovering
        }
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if isEnabled {
              isPressed = true
            }
          }
          .onEnded { _ in
            isPressed = false
          }
      )
      .disabled(!isEnabled)
      .pointingHandCursor(enabled: isEnabled)
    }
  }

  private func createNewCategory() {
    guard canAddMoreCategories else { return }

    withAnimation(.easeInOut(duration: 0.25)) {
      if stage != .details {
        stage = .details
      }

      showFirstTimeHints = false

      let baseName = "New category"
      var candidate = baseName
      var suffix = 2
      let existingNames = Set(categories.map { $0.name.lowercased() })
      while existingNames.contains(candidate.lowercased()) {
        candidate = "\(baseName) \(suffix)"
        suffix += 1
      }

      categoryStore.markOnboardingCategoriesCustomized()
      categoryStore.addCategory(name: candidate)
      addCount += 1
      captureOnboardingEvent(
        "onboarding_category_added",
        [
          "category_name": candidate,
          "total_count": categoryStore.editableCategories.count,
          "stage": CategorySetupStage.details.rawValue,
        ])
      let editable = categoryStore.editableCategories
      if let newlyCreated = editable.last {
        editingCategoryID = newlyCreated.id
        draftName = newlyCreated.name
        draftDetails = newlyCreated.details

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          pendingScrollTarget = newlyCreated.id
        }
      }
    }
  }

  private func startEditing(_ category: TimelineCategory) {
    if editingCategoryID != nil && editingCategoryID != category.id {
      commitPendingEditsIfNeeded()
    }
    withAnimation(.easeInOut(duration: 0.2)) {
      editingCategoryID = category.id
      draftName = category.name
      draftDetails = category.details
    }
  }

  private func saveEdits(for category: TimelineCategory) {
    let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    let didRename = !trimmedName.isEmpty && trimmedName != category.name
    let didUpdateDetails = draftDetails != category.details
    let previousName = category.name
    let previousDetails = category.details

    if didRename || didUpdateDetails {
      categoryStore.markOnboardingCategoriesCustomized()
    }

    if didRename {
      categoryStore.renameCategory(id: category.id, to: trimmedName)
      renameCount += 1
      captureOnboardingEvent(
        "onboarding_category_renamed",
        [
          "category_name": trimmedName,
          "previous_name": previousName,
          "stage": CategorySetupStage.details.rawValue,
        ])
    }
    categoryStore.updateDetails(draftDetails, for: category.id)
    if didUpdateDetails {
      detailsUpdateCount += 1
      captureOnboardingEvent(
        "onboarding_category_details_updated",
        [
          "category_name": didRename ? trimmedName : previousName,
          "details_length": draftDetails.count,
          "had_previous_details": previousDetails.isEmpty == false,
          "stage": CategorySetupStage.details.rawValue,
        ])
    }
    endEditing()
  }

  private func deleteCategory(_ category: TimelineCategory) {
    withAnimation(.easeInOut(duration: 0.2)) {
      if editingCategoryID == category.id {
        endEditing()
      }
      categoryStore.markOnboardingCategoriesCustomized()
      categoryStore.removeCategory(id: category.id)
      deleteCount += 1
      captureOnboardingEvent(
        "onboarding_category_deleted",
        [
          "category_name": category.name,
          "remaining_count": categoryStore.editableCategories.count,
          "stage": stage.rawValue,
        ])
    }
  }

  private func assignColor(_ hex: String, to category: TimelineCategory) {
    let previousHex = category.colorHex
    categoryStore.markOnboardingCategoriesCustomized()
    categoryStore.assignColor(hex, to: category.id)

    guard hex != previousHex else { return }

    colorChangeCount += 1
    captureOnboardingEvent(
      "onboarding_category_color_changed",
      [
        "category_name": category.name,
        "color_hex": hex,
        "previous_color_hex": previousHex,
        "stage": CategorySetupStage.colors.rawValue,
      ])
  }

  private func updatePaletteRadius(_ newRadius: Double) {
    if abs(newRadius - normalizedRadius) > 0.0001 {
      didAdjustPalette = true
    }
    normalizedRadius = newRadius
  }

  private func updatePaletteAngle(_ newAngle: Double) {
    if abs(newAngle - currentAngle) > 0.0001 {
      didAdjustPalette = true
    }
    currentAngle = newAngle
  }

  private func trackStageViewIfNeeded(_ stage: CategorySetupStage) {
    guard isOnboardingAnalyticsEnabled else { return }
    guard trackedStages.contains(stage) == false else { return }

    trackedStages.insert(stage)
    AnalyticsService.shared.screen("onboarding_categories_\(stage.rawValue)")
  }

  private func trackDetailsCompletion() {
    captureOnboardingEvent(
      "onboarding_categories_details_completed",
      [
        "stage": CategorySetupStage.details.rawValue,
        "added_count": addCount,
        "renamed_count": renameCount,
        "details_updated_count": detailsUpdateCount,
        "deleted_count": deleteCount,
      ])
  }

  private func trackColorsCompletion() {
    captureOnboardingEvent(
      "onboarding_categories_colors_completed",
      [
        "stage": CategorySetupStage.colors.rawValue,
        "added_count": addCount,
        "renamed_count": renameCount,
        "details_updated_count": detailsUpdateCount,
        "deleted_count": deleteCount,
        "color_changed_count": colorChangeCount,
        "did_adjust_palette": didAdjustPalette,
        "palette_radius": normalizedRadius,
        "palette_angle": currentAngle,
      ])
  }

  private func captureOnboardingEvent(_ name: String, _ extra: [String: Any]) {
    guard isOnboardingAnalyticsEnabled else { return }

    var payload: [String: Any] = [
      "surface": analyticsSurface ?? "unknown",
      "role": onboardingRole,
      "preset": onboardingPreset,
      "category_count": categories.count,
    ]

    extra.forEach { key, value in
      payload[key] = value
    }

    AnalyticsService.shared.capture(name, payload)
  }

  private func commitPendingEditsIfNeeded() {
    guard let editingID = editingCategoryID,
      let category = categories.first(where: { $0.id == editingID })
    else { return }
    saveEdits(for: category)
  }

  private func endEditing() {
    editingCategoryID = nil
    draftName = ""
    draftDetails = ""
  }
}

// App entry point intentionally omitted; DayflowApp provides the main entry.

#Preview("Timeline Card Color Picker") {
  ColorOrganizerRoot()
    .environmentObject(CategoryStore())
    .frame(minWidth: 980, minHeight: 640)
}
