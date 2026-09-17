# MiniWatts

Sideload-only iPhone battery instrument. Private APIs; never App Store safe.

The method for reading the PMU — dlsym'd IOKit, `IOHIDEventSystemClient` on usage
pages `0xff08` and `0xff00` — and the first version of the *Verified blocked* list
below are taken from
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor)
(ChargeSpeed, MIT). What is built on that is this project's own: the five screens,
the thermal zone mapping, the USB-PD inspector, the energy integration and session
history, and everything under *Sensor notes*, which the blocked list has since grown
by several entries.

## Build and run

- Plain Xcode project, no XcodeGen, no packages. `PBXFileSystemSynchronizedRootGroup`:
  new files under `MiniWatts/` join the target automatically, do not edit the pbxproj.
- iOS 17 deployment target, **Swift 6** language mode, Xcode 26+ required
  (`nonisolated` on type and extension declarations is Swift 6.2).
- `./scripts/build-ipa.sh` — unsigned ipa, the distributable one; runs
  `verify-clean.sh` on itself and fails if the artifact carries identifying data.
- `TEAM_ID=… ./scripts/build-ipa.sh signed` — for your own device. No default team
  lives in this repo; `DEVELOPMENT_TEAM` is empty in the pbxproj and Xcode will
  write yours back into it if you pick one in the UI. Do not commit that.
- `.github/workflows/build.yml` builds, verifies and (on a `v*` tag) releases.
- The simulator reads the **Mac's** battery through IOKit and has no HID sensors:
  fine for layout and for the adapter/PD panels, useless for anything sensor-driven.

## Layout

