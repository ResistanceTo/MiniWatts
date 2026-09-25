import SwiftUI
import UIKit

struct RootView: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(FloatingMeterController.self) private var floatingMeter
    @Environment(\.scenePhase) private var scenePhase
    @State private var liveActivity = ChargeActivityController()
    @State private var widgets = WidgetPublisher()

    var body: some View {
        TabView {
            TabPage { DashboardView() }
                .tabItem { Label("Power", systemImage: "bolt.fill") }
            TabPage { ThermalView() }
                .tabItem { Label("Thermal", systemImage: "thermometer.medium") }
            TabPage { AdapterView() }
                .tabItem { Label("Adapter", systemImage: "powerplug.fill") }
            TabPage { DevicesView() }
                .tabItem { Label("Devices", systemImage: "square.stack.3d.up.fill") }
            TabPage { SessionsView() }
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
        }
        .tint(.mwAccent)
        .background { ScreenAwakeHolder() }
        // The layer Picture in Picture draws from has to be on screen for the system
        // to open a window from it, so it sits here, a few points across, for the
        // life of the app. Nothing is ever read off it here.
        .background(alignment: .topLeading) {
            FloatingMeterStage(controller: floatingMeter)
                .frame(width: 16, height: 9)
                .opacity(0.02)
                .allowsHitTesting(false)
        }
        .task {
            // Every glance is fed from the tick rather than from `onChange`: SwiftUI
            // stops updating views once the app is off screen, and off screen is
            // exactly where the floating meter earns its keep. Each consumer
            // throttles itself; this only hands over the reading.
            monitor.onTick = { [liveActivity, widgets, floatingMeter] snapshot in
                let reading = ChargeReading(snapshot)
                floatingMeter.render(snapshot: snapshot,
                                     thermalState: monitor.thermal.state)
                liveActivity.sync(snapshot,
                                  selectedMetric: monitor.liveActivityMetric,
                                  enabled: monitor.showsLiveActivityWhileCharging,
                                  isForeground: UIApplication.shared.applicationState == .active)
                widgets.publish(reading, lastSession: monitor.sessions.first)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                monitor.start()
            case .background:
                // Sensor reads are pointless while suspended, so the tick stops —
                // but an open charge session stays open. It ends when the charger
                // comes out, not when the app goes off screen.
                //
                // Unless the floating meter is up: PiP keeps the process running, so
                // the sensors can still be read, the window keeps a live number on
                // screen and the charge is recorded through a locked screen.
                if !floatingMeter.isRunning {
                    monitor.pause()
                }
                // Last chance to leave the widget something fresh to fall back on.
                widgets.flush(ChargeReading(monitor.snapshot), lastSession: monitor.sessions.first)
            default:
                // `.inactive` is transient and the app is still on screen for most
                // of it: a pulled-down Control Center, the app switcher, an
                // incoming call. Nothing to do.
                break
            }
        }
    }
}

/// A tab's page, built only while the tab is on screen.
///
/// A `TabView` keeps every tab that has been visited alive, and keeps updating it:
/// each page reads the monitor, so each one was re-evaluated on every tick, on
/// screen or not. With all five visited that was five pages rebuilt once a second,
/// and scrolling the one in front hitched at exactly that rhythm. The price is that
/// a tab comes back scrolled to the top.
///
/// The switch has to live inside the tab. Deciding it in `RootView` from the
/// selection does not work: a tab that is not showing never receives its parent's
/// update, so it kept the page it had and went on updating it.
private struct TabPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var isOnScreen = true

    var body: some View {
        ZStack {
            if isOnScreen {
                content()
            } else {
                Color.clear
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }
}

/// Holds the screen on, but only while it is actually earning something: the app
/// is in front and the phone is plugged in. Keeping a battery instrument awake on
/// battery would be a poor joke.
///
/// A view of its own because deciding needs the snapshot, which changes every
/// second. Read in `RootView`'s body, it re-ran that body — and the tab view under
/// it — on every tick; here it re-runs an empty view.
private struct ScreenAwakeHolder: View {
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .onChange(of: shouldStayAwake, initial: true) { _, awake in
                UIApplication.shared.isIdleTimerDisabled = awake
            }
    }

    private var shouldStayAwake: Bool {
        monitor.keepScreenAwakeWhileCharging
            && monitor.snapshot.externalConnected
            && scenePhase == .active
    }
}

/// Shared page chrome: the instrument backdrop behind a scrolling column of panels.
///
/// The page's content and glow are closures, called by small views of their own
/// rather than here. Every page reads the monitor, and whatever a body reads
/// during evaluation re-runs that body when it changes: called here, a page's
/// reads made this scaffold re-run every tick, and with it the navigation stack,
/// the title, the toolbar and the scroll view. Now only `PageContent` and
/// `PageBackdrop` re-run, and the chrome stays as it is. For the same reason a
/// page must not read the monitor in its own body outside these closures.
struct PageScaffold<Content: View>: View {
    let title: LocalizedStringResource
    var glow: () -> Color
    var toolbar: AnyView?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringResource,
         glow: @autoclosure @escaping () -> Color = .mwAccent,
         toolbar: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.glow = glow
        self.toolbar = toolbar
        self.content = content
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PageBackdrop(glow: glow)
                ScrollView {
                    // Lazy, not a plain `VStack`. History puts up to sixty session
                    // panels in here, each with its own sparkline, and an eager stack
                    // builds and measures every one of them — while charging, once a
                    // second, because the page reads the live session.
                    LazyVStack(spacing: 14) {
                        PageContent(content: content)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                    // Pinned to the container's width so nothing inside can widen the
                    // scroll content. A paragraph inside an HStack reports an enormous
                    // ideal width — the text unwrapped onto one line — and
                    // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                    // that width propagates up and the page starts scrolling sideways.
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if let toolbar {
                    ToolbarItem(placement: .topBarTrailing) { toolbar }
                }
            }
        }
    }
}

/// Calls a page's content closure, so that the monitor reads inside it are this
/// view's dependencies and not `PageScaffold`'s. A custom view's body is flattened
/// into the enclosing list, so the stack stays lazy panel by panel.
private struct PageContent<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}

/// The backdrop, with its glow read here for the same reason.
private struct PageBackdrop: View {
    let glow: () -> Color

    var body: some View {
        Backdrop(glow: glow())
    }
}

/// Used wherever a probe legitimately has nothing to report.
struct EmptyNote: View {
    let text: LocalizedStringResource
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.mwMuted)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.mwMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
