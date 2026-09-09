import WebKit

/// Host-only overrides. AgentPlayback still owns skin selection and its light appearance.
enum AgentPlaybackAppearance {
  @MainActor
  static func apply(to webView: WKWebView, isDark: Bool) {
    webView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    webView.evaluateJavaScript(
      "document.documentElement.dataset.dayflowDark = '\(isDark)';", completionHandler: nil)
  }

  // The media query covers the initial navigation; native updates the attribute
  // when Dayflow's explicit appearance preference changes, without reloading.
  static let script = """
    (() => {
      const root = document.documentElement;
      if (!root.dataset.dayflowDark) {
        root.dataset.dayflowDark = String(matchMedia('(prefers-color-scheme: dark)').matches);
      }
      const style = document.createElement('style');
      style.id = 'dayflow-embedded-appearance';
      const scope = 'html[data-dayflow-dark="true"] body:is([data-skin="paper"], [data-skin="vinyl"])';
      style.textContent = `
        ${scope} {
          background: transparent !important;
          --bg: transparent;
          --bg-texture: none;
          --text-strong: #ffffff;
          --text-mid: #dddddd;
          --text-dim: #b4b4b4;
          --card-bg: rgba(255,255,255,.06);
          --card-border: rgba(255,255,255,.14);
          --panel-bg: rgba(255,255,255,.06);
          --panel-border: rgba(255,255,255,.14);
          --panel-head-bg: rgba(255,255,255,.08);
          --panel-head-text: #dddddd;
          --panel-cap: #b4b4b4;
          --panel-cost: #edbaa5;
          --nav-btn-bg: rgba(255,255,255,.10);
          --nav-btn-border: rgba(255,255,255,.16);
          --toggle-bg: rgba(255,255,255,.08);
          --toggle-active-bg: rgba(255,255,255,.16);
          --toggle-text: #b4b4b4;
          --toggle-active-text: #ffffff;
          --tooltip-bg: #303044;
          --tooltip-text: #ffffff;
          --chip-bg: rgba(143,154,255,.18);
          --chip-text: #bac2ff;
          --startend: #edbaa5;
          --callout-line: #dddddd;
          color: var(--text-strong);
        }
        ${scope} .date-nav button {
          background: var(--nav-btn-bg); border-color: var(--nav-btn-border);
          color: var(--text-strong);
        }
        ${scope} .skin-toggle button.active { box-shadow: none; }
        ${scope} :is(.legend-row, .playback-brand) { color: var(--text-mid); }
        ${scope} .color-editor {
          background: var(--panel-bg); border-color: var(--panel-border);
          color: var(--text-strong);
        }
        ${scope} .color-editor-header { color: var(--text-mid); }
        ${scope} .color-editor.open .color-editor-header { background: var(--panel-head-bg); }
        ${scope} .color-project {
          background: var(--toggle-bg); color: var(--text-strong);
          border-color: var(--panel-border);
        }
        ${scope} .color-project.active { box-shadow: 0 0 0 1px rgba(255,255,255,.24); }
        ${scope} .share-trigger {
          background: var(--panel-bg); color: var(--text-strong);
          border-color: var(--panel-border);
        }
        ${scope} .share-trigger.is-ready:hover { background: rgba(255,255,255,.14); }
        ${scope} .share-trigger.is-disabled { color: var(--text-dim); opacity: .6; }
        ${scope} .calendar-popover {
          background: var(--tooltip-bg); color: var(--text-strong);
          border-color: var(--panel-border);
        }
        ${scope} :is(.calendar-month-nav button, .calendar-day) { color: var(--text-strong); }
        ${scope} .calendar-day:not(.empty) {
          background: rgba(143,154,255,calc(var(--cost-alpha,0) * .26));
        }
        ${scope} .calendar-day.selected { border-color: rgba(255,255,255,.4); }
        ${scope} :is(.calendar-agents, .calendar-weekdays) { color: var(--text-dim); }
        ${scope} .calendar-day:is(.outside, .empty) { color: #858598; }
      `;
      document.head.appendChild(style);
    })();
    """
}
