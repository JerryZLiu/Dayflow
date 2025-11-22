# UI Migration Strategy: SwiftUI → WinUI 3

**Component**: User Interface
**Priority**: P0 - CRITICAL
**Complexity**: HIGH (complete rewrite required)

---

## Current macOS Implementation

### Technology Stack
- **Framework**: SwiftUI (Apple's declarative UI framework)
- **Platform**: macOS 13.0+
- **Language**: Swift
- **Architecture**: MVVM-like with `@State`, `@ObservedObject`, `@EnvironmentObject`

### Main UI Components

1. **App Shell** (`DayflowApp.swift`)
   - WindowGroup with hidden title bar
   - Launch video animation
   - Onboarding flow gate (first launch)
   - Main app view

2. **Main View** (`MainView.swift`)
   - Timeline display
   - Settings panel
   - Journal view
   - Dashboard view (future)

3. **Timeline View** (`CanvasTimelineDataView.swift`)
   - Scrollable timeline with cards
   - Video thumbnail integration
   - Category-based coloring
   - Time-based grouping

4. **Onboarding Flow** (`OnboardingFlow.swift`)
   - Multi-step wizard
   - Permission requests
   - LLM provider selection
   - API key input
   - Connection testing

5. **Settings Panel** (`SettingsView.swift`)
   - LLM provider configuration
   - Recording preferences
   - Storage management
   - About/version info

6. **Status Bar Menu** (`StatusMenuView.swift`)
   - System tray icon
   - Quick actions menu
   - Recording status indicator

### SwiftUI Patterns Used

```swift
// State management
@State private var isRecording = false
@AppStorage("didOnboard") private var didOnboard = false
@EnvironmentObject private var appState: AppState
@StateObject private var viewModel = TimelineViewModel()

// Declarative UI
VStack {
    Text("Timeline")
    ScrollView {
        ForEach(cards) { card in
            TimelineCardView(card: card)
        }
    }
}
.padding()
.background(Color.black)
```

---

## Windows Implementation: WinUI 3

### Technology Stack Recommendation
- **Framework**: WinUI 3 (Windows App SDK)
- **Platform**: Windows 10 1809+ (Windows 11 recommended)
- **Language**: C# (.NET 8)
- **Architecture**: MVVM with CommunityToolkit.Mvvm

### Why WinUI 3 Over WPF?

| Criteria | WinUI 3 | WPF |
|----------|---------|-----|
| **Modern Design** | ✅ Fluent Design, modern controls | ❌ Dated appearance |
| **Performance** | ✅ Better rendering, composition | ⚠️ Good but older tech |
| **Future-proof** | ✅ Microsoft's recommended path | ❌ Maintenance mode |
| **Compatibility** | ⚠️ Windows 10 1809+ | ✅ Windows 7+ |
| **Documentation** | ⚠️ Growing but incomplete | ✅ Extensive |
| **Packaging** | ✅ Modern MSIX packaging | ⚠️ Traditional installers |

**Decision**: Use WinUI 3 for modern UI, better long-term support.

---

## Component-by-Component Migration

### 1. App Shell & Window Management

#### macOS (SwiftUI)
```swift
@main
struct DayflowApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
    }
}
```

#### Windows (WinUI 3 + C#)
```csharp
// App.xaml.cs
public partial class App : Application
{
    private Window m_window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        m_window = new MainWindow();
        m_window.Activate();
    }
}

// MainWindow.xaml
<Window
    x:Class="Dayflow.MainWindow"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

    <Grid>
        <!-- Custom title bar -->
        <Grid.RowDefinitions>
            <RowDefinition Height="32"/> <!-- Title bar -->
            <RowDefinition Height="*"/>  <!-- Content -->
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" x:Name="AppTitleBar" Background="Transparent">
            <TextBlock Text="Dayflow" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </Grid>

        <NavigationView Grid.Row="1" x:Name="NavView">
            <Frame x:Name="ContentFrame"/>
        </NavigationView>
    </Grid>
</Window>

// MainWindow.xaml.cs
public MainWindow()
{
    InitializeComponent();

    // Custom title bar
    ExtendsContentIntoTitleBar = true;
    SetTitleBar(AppTitleBar);

    // Set default size
    var appWindow = this.AppWindow;
    appWindow.Resize(new SizeInt32(1200, 800));
}
```

**Migration Notes**:
- WinUI 3 requires explicit title bar customization
- Window size persistence handled via `ApplicationDataContainer`
- Navigation is explicit (Frame.Navigate) vs implicit (SwiftUI tabs)

---

### 2. Navigation & Tabs

#### macOS (SwiftUI)
```swift
TabView {
    TimelineView()
        .tabItem { Label("Timeline", systemImage: "clock") }

    SettingsView()
        .tabItem { Label("Settings", systemImage: "gear") }

    JournalView()
        .tabItem { Label("Journal", systemImage: "book") }
}
```

#### Windows (WinUI 3)
```xml
<NavigationView x:Name="NavView"
                PaneDisplayMode="Left"
                SelectionChanged="NavView_SelectionChanged">
    <NavigationView.MenuItems>
        <NavigationViewItem Content="Timeline" Icon="Clock" Tag="Timeline"/>
        <NavigationViewItem Content="Settings" Icon="Setting" Tag="Settings"/>
        <NavigationViewItem Content="Journal" Icon="Library" Tag="Journal"/>
    </NavigationView.MenuItems>

    <Frame x:Name="ContentFrame"/>
</NavigationView>
```

```csharp
private void NavView_SelectionChanged(NavigationView sender,
                                      NavigationViewSelectionChangedEventArgs args)
{
    if (args.SelectedItem is NavigationViewItem item)
    {
        switch (item.Tag.ToString())
        {
            case "Timeline":
                ContentFrame.Navigate(typeof(TimelinePage));
                break;
            case "Settings":
                ContentFrame.Navigate(typeof(SettingsPage));
                break;
            case "Journal":
                ContentFrame.Navigate(typeof(JournalPage));
                break;
        }
    }
}
```

---

### 3. Timeline View (Complex Scrolling List)

#### macOS (SwiftUI)
```swift
ScrollView {
    LazyVStack(spacing: 12) {
        ForEach(timelineCards) { card in
            TimelineCardView(card: card)
                .padding()
                .background(Color(card.category.color))
                .cornerRadius(12)
        }
    }
}
```

#### Windows (WinUI 3)
```xml
<ScrollViewer>
    <ItemsRepeater ItemsSource="{x:Bind ViewModel.TimelineCards, Mode=OneWay}">
        <ItemsRepeater.ItemTemplate>
            <DataTemplate x:DataType="local:TimelineCard">
                <Border Padding="12" Margin="0,0,0,12"
                        Background="{x:Bind CategoryColor}"
                        CornerRadius="12">
                    <StackPanel>
                        <TextBlock Text="{x:Bind Title}"
                                   FontSize="18" FontWeight="SemiBold"/>
                        <TextBlock Text="{x:Bind TimeRange}"
                                   FontSize="14" Opacity="0.8"/>
                        <TextBlock Text="{x:Bind Summary}"
                                   TextWrapping="Wrap"/>
                    </StackPanel>
                </Border>
            </DataTemplate>
        </ItemsRepeater.ItemTemplate>
    </ItemsRepeater>
</ScrollViewer>
```

**Migration Notes**:
- `ItemsRepeater` is WinUI 3 equivalent of `LazyVStack` (virtualizes items)
- Data binding uses `{x:Bind}` for compiled bindings (faster than WPF)
- Must implement `INotifyPropertyChanged` in view models

---

### 4. Onboarding Flow (Multi-step Wizard)

#### macOS (SwiftUI)
```swift
struct OnboardingFlow: View {
    @State private var currentStep = 0

    var body: some View {
        TabView(selection: $currentStep) {
            WelcomeView().tag(0)
            PermissionsView().tag(1)
            LLMSetupView().tag(2)
            CompletionView().tag(3)
        }
        .tabViewStyle(.page)
    }
}
```

#### Windows (WinUI 3)
```xml
<!-- OnboardingWindow.xaml -->
<Window>
    <Grid>
        <!-- Step indicator -->
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <Ellipse Width="12" Height="12" Fill="{x:Bind StepColor(0)}"/>
            <Ellipse Width="12" Height="12" Fill="{x:Bind StepColor(1)}"/>
            <Ellipse Width="12" Height="12" Fill="{x:Bind StepColor(2)}"/>
            <Ellipse Width="12" Height="12" Fill="{x:Bind StepColor(3)}"/>
        </StackPanel>

        <!-- Content frame -->
        <Frame x:Name="OnboardingFrame"/>

        <!-- Navigation buttons -->
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Content="Back" Click="BackButton_Click"/>
            <Button Content="Next" Click="NextButton_Click"/>
        </StackPanel>
    </Grid>
</Window>
```

```csharp
private int _currentStep = 0;
private Type[] _steps = new[]
{
    typeof(WelcomePage),
    typeof(PermissionsPage),
    typeof(LLMSetupPage),
    typeof(CompletionPage)
};

private void NextButton_Click(object sender, RoutedEventArgs e)
{
    if (_currentStep < _steps.Length - 1)
    {
        _currentStep++;
        OnboardingFrame.Navigate(_steps[_currentStep]);
    }
}
```

---

### 5. Settings Panel

#### macOS (SwiftUI)
```swift
Form {
    Section("LLM Provider") {
        Picker("Provider", selection: $selectedProvider) {
            Text("Gemini").tag("gemini")
            Text("Ollama").tag("ollama")
        }

        if selectedProvider == "gemini" {
            SecureField("API Key", text: $apiKey)
        }
    }

    Section("Recording") {
        Toggle("Auto-start recording", isOn: $autoStart)
        Stepper("Idle timeout: \(idleMinutes) min",
                value: $idleMinutes, in: 1...60)
    }
}
```

#### Windows (WinUI 3)
```xml
<StackPanel Spacing="24">
    <!-- LLM Provider Section -->
    <StackPanel>
        <TextBlock Text="LLM Provider" FontSize="20" FontWeight="SemiBold"/>

        <ComboBox x:Name="ProviderComboBox"
                  SelectedItem="{x:Bind ViewModel.SelectedProvider, Mode=TwoWay}">
            <ComboBoxItem Content="Gemini" Tag="gemini"/>
            <ComboBoxItem Content="Ollama" Tag="ollama"/>
        </ComboBox>

        <PasswordBox x:Name="ApiKeyBox"
                     Password="{x:Bind ViewModel.ApiKey, Mode=TwoWay}"
                     Visibility="{x:Bind ViewModel.IsGeminiSelected, Mode=OneWay}"/>
    </StackPanel>

    <!-- Recording Section -->
    <StackPanel>
        <TextBlock Text="Recording" FontSize="20" FontWeight="SemiBold"/>

        <ToggleSwitch Header="Auto-start recording"
                      IsOn="{x:Bind ViewModel.AutoStartRecording, Mode=TwoWay}"/>

        <Slider Header="Idle timeout (minutes)"
                Minimum="1" Maximum="60" StepFrequency="1"
                Value="{x:Bind ViewModel.IdleMinutes, Mode=TwoWay}"/>
    </StackPanel>
</StackPanel>
```

---

### 6. System Tray Icon (Status Bar)

#### macOS (SwiftUI + AppKit)
```swift
// StatusBarController.swift
class StatusBarController {
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()

    init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(named: "MenuBarIcon")

        popover.contentViewController = NSHostingController(
            rootView: StatusMenuView())
    }
}
```

#### Windows (WinUI 3 + Win32)
```csharp
// SystemTrayService.cs
using Microsoft.UI.Xaml.Controls;
using Windows.UI.Notifications;
using H.NotifyIcon; // NuGet: H.NotifyIcon.WinUI

public class SystemTrayService
{
    private TaskbarIcon _trayIcon;

    public void Initialize()
    {
        _trayIcon = new TaskbarIcon
        {
            IconSource = new BitmapImage(
                new Uri("ms-appx:///Assets/TrayIcon.ico")),
            ToolTipText = "Dayflow"
        };

        // Context menu
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem
        {
            Text = "Start Recording",
            Command = StartRecordingCommand
        });
        menu.Items.Add(new MenuFlyoutItem
        {
            Text = "Stop Recording",
            Command = StopRecordingCommand
        });
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem
        {
            Text = "Open Dayflow",
            Command = ShowMainWindowCommand
        });

        _trayIcon.ContextMenuMode = H.NotifyIcon.ContextMenuMode.PopupMenu;
        _trayIcon.ContextMenuFlyout = menu;
    }
}
```

**Note**: Requires `H.NotifyIcon.WinUI` NuGet package for easy system tray integration.

---

## State Management & Data Binding

### macOS: SwiftUI Property Wrappers
```swift
@State private var count = 0              // Local state
@AppStorage("key") var value = ""         // UserDefaults
@ObservedObject var viewModel: VM         // External state
@EnvironmentObject var appState: AppState // Dependency injection
```

### Windows: MVVM with CommunityToolkit.Mvvm

```csharp
// ViewModel base class
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

public partial class TimelineViewModel : ObservableObject
{
    [ObservableProperty]
    private ObservableCollection<TimelineCard> _timelineCards;

    [ObservableProperty]
    private bool _isRecording;

    [RelayCommand]
    private async Task StartRecordingAsync()
    {
        IsRecording = true;
        await _recordingService.StartAsync();
    }
}
```

```xml
<!-- XAML binding -->
<ItemsControl ItemsSource="{x:Bind ViewModel.TimelineCards, Mode=OneWay}"/>
<ToggleSwitch IsOn="{x:Bind ViewModel.IsRecording, Mode=TwoWay}"/>
<Button Command="{x:Bind ViewModel.StartRecordingCommand}"/>
```

**Key Differences**:
- WinUI requires explicit `INotifyPropertyChanged` implementation
- CommunityToolkit.Mvvm generates boilerplate code via source generators
- `{x:Bind}` is compile-time binding (faster, type-safe)

---

## Video Player Integration

### macOS (AVKit)
```swift
import AVKit

struct VideoPlayerView: View {
    let videoURL: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player = AVPlayer(url: videoURL)
            }
    }
}
```

### Windows (MediaPlayerElement)
```xml
<MediaPlayerElement x:Name="MediaPlayer"
                    AutoPlay="True"
                    AreTransportControlsEnabled="True"/>
```

```csharp
var mediaSource = MediaSource.CreateFromUri(new Uri(videoPath));
MediaPlayer.Source = mediaSource;
MediaPlayer.MediaPlayer.Play();
```

---

## Styling & Theming

### macOS (SwiftUI)
```swift
.background(Color.black)
.foregroundColor(.white)
.font(.system(size: 16, weight: .semibold))
.cornerRadius(12)
.shadow(radius: 4)
```

### Windows (WinUI 3)
```xml
<Border Background="{ThemeResource CardBackgroundFillColorDefaultBrush}"
        CornerRadius="12">
    <TextBlock Text="Hello"
               Foreground="{ThemeResource TextFillColorPrimaryBrush}"
               FontSize="16"
               FontWeight="SemiBold"/>
</Border>
```

**Theme Support**:
- WinUI 3 has built-in light/dark theme switching
- Use `{ThemeResource}` for automatic theme adaptation
- Access via `Application.Current.RequestedTheme`

---

## Custom Fonts

### macOS (Info.plist)
```xml
<key>UIAppFonts</key>
<array>
    <string>Fonts/Nunito-Bold.ttf</string>
    <string>Fonts/Figtree-SemiBold.ttf</string>
</array>
```

### Windows (Package.appxmanifest)
```xml
<Package>
  <Applications>
    <Application>
      <Extensions>
        <uap:Extension Category="windows.fileTypeAssociation">
          <uap:FileTypeAssociation Name="fonts">
            <uap:SupportedFileTypes>
              <uap:FileType>.ttf</uap:FileType>
            </uap:SupportedFileTypes>
          </uap:FileTypeAssociation>
        </uap:Extension>
      </Extensions>
    </Application>
  </Applications>
</Package>
```

```xml
<!-- Usage in XAML -->
<TextBlock FontFamily="Assets/Fonts/Nunito-Bold.ttf#Nunito"/>
```

---

## Animation

### macOS (SwiftUI)
```swift
.scaleEffect(isVisible ? 1.0 : 0.8)
.opacity(isVisible ? 1.0 : 0.0)
.animation(.easeInOut(duration: 0.3), value: isVisible)
```

### Windows (WinUI 3)
```xml
<Border x:Name="AnimatedElement">
    <Border.Transitions>
        <TransitionCollection>
            <EntranceThemeTransition/>
        </TransitionCollection>
    </Border.Transitions>
</Border>
```

```csharp
// Code-behind animation
var scaleAnimation = new ScaleAnimation
{
    Duration = TimeSpan.FromMilliseconds(300),
    From = "0.8",
    To = "1.0"
};
await AnimatedElement.StartAsync(scaleAnimation);
```

**Note**: WinUI 3 uses Composition APIs for advanced animations (similar to Core Animation on macOS)

---

## Migration Checklist

### Core UI Components
- [ ] Main window with custom title bar
- [ ] Navigation between Timeline/Settings/Journal
- [ ] Timeline scrolling list with virtualization
- [ ] Onboarding multi-step wizard
- [ ] Settings panel with form controls
- [ ] System tray icon and context menu

### Data Binding
- [ ] MVVM architecture setup
- [ ] ObservableCollection for lists
- [ ] INotifyPropertyChanged for view models
- [ ] Dependency injection (via CommunityToolkit.Mvvm or MS.Extensions.DependencyInjection)

### Media
- [ ] Video player for timelapses
- [ ] Thumbnail display in timeline
- [ ] Image caching for performance

### Theming
- [ ] Light/dark theme support
- [ ] Custom brand colors
- [ ] Fluent Design acrylic effects (optional)

### Animations
- [ ] Page transitions
- [ ] Card entrance animations
- [ ] Loading indicators

### Custom Controls
- [ ] Timeline card component
- [ ] Category color picker
- [ ] Time range scrubber

---

## Recommended Libraries

| Purpose | Library | NuGet Package |
|---------|---------|---------------|
| MVVM | CommunityToolkit.Mvvm | `CommunityToolkit.Mvvm` |
| System Tray | H.NotifyIcon | `H.NotifyIcon.WinUI` |
| Navigation | Built-in | `Microsoft.UI.Xaml` |
| Animations | Composition API | `Microsoft.UI.Composition` |
| HTTP Client | Built-in | `System.Net.Http` |
| JSON | Built-in | `System.Text.Json` |
| SQLite | Microsoft.Data.Sqlite | `Microsoft.Data.Sqlite` |

---

## Timeline Estimate

| Component | Estimated Duration |
|-----------|-------------------|
| App shell & window setup | 2-3 days |
| Navigation framework | 2-3 days |
| Timeline view (complex list) | 5-7 days |
| Onboarding flow | 3-5 days |
| Settings panel | 2-3 days |
| System tray integration | 2-3 days |
| Video player | 2-3 days |
| Theming & polish | 3-5 days |
| **TOTAL** | **3-4 weeks** |

---

## References

- [WinUI 3 Documentation](https://learn.microsoft.com/en-us/windows/apps/winui/winui3/)
- [CommunityToolkit.Mvvm Docs](https://learn.microsoft.com/en-us/dotnet/communitytoolkit/mvvm/)
- [WinUI 3 Gallery App (Sample)](https://github.com/microsoft/WinUI-Gallery)
- [H.NotifyIcon Documentation](https://github.com/HavenDV/H.NotifyIcon)

---

**Created**: 2025-11-17
**Last Updated**: 2025-11-17
