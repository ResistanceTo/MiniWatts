import AppIntents
import SwiftUI

@main
struct MiniWattsApp: App {
    @State private var monitor: PowerMonitor
    /// One per process, and alive for as long as the app is: the layer Picture in
    /// Picture draws from cannot come and go with a settings sheet.
    @State private var floatingMeter = FloatingMeterController()

    init() {
        let monitor = PowerMonitor()
        _monitor = State(initialValue: monitor)
        // The Shortcuts action runs in this process — launched in the background, with
        // no scene, when the app is not already running — and has to read through this
        // monitor's sensors rather than open its own: a process gets one working HID
        // client, and a second one reads NaN. Registered here because `init` is the
        // one place that runs on every launch, scene or no scene.
        AppDependencyManager.shared.add(dependency: monitor)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(monitor)
                .environment(floatingMeter)
        }
    }
}