- `Core/Sensors/` — the probes. `IOKitBattery` (dlsym'd IOKit + powerd), `HIDSensors`
  (`IOHIDEventSystemClient`, one client per process, created once), `BatteryCenterBridge`,
  `ThermalMonitor` (`ProcessInfo.thermalState`, public API), `SensorCatalog`
  (name → zone/label by whole-word keyword, never exact).
- `Core/Model/` — `PowerSnapshot` merges all four sources and owns every derived value.
  Anything derived from the HID readings is resolved **once, in `init`, and stored** —
  it used to be computed per access, which meant a body asking for the battery
  temperature four times did four linear scans and called `SensorCatalog.zone(for:)`
  (which lowercases and splits) once per sensor per scan. Registry lookups stay
  computed: those are single hash hits. Also here:
  `EnergyAccumulator` integrates ∫V·I dt; `ChargeSession` + `SessionStore` persist charges
  as one JSON file in Application Support.
- `Core/PowerMonitor.swift` — `@Observable`, 1 s tick, drives everything and owns session
  lifecycle. Injected once in `MiniWattsApp`, read via `@Environment(PowerMonitor.self)`.
  `headline` lives here rather than on the snapshot: its last fallback is the %-rate
  estimate, which is derived across several snapshots and so is not a snapshot's to give.
- `Design/` — palette (`Color.mw(light:dark:)`, no asset catalog entries), `Panel`/
  `Metric`/`Pill`/`BarRow`, `PowerRing`, Swift Charts wrappers, `PhoneHeatMap`.
- `Features/` — one folder per tab, plus Settings. `DebugView` (Raw data) is reached
  from the bottom of Settings, not the main toolbar. It ships in release builds: its
  probes answer questions only hardware this project does not have can answer, and
  those answers arrive as dumps from people running the release. Nothing it reads may
  be gated on `#if DEBUG` — `PowerMonitor.powerSources` was, and its panel reported no
  power sources in every release build.
- `Shared/` — the four files compiled into both targets: `ChargeReading`,
  `ChargeActivityAttributes`, `WidgetSnapshot`, `ReadingWording`. `Widgets/` — the app
  side of the widget and the live activity (`WidgetPublisher`, `ChargeActivityController`),
  driven from the tick. `Floating/` — the Picture in Picture readout; see *The floating
  meter*. `Widget/`, at the top level, is the extension itself; see *Widgets and Live
  Activity*.

## Swift 6 isolation

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so everything is
main-actor isolated unless it says otherwise. Consequences that have already bitten:

- **`Theme.swift` must stay `nonisolated`.** `Color.mw` builds a `UIColor` with a
  trait-resolution closure, and UIKit calls that from whatever thread is resolving a
  dynamic colour while rendering. Under Swift 6 the compiler inserts an executor
  check there, and the app **traps on the first frame that paints a gradient**. It
  compiles fine either way — this is a runtime crash, not a build error.
- The whole `Core/` layer is `nonisolated`: it has no UI in it, and nonisolated
  protocol requirements (`Shape`, `Layout`, `Identifiable`, `Codable`) cannot be
  witnessed by main-actor-isolated members. `PowerMonitor` and `ThermalMonitor`
  stay on the main actor — they are `@Observable` UI state.
- `deinit` is nonisolated in Swift 6 and cannot touch isolated stored properties.
  `ThermalMonitor` therefore has no notification observers to tear down; it is
  polled from the one-second tick instead, which costs nothing and covers the same
  ground (nothing observes a change made while the app is suspended anyway).

## Sessions and the app lifecycle

A charge session ends when the **charger is unplugged**, not when the app leaves the
foreground. Three things make that work and they are easy to undo by accident:

- `RootView` calls `monitor.pause()` on `.background` only. It used to call a `stop()`
  that closed the session on anything that was not `.active`, and `.inactive` fires for
  a pulled-down Control Center, the app switcher, an incoming call and the screen
  locking — so an overnight charge was recorded as a scatter of two-minute fragments.
- `closeSessionIfNeeded` dates the end from `lastConnectedObservation`, the last tick
  that actually saw a charger, not from `.now`. Unplug while the app is suspended and
  the first tick after it wakes is the first that knows; `.now` there would stretch the
  session across however long the app was away.
- Settings has *keep the screen on while charging*, default on, applied in `RootView`
  (`isIdleTimerDisabled`) and gated on the phone being plugged in. Sensors can only be
  read while the app runs, so without it the screen locks and a full charge can never be
  recorded. UIKit stays in the view layer; `Core` only holds the preference. The other
  way to keep the tick alive is the floating meter, which runs through a locked screen.

`SessionStore` encodes and writes on its own serial queue, coalescing bursts, and the
load in `PowerMonitor.init` is a `Task`. At the ceiling — 60 sessions × 1,500 samples —
the file is several megabytes, and doing that inline was a stall before the first frame
and again every thirty seconds during a charge. `persist()` is a no-op until `isLoaded`,
or a save landing before the load would truncate the history to nothing.

## Localization

UI copy is in a String Catalog. Slots are typed by what they actually carry:

| Kind | Type | Examples |
| --- | --- | --- |
| Always copy | `LocalizedStringResource` | `Panel.title`, `Metric.caption`, `EmptyNote.text`, `DetailRow.label` |
| Always a measurement | `String` | `Metric.value`/`unit`, `BarRow.detail` |
| Either, decided per call | `Text` | `Panel.trailing`, `Pill.text`, `BarRow.title`/`subtitle`, `Metric.footnote` |

**`Text(someString)` is the non-localising overload.** Passing a `String` variable
where copy was meant does not just skip translation at runtime — the extractor has
nothing to extract either, so the string never reaches the catalog and nothing ever
flags it. That is how 49 user-visible strings were silently English-only after the
project had supposedly been localised: every `DetailRow` label, the five sentences of
`AdapterView.headroomReason`, the live-rail names, the session fallback titles, and
the Left/Right/Case/Internal/Wired/Wireless strings that `BatteryCenterBridge` used to
build in English inside the model. If a slot carries copy, type it
`LocalizedStringResource` or `Text` — never `String`. `DetailRow` has two initialisers
for exactly this: `label:` for copy, `rawLabel:` for an IOKit key.

`Text("…")` is extracted, `Text(verbatim:)` is not. The mixed slots exist because a
panel header reads `12 sensors` on one screen and `iPhone17,2` on the next, and a
hardware name must never reach the catalog as a lookup key. `SensorCatalog.label(for:)`
returns `LocalizedStringResource?` — nil means "show the raw sensor name".

Watch for: `String(format:)` still hardcodes the decimal separator, and
`Formatting.duration` hardcodes h/m/s. `Formatting.timestamp`/`clock` were moved to
`Date.FormatStyle` and do follow the locale.

## Verified blocked (don't retry)

**Sandbox, iOS 26/27.** `IOPMPowerSource` registry keys beyond `BatteryInstalled`/
`ExternalConnected`; `IOReport`; `IOPMCopyBatteryInfo`; `IOPSCopyChargeStatus`,
`IOPSCopyBatteryLevelLimits`, `IOPSCopyPowerSourcesInfoPrecise` (all
`kIOReturnNotPrivileged`); PowerUI XPC (Optimized Charging, charge limit); powerd
`Time to Empty` (always 0).

**Nothing about the charger's identity, and nothing about the cable.** Raw data has
a probe button for this (`AccessoryProbe`); re-run it on a new iOS rather than
deriving any of it again. On iOS 27 / iPhone18,4:

- **The registry nodes are all there.** `IOServiceMatching("IOAccessoryManager")`
  matches `IOAccessoryDock0PinBuiltin · Port-MagSafe` and
  `AppleHPMInterfaceType15 · Port-USB-C`; `IOAccessoryPort` matches
  `IOAccessoryPortUSB`; `IOPortTransportStateCC · CC` and
  `IOPortTransportComponentCCUSBPDSOP · SOP` both exist. This is the same driver
  family WhatCable reads on macOS, under slightly different type numbers.
- **Every property is filtered away.** `IORegistryEntryCreateCFProperties`
  *succeeds* — no `kIOReturn` at all — and returns `IOClass` alone on the three
  `IOAccessory*` nodes and an empty dictionary on the two transport nodes. All 39
  targeted per-key reads on all five services returned nothing: the whole
  `IOAccessoryUSB*` family (connect type, charging voltage, current limit),
  `IOAccessoryAccessoryManufacturer`/`Name`/`ModelNumber`/`SerialNumber`, the power
  modes, `IOAccessoryDigitalID`, and `Metadata` / `Vendor ID (SOP1)` /
  `Product ID (SOP1)` on the transport nodes.
- **`libIOAccessoryManager.dylib` loads and still exports all sixteen getters**, and
  they are useless anyway. Disassembling it shows they are built on exactly the two
  calls above: `IOAccessoryManagerGetUSBChargingVoltage` is one
  `IORegistryEntryCreateCFProperty("IOAccessoryUSBChargingVoltage")` plus
  `CFNumberGetValue`, and `IOAccessoryManagerGetUSBConnectType` is one
  `IORegistryEntryCreateCFProperties` plus two dictionary lookups. They can only
  return the same nothing, so do not go guessing their signatures.
- `IOPortFeaturePowerSource`, where macOS keeps the PDO list, does not exist on iOS.
  The profile menu arrives through `IOPSCopyExternalPowerAdapterDetails` instead.

**The cable's e-marker is not hidden — it is never read.**
`IOPortTransportComponentCCUSBPDSOPp` matches **no service**, while `…SOP` matches
one. SOP is the port partner, which is the charger; SOP′ is the cable. Only the port
that sources VCONN can talk to a cable plug, and while charging the phone is the
sink — the charger is the one that reads the cable, and it trims the `UsbHvcMenu` it
advertises to what the cable supports. macOS creates the SOP′ node only when it
needs the cable's rating (above 3 A, or Thunderbolt), so on a Mac charging over a
plain USB-C cable that node is absent too. Nothing about cable identity is reachable
on a phone at any privilege level, because the conversation does not happen there.
What is left is the cable's *effect*: the advertised menu against the charger's
rating, and the port voltage against the current through it — see `PathResistanceMeter`.

**Accessory battery levels are gone.** `BatteryCenter.framework` still loads from a
normal sandbox and `BCBatteryDeviceController` still exists, but:

- `+sharedInstance` **no longer exists** on iOS 26+ — the selector is not even in the
  framework binary. The controller is allocated with `+new` now, and
  `-addBatteryDeviceObserver:queue:` (protocol `BCBatteryDeviceObserving`, callback
  `connectedDevicesDidChange:`) is what starts collection.
- Even then `connectedDevices` returns an empty array, while the system Batteries
  widget shows the same devices. The console says it plainly:
  `(<_BCPowerSourceController: …>) Failed to obtain power sources info`. The
  controller's XPC to powerd is denied; it fails quietly and returns nothing.
- There is no public API either. Apple Watch is reachable only by shipping a
  watchOS companion app and sending `WKInterfaceDevice.batteryLevel` over
  `WatchConnectivity`. AirPods have no route at all — CoreBluetooth's standard
  Battery Service is not exposed by them, and ExternalAccessory is MFi-only.

The Devices tab therefore shows this iPhone and a placeholder. The card-rendering
code is still there and lights up if BatteryCenter ever answers again.

**No wireless input current.** Enumerating all 75 HID services on an iPhone 17 finds
eleven sensors on usage page `0xff08` and no `IQ1u` — the charge IC exposes the coil
voltage (`Charger VQ1u`) and nothing to multiply it by. Wireless input power cannot
be measured. The dial falls back to the battery-side figure and says "into battery".

**The adapter's voltage and current are a ceiling, not a reading.** Two MagSafe
samples minutes apart both reported `AdapterVoltage 6800` × `Current 661` while the
current into the cell fell from 0.76 A to 0.51 A; over USB-C the same pair equals the
`UsbHvcMenu` profile's `MaxVoltage` × `MaxCurrent` exactly (5 V × 3 A) while the phone
drew 3.9 W. Use it for the rating, never for live draw.

**No discharge-current sensor exists.** Discharge power comes from the %-rate estimate
against a pack energy the user sets in Settings.

## Sensor notes (iPhone 17 / iPhone18,4)

- `PMU tcal` reads exactly 51.8 °C in every sample while its neighbours move several
  degrees. It is a calibration constant. Excluded from anything that ranks sensors by
  heat, still listed in its zone — and that exclusion has to happen at the **grouping**,
  not only at `hottestSensor`. `temperaturesByZone` used to sort a zone's readings by
  value and hand out `.first`, which made `tcal` the SoC zone's representative: the heat
  map showed a permanently red 52° SoC pin while the "Hottest" readout an inch below it,
  which did exclude `tcal`, said 44°. `ZoneTemperatures.hottest` is the live-only
  maximum; `readings` keeps everything, with constants sorted last.
- Four separate sensors are all named `gas gauge battery`. `HIDSensors.Reading.id`
  therefore includes the service index — name alone gave `ForEach` duplicate ids.
- `Charger QQ0u` (usage 2) and `Charger WQ0u` (usage 3) look like **accumulators**,
  not readings, and stay out of every derived value until that is settled. They sit
  on the USB-C port, so they cannot be the wireless input; and `WQ0u` is not
  instantaneous power (it read 0.726 while `VQ0u × IQ0u` was 3.91 W). Two samples ten
  minutes apart on one connection had both rising monotonically — `QQ0u` 0.817 →
  1.495, `WQ0u` 3.629 → 6.530 — with ΔW/ΔQ = 4.28 against a `VQ0u` of 4.23–4.27 V.
  That ratio is dimensionally volts and lands on the measured rail, which reads as
  Q for charge and W for energy, the physics symbols; it would also explain why `ALS`
  carries the same pair, the convention being general rather than charger-specific.
  Not settled: the units are unknown, the two samples may straddle a replug, and the
  first guess — that Q and W were `I` and `V` scaled by one common factor — was
  falsified by the second sample, the ratios having matched to four digits once and
  then differed by 2.4%. To pin it: sample repeatedly *without* unplugging, check
  ΔQ/Δt against `IQ0u`, and check whether both reset on unplug.
- Enumerating **all** HID services needs `IOHIDEventSystemClientSetMatching(client, NULL)`.
  An empty matching dictionary matches nothing, which made the debug button look dead.
- `PMU tdie14`–`tdie17` appear in the service list but return NaN; they are skipped.
- **NaN is not the only "nothing here".** Users on other models reported a charge IC at
  −9199.4 °C, and the app drew it on the heat map as a temperature.
  `HIDSensors.plausibleCelsius` (−40…150) is applied where `PowerSnapshot` decides what
  counts as a temperature, not in `read()` — the reading stays in `sensors`, which Raw
  data shows unedited, and never reaches a zone, the heat map or a widget.
  `registryTemperature` goes through the same check, since its ÷100 scaling is only
  known to hold on the models checked here.
  Only temperature is filtered — volts and amps have shown no comparable sentinel, and
  a range tight enough to catch one would risk hiding a real rail on an unseen model.
  This catches impossible values, not merely wrong ones: Settings → About and the
  Thermal page both say which model the build was verified on, because a mis-scaled
  reading that still looks plausible cannot be caught in code.

## Widgets and Live Activity

The `WidgetExtension` target lives in `Widget/`: one Home Screen and Lock Screen widget
(`BatteryWidget`) and the charging live activity (`ChargeLiveActivity`). Swift 6 like the
app, but **without** `SWIFT_DEFAULT_ACTOR_ISOLATION`: WidgetKit's providers are
nonisolated, and the extension has no main-actor state to protect.

**Shared code is listed in the pbxproj, not kept in a folder.** The extension compiles
eight files from `MiniWatts/` — the sensor readers, `PowerSnapshot` and what it depends
on, and the three files in `MiniWatts/Shared/`. They are named in a
`PBXFileSystemSynchronizedBuildFileExceptionSet` on the `MiniWatts` folder with
`target = WidgetExtension`. For a folder that *is* synchronised into a target an exception
set removes files; for one that is not, it adds them — confirmed by the extension's build,
which compiles exactly those eight and nothing else from the app. A new file the widget
needs has to be added there, or ticked under Target Membership in Xcode, which writes the
same entry. Keep shared files free of UI and of the app-only model: the initialiser that
turns a `ChargeSession` into a `WidgetSnapshot.Session` lives in `MiniWatts/Widgets/` for
exactly that reason.

**The extension reads the sensors itself.** `ReadingProbe` runs the app's IOKit and HID code
at every timeline refresh. It keeps a single `HIDSensors` for the life of the process: a
second client in one process reads NaN, and the extension's process can outlive a refresh.
The App Group file the app writes (`WidgetSnapshot`, `group.org.zhaohe.MiniWatts`) is a
fallback plus the last finished charge, and may not exist at all — re-signing tools differ
on whether they carry an App Group entitlement over, and AltStore only grants custom
entitlements to a handful of apps. Everything that reads it treats `nil` as normal.

Not verified on a device when this was written: that `IOHIDEventSystemClient` answers inside
the widget extension's sandbox, and whether the App Group survives Sideloadly, AltStore and
SideStore. A widget that shows the level but never watts means the first did not.

**Refresh is iOS's call.** A timeline asks to be refreshed after 5 minutes when plugged in
and 30 on battery; iOS fits that to a budget of roughly one refresh every 15–60 minutes. The
app calls `WidgetCenter.reloadAllTimelines()` on plugging in, unplugging and a finished
session — requests made by the foreground app do not count against the budget. Every widget
says when its numbers were taken, and whether the extension read them or the app did.

**The live activity is driven by the app alone.** No push updates: those need an APNs server
and a certificate tied to a developer team, and a re-signed copy could never receive them.
So `ChargeActivityController` starts an activity only while the app is in front; sends an
update at most every 5 s and at least every 20 s; gives each update a stale date 45 s out, so
a suspended app's last reading is shown as paused rather than as current; ends the activity
two minutes after unplugging, or at once if the setting is turned off; and adopts an activity
left over from a killed run instead of starting a second one. All of that needs the app to be
running: unplug while it is suspended, or kill it, and the activity stays up — paused — until
the app runs again. The End button on the activity is the way out: `EndChargeActivityIntent`
is a `LiveActivityIntent`, which iOS performs in the app's process, waking it if needed. It
lives in `ChargeActivityAttributes.swift` because the extension needs the type to draw the
button and that file is already compiled into both targets. Checked on a device: ended with
End while still charging, the activity does not come back when the app is next opened, and
that is accepted as it is. Unplug while the app is suspended and the island greys out and the
Lock Screen says paused, for as long as the app stays suspended; the next time it runs, the
island clears at once and the Lock Screen keeps the final state for two more minutes — the
rule for an ended activity with an `.after` dismissal. `Activity` is not `Sendable`, so
tasks are handed the activity's id and look it up — holding the instance across a `Task` does
not compile under Swift 6. `NSSupportsLiveActivities` is set through `INFOPLIST_KEY_*` on the
app target, like every other Info.plist key.

Its compact presentation can show charging power, SoC temperature, battery temperature or
the hottest sensor, selected in Settings. The expanded and Lock Screen presentations show
that reading large with a caption, the other three on one line beneath it, the charge level
bar and the status / "Since …" footnote. **Height is the constraint:** the Lock Screen gives
an activity about 160 pt, and a first version that stacked each reading as icon, label and
value three lines high came to about 195 pt — the system clipped its top and bottom, ate the
padding, and shrank each cell's text by a different factor.

**The widget has its own palette and its own string catalog.** It does not compile
`Theme.swift`: `Color.mw` wraps a trait-resolution closure, and a widget is archived and drawn
by the system, so `WidgetPalette` resolves the same hex values against `colorScheme` itself.
`Widget/Localizable.xcstrings` holds the widget's copy plus the shared files' strings, copied
across from the app's catalog so they do not turn up as new and untranslated.

**Packaging.** An extension is a bundle of its own inside `PlugIns/`, with its own executable,
signature directory and debug map. `build-ipa.sh` strips and de-signs every `.appex` as well
as the app, and `verify-clean.sh` looks for signatures and profiles at any depth. The
extension is also one more App ID for whoever installs it: a free Apple ID gets ten a week,
and AltStore offers to drop extensions to stay under that, which drops the widget with them.

## The floating meter

`Floating/` puts the live reading in a Picture in Picture window, started by hand from
Settings. It exists because neither glance can show a number that moves while the app
is away: a widget shows what it read at its last timeline reload and iOS grants
roughly one reload every 15 to 60 minutes, and a live activity can only be updated by
a running app — push updates need APNs and a team certificate, which a re-signed build
can never have. Every reload WidgetKit does not charge to the budget comes down to the
same thing (app in the foreground, an active audio or navigation session, a tap on the
widget, WidgetKit developer mode in Settings → Developer). PiP is the one surface the
system keeps alive by itself: it wants frames, so the process runs, and the one-second
tick keeps reading sensors.

- **`UIBackgroundModes = audio` is the price** — see *Performance*. Nothing is ever
  played: the session is `.playback` with `.mixWithOthers` and carries no audio, and
  `shouldProhibitBackgroundAudioPlayback` returns false, so whatever the phone was
  playing keeps playing.
- **The layer has to be on screen.** `RootView` keeps `FloatingMeterStage` — the host
  for the `AVSampleBufferDisplayLayer` that PiP draws from — 16 × 9 pt at 2 % opacity
  behind the tab bar for the life of the app. The system opens no window for a layer
  that is not in the hierarchy and closes the window when the source goes away, which
  rules out hosting it in the Settings sheet, the obvious place for a preview. Settings
  shows a plain SwiftUI copy of the frame instead.
- **Frames are rendered, not captured.** `ImageRenderer` draws `FloatingMeterTelemetryFrame`
  at 640 × 360 @1× into a pooled BGRA `CVPixelBuffer`, then a `CMSampleBuffer` tagged
  `DisplayImmediately` — there is no timebase on the layer, each frame is shown when it
  arrives. A failed renderer stays failed until it is flushed and silently swallows
  every frame after, which looks exactly like a frozen reading, so the status is
  checked on the way in. The frame carries a running clock: if the seconds stop, the
  reading behind them stopped too.
- **`controlsStyle = 1`** is undocumented, guarded by a `responds(to:)` check, and the
  reason the window reads as an instrument rather than a paused video: it drops the
  play/pause and skip buttons AVKit otherwise draws over the frame.
- **The controller is built on the first frame, not on the first tap.**
  `isPictureInPicturePossible` is the controller's own answer, so building it inside
  `start()` — which is what the button waits on — is a deadlock: no controller, so the
  window is never reported as available, so the button stays disabled and nothing ever
  builds the controller. The button is now only disabled while a start is in flight,
  a start the system silently ignores (it answers neither the window nor the delegate)
  is reported as `.notReady`, and a `.starting` that is never confirmed times out after
  six seconds.
- **The tick feeds every glance now.** `PowerMonitor.onTick` replaced `RootView`'s
  `onChange(of: monitor.snapshot.date)`: SwiftUI stops updating views once the app is
  off screen, which is exactly when the window is the only thing still showing a
  number. `RootView` also skips `monitor.pause()` while the window is open.

Unverified on a device when this was written: that PiP starts from a host that small,
that `IOHIDEventSystemClient` still answers once the app is in the background, and how
often iOS actually asks for a frame.

## Distribution

Releases ship an **unsigned** ipa. A signed one carries a provisioning profile, and
that profile contains the team ID, every developer certificate and **the UDID of
every registered device** — five of them, in the build checked. Never publish one.

**The app source** (SideStore, AltStore, LiveContainer's bundled SideStore) is
`apps.json`, written by `scripts/make-source.py` from the release's ipa and attached to
the release by CI. Users add
`https://github.com/ResistanceTo/MiniWatts/releases/latest/download/apps.json`, which
GitHub redirects to the newest non-prerelease's copy — so the address never changes, beta
tags never reach it, and no bot commits back to master. Version, build, size and privacy
keys are read from the ipa, never typed: AltStore compares them with what it downloads and
refuses to install on any difference. Entitlements are declared empty because the ipa is
unsigned, and the script refuses a signed ipa rather than describe it wrongly. Never add
`marketplaceID`: SideStore takes it for a notarized AltStore PAL source and rejects the
whole source. Icon and screenshots are served from master (`docs/icon.png`, exported
from `MiniWatts/AppIcon.icon` with Icon Composer's `ictool`).

Two things leak build paths into the binary and need two different fixes:

1. Swift writes absolute source paths through debug info and `#file` metadata →
   `-file-prefix-map $PWD=/MiniWatts` (and `-ffile-prefix-map` for C).
2. The linker records every object file's absolute path in the symbol table as
   `N_OSO` debug-map entries, in `__LINKEDIT` → `xcrun strip -S -x`.

`scripts/verify-clean.sh` checks all of it. Verify with a raw byte scan
(`grep -a "/Users/"`, or `nm -pa … | grep " OSO "`), **not** with `strings` and **not**
with Hopper: the paths live in `__LINKEDIT`, which Hopper's Strings view does not show,
so it reports clean while they are still there.

Also note that Xcode 26+ Debug builds put the app's code in `MiniWatts.debug.dylib`
and leave a Previews launcher stub as the main executable — inspecting the wrong file
makes every symbol look absent.

## Performance

An Instruments trace (Core Animation + Time Profiler, Release, device) says the
probes are not the cost:

- IOKit — 45 HID sensors plus the registry, every second — is **0.6 % of CPU**.
- SwiftUI/UIKit/QuartzCore rendering is ~31 %.
- Core Animation commits run at **66/s** for data that changes once a second, and
  take 7.9 % of wall time. Something is always animating.

`Color.mw` builds a **new** `UIColor` with a trait-resolution closure on every call,
and a dynamic `UIColor` compares by identity, so a `Color` produced by calling it in a
view body was a different value every evaluation. `Color.mwTemperature` did exactly
that, which is why `Backdrop`'s `.animation(_:value: glow)` restarted an 0.8 s
full-screen `plusLighter` animation every second on the Thermal tab for a temperature
that had not moved. Every palette entry is now a `static let`; keep it that way.

`MiniWatts/Info.plist` holds **one key**, `UIBackgroundModes`, and should hold no
more: everything else in the bundle comes from `GENERATE_INFOPLIST_FILE` plus the
`INFOPLIST_KEY_*` settings, which are merged with the file. Put new keys in
`INFOPLIST_KEY_*`. `UIBackgroundModes` is there because it has no build setting —
Xcode's own spec defines none — and Picture in Picture will not start without it.
The file had been deleted once before, when its only key was
`CADisableMinimumFrameDurationOnPhone` (120 Hz for data that changes once a second),
and Xcode dropped the `INFOPLIST_FILE` setting along with it. Note that the app
folder is synchronised into the target, so the file also needs a membership exception
or it is copied into the bundle as a resource as well — the same exception Xcode
writes for the widget's own `Info.plist`.

`PageScaffold` uses a `LazyVStack`. History puts up to sixty session panels through it.

Already removed: `contentTransition(.numericText())` on every readout (it is opt-in
via `mwReadout(rolling:)` now, used only by the dial), and the heat map's 0.6 s
animation, which was retriggered every second on a `blur` + `plusLighter` layer.
The grid `Canvas` is `.drawingGroup()`-rasterised.

Deliberately kept despite the cost, as design decisions: the `Backdrop`'s full-screen
`plusLighter` glow, and `PowerRing`'s `.shadow` on a stroked arc (a non-rectangular
shadow is an offscreen pass per frame).

## Conventions

- English source copy. Sensor names stay raw (`Charger VQ0u`), with a human label
  above them when `SensorCatalog` recognises one.
- Follow the system appearance — every colour is defined for both schemes in
  `Theme.swift`. No `colorScheme` checks in view bodies.
- A missing reading renders as a muted dash or the words "no reading", never as 0.
- Nothing is claimed that the sandbox did not actually return. Panels say where their
  numbers come from and mark inferred values as inferred — charging holds are inferred
  from behaviour, and labelled that way.
- User-facing copy stays in the app's voice; selector-level detail belongs in Raw data.
