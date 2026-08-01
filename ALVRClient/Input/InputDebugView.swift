//
//  InputDebugView.swift
//
//  Offline exercise harness for the input stack.
//
//  There is no streaming desktop in the loop here: this opens the CoreBluetooth
//  driver, runs real snapshots through a real InteractionProfile, and lands them
//  in a DebugInputSink instead of the ALVR FFI. That makes the whole path —
//  driver, profile table, router — testable on device with nothing else running.
//
//  It deliberately shows *both* halves. The mapped column is what a server would
//  receive; the raw column is what the device actually reported. Without the
//  latter, everything the active profile drops on the floor (paddles, QAM, both
//  touchpads, grip capsense) would be invisible, and there would be no way to
//  tell "the driver never saw it" apart from "the profile doesn't bind it".
//

import SwiftUI
import Foundation
import QuartzCore
import simd

// MARK: - Path names

/// Reverse lookup for ALVR path IDs.
///
/// `alvr_path_string_to_id` is a one-way hash, so the only way back to a name is
/// to hash the names we might see and keep the table. Rather than duplicating
/// WorldTracker's ~60 constants (which would then drift), this enumerates the
/// cross product of the OpenXR-ish vocabulary those constants are drawn from, so
/// paths added to a profile later resolve without touching this file.
enum AlvrPathNames {
    private static let hands = ["left", "right"]

    private static let components = [
        "a", "b", "x", "y",
        "trigger", "squeeze", "thumbstick", "trackpad", "joystick",
        "system", "menu", "view", "back", "guide", "start", "bumper",
        "dpad_up", "dpad_down", "dpad_left", "dpad_right",
        "paddle1", "paddle2", "thumbrest", "grip",
    ]

    private static let suffixes = [
        "click", "touch", "value", "force", "x", "y", "sensor/value",
    ]

    private static let table: [UInt64: String] = {
        var t: [UInt64: String] = [:]
        for hand in hands {
            for component in components {
                for suffix in suffixes {
                    let path = "/user/hand/\(hand)/input/\(component)/\(suffix)"
                    t[alvr_path_string_to_id(path)] = "\(hand)/\(component)/\(suffix)"
                }
            }
        }
        return t
    }()

    /// Short display name, or the raw ID when the path isn't in the vocabulary
    /// above — which is itself useful signal that a profile invented a path.
    static func name(for id: UInt64) -> String {
        table[id] ?? String(format: "0x%016llx", id)
    }
}

// MARK: - Session

/// Drives the input stack with no server attached.
///
/// Routing runs on its own queue rather than in the view: the point is to
/// exercise the same call shape `sendGamepadInputs()` will use, at a plausible
/// frame rate, independent of how often SwiftUI decides to redraw.
final class InputDebugSession {
    static let shared = InputDebugSession()

    /// How often bindings are evaluated. Above the controller's ~68Hz report
    /// rate on purpose, so routing never becomes the thing limiting freshness.
    private static let routeHz: Double = 90

    struct Stats {
        var displayName: String?
        var isConnected = false
        var battery: Float?
        /// Distinct device reports per second, i.e. actual BLE throughput.
        var reportHz: Double = 0
        var snapshot: InputSnapshot?
    }

    let sink = DebugInputSink.shared

    private let queue = DispatchQueue(label: "com.alvr.client.inputdebug")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var stats = Stats()
    /// Read by the view on the main thread, written by the picker, used by the
    /// routing queue — so it lives under the same lock as `stats`.
    private var activeProfile = InteractionProfile.steamControllerQuestEmulation()

    var profile: InteractionProfile {
        lock.lock(); defer { lock.unlock() }
        return activeProfile
    }

    // Report-rate accounting. Snapshots are pulled, not pushed, so new reports
    // are identified by their host timestamp changing rather than by a callback.
    private var lastReportStamp: TimeInterval = 0
    private var reportsThisWindow = 0
    private var windowStart: TimeInterval = 0

    // MARK: Lifecycle
    //
    // Main-thread only. Driven by the debug window's onAppear/onDisappear; the
    // test space renders the client's own Metal view and carries no panel, so
    // there is only ever one of these.

    private var isAttached = false

    /// The debug window appeared.
    func attach() {
        guard !isAttached else { return }
        isAttached = true
        start()
    }

    /// The debug window went away.
    func detach() {
        guard isAttached else { return }
        isAttached = false
        stop()
    }

    private func start() {
        guard timer == nil else { return }
        SteamControllerManager.shared.start()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Self.routeHz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// Stops routing and hands the controller back to the system.
    ///
    /// Stopping the manager is what returns the Steam Controller to lizard
    /// mode: while this session is running the pads are ours, and if we simply
    /// went quiet without stopping the keepalive the controller would keep
    /// being driven by a harness nobody is looking at.
    private func stop() {
        timer?.cancel()
        timer = nil
        SteamControllerManager.shared.stop()
        sink.reset()
        lock.lock()
        stats = Stats()
        lock.unlock()
        wasSuspendedWhileRunning = false
    }

    /// Whether `suspend()` should be undone by a later `resume()`.
    /// Main-thread only, like the rest of the lifecycle below.
    private var wasSuspendedWhileRunning = false

    /// Backgrounding / headset-off counterpart, mirroring how the audio session
    /// is torn down in `EventHandler.handleHeadsetRemoved()`.
    ///
    /// The controller must not be left out of lizard mode while the app isn't
    /// in front of the user — that is exactly the state where the pads silently
    /// drive the desktop instead of anything of ours.
    ///
    /// EventHandler calls this from its event thread, so the whole start/stop
    /// lifecycle is funnelled onto the main queue rather than being separately
    /// locked.
    func suspend() {
        DispatchQueue.main.async { [self] in
            let running = timer != nil
            stop()
            wasSuspendedWhileRunning = running
        }
    }

    /// Headset-donned counterpart of `suspend()`, mirroring
    /// `EventHandler.handleHeadsetEntered()`. No-op unless we were actually
    /// running when suspended.
    func resume() {
        DispatchQueue.main.async { [self] in
            guard wasSuspendedWhileRunning else { return }
            wasSuspendedWhileRunning = false
            // The window may have closed while we were suspended.
            if isAttached { start() }
        }
    }

    func setProfile(_ p: InteractionProfile) {
        lock.lock()
        activeProfile = p
        lock.unlock()
        // Values from the old table would otherwise linger forever, since
        // nothing overwrites a path the new profile doesn't bind.
        sink.reset()
    }

    func currentStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard let device = SteamControllerManager.shared.connectedDevices.first else {
            // Drop the rate accounting too, or the window spanning a
            // disconnect reports a nonsense Hz once the device comes back.
            reportsThisWindow = 0
            windowStart = 0
            lock.lock(); stats = Stats(); lock.unlock()
            return
        }

        var s = Stats()
        s.displayName = device.identity.displayName
        s.isConnected = device.isConnected

        if let snap = device.snapshot() {
            if snap.hostTimestamp != lastReportStamp {
                lastReportStamp = snap.hostTimestamp
                reportsThisWindow += 1
            }
            s.battery = snap.battery
            s.snapshot = snap
            InputRouter.route(snapshot: snap, profile: profile, to: sink)
        }

        if windowStart == 0 { windowStart = now }
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            lock.lock()
            stats.reportHz = Double(reportsThisWindow) / elapsed
            lock.unlock()
            reportsThisWindow = 0
            windowStart = now
        }

        lock.lock()
        s.reportHz = stats.reportHz
        stats = s
        lock.unlock()
    }
}

// MARK: - View

struct InputDebugView: View {
    private enum ProfileChoice: String, CaseIterable, Identifiable {
        case quest = "Quest emulation"
        case roy = "Roy (provisional)"

        var id: String { rawValue }

        var profile: InteractionProfile {
            switch self {
            case .quest: return .steamControllerQuestEmulation()
            case .roy:   return .steamControllerRoyEmulation()
            }
        }
    }

    private let session = InputDebugSession.shared
    @State private var choice: ProfileChoice = .quest
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        // Pull-based at a fixed rate: reports land on the Bluetooth queue at
        // ~68Hz and driving SwiftUI observation from there would be both
        // incorrect and far faster than anyone can read.
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
            let stats = session.currentStats()
            let values = session.sink.snapshotOfValues()

            VStack(alignment: .leading, spacing: 12) {
                header(stats)
                // Brings up the client's Metal renderer with no streamer
                // connected, which is the state that draws the room wireframe.
                // This window stays open in front of it — the space is .mixed
                // precisely so it does.
                Button {
                    Task { await openImmersiveSpace(id: "InputDebugSpace") }
                } label: {
                    Label("Enter Test Space", systemImage: "visionpro")
                }
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    rawColumn(stats.snapshot)
                    Divider()
                    mappedColumn(values)
                }
            }
            .padding()
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear { session.attach() }
        .onDisappear { session.detach() }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ stats: InputDebugSession.Stats) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(stats.isConnected ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
            Text(stats.displayName ?? "Searching for a Steam Controller…")
                .font(.system(size: 18, weight: .bold))
            if stats.isConnected {
                Text(String(format: "%.1f Hz", stats.reportHz))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let battery = stats.battery {
                    Text(String(format: "%.0f%% battery", battery * 100))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Profile", selection: $choice) {
                ForEach(ProfileChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .onChange(of: choice) { _, new in session.setProfile(new.profile) }
        }
    }

    // MARK: Raw device state

    @ViewBuilder
    private func rawColumn(_ snapshot: InputSnapshot?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Device reports")
                    .font(.system(size: 15, weight: .bold))

                let snap = snapshot
                buttonGrid(snap?.buttons ?? ButtonSet())

                Text("Axes").font(.system(size: 13, weight: .semibold))
                let axes = snap?.axes ?? AnalogAxes()
                axisRow("L stick X", axes.leftStick.x, bipolar: true)
                axisRow("L stick Y", axes.leftStick.y, bipolar: true)
                axisRow("R stick X", axes.rightStick.x, bipolar: true)
                axisRow("R stick Y", axes.rightStick.y, bipolar: true)
                axisRow("L trigger", axes.leftTrigger, bipolar: false)
                axisRow("R trigger", axes.rightTrigger, bipolar: false)

                Text("Touchpads").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 24) {
                    touchpad("Left", snap?.leftTouchpad)
                    touchpad("Right", snap?.rightTouchpad)
                }

                Text("Motion").font(.system(size: 13, weight: .semibold))
                motion(snap?.motion)

                Text("Fused pose").font(.system(size: 13, weight: .semibold))
                fusedPose()

                Text("Component probe").font(.system(size: 13, weight: .semibold))
                componentProbe()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The solved 6DoF pose, read straight off WorldTracker.
    ///
    /// Numbers rather than only the wireframe in the test space, because the two
    /// answer different questions: the wireframe shows whether the pose sits on
    /// the real object, this shows *why* — which hands are believed, and whether
    /// yaw is being measured or dead-reckoned.
    @ViewBuilder
    private func fusedPose() -> some View {
        let pose = WorldTracker.shared.currentSteamControllerPose()
        if let pose {
            let held = pose.heldLeft && pose.heldRight ? "both grips"
                     : pose.heldLeft ? "left grip only"
                     : pose.heldRight ? "right grip only"
                     : "no grip — dead reckoning"
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pose.heldLeft && pose.heldRight ? Color.green
                              : (pose.heldLeft || pose.heldRight) ? Color.orange : Color.red)
                        .frame(width: 10, height: 10)
                    Text(held).font(.system(size: 12, weight: .semibold))
                    Text(String(format: "confidence %.2f", pose.confidence))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(String(format: "pos  % .3f  % .3f  % .3f", pose.position.x, pose.position.y, pose.position.z))
                    .font(.system(size: 12, design: .monospaced))
                Text(String(format: "quat % .3f  % .3f  % .3f  % .3f",
                            pose.orientation.vector.x, pose.orientation.vector.y,
                            pose.orientation.vector.z, pose.orientation.vector.w))
                    .font(.system(size: 12, design: .monospaced))
                Text(String(format: "vel  % .2f  % .2f  % .2f m/s",
                            pose.linearVelocity.x, pose.linearVelocity.y, pose.linearVelocity.z))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("no pose — needs a tracked hand on a grip")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// Stick and pad positions, measured off the thumb.
    ///
    /// Values are in model space in **millimetres**, with `mountCorrection`
    /// excluded so they are a measurement of the device rather than a readback
    /// of a tuned constant. Intended to be transcribed into `IbexModel` once the
    /// spread settles — which is why spread is shown as prominently as the mean.
    @ViewBuilder
    private func componentProbe() -> some View {
        let probe = WorldTracker.shared.steamControllerProbe
        VStack(alignment: .leading, spacing: 4) {
            Text("touch each control with both hands on the grips")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("mm · Δ = measured − CAD · ± is spread")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            ForEach(ComponentProbe.Site.allCases) { site in
                if let e = probe.estimate(site) {
                    // Residual against the CAD where there is one. The absolute
                    // position carries the grip-anchor error as an additive
                    // constant and so cannot check the anchors; the residual is
                    // that error, directly.
                    let d = site.expected.map { e.mean - $0 }
                    let lead = d.map { String(format: "Δ % 5.1f % 5.1f % 5.1f", $0.x * 1000, $0.y * 1000, $0.z * 1000) }
                             ?? String(format: "  % 5.1f % 5.1f % 5.1f", e.mean.x * 1000, e.mean.y * 1000, e.mean.z * 1000)
                    Text(String(format: "%-15@ %@  ±%.1f %.1f %.1f  n=%d",
                                site.displayName as NSString, lead as NSString,
                                e.spread.x * 1000, e.spread.y * 1000, e.spread.z * 1000,
                                e.count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(site.expected == nil ? .secondary : .primary)
                } else {
                    Text(String(format: "%-15@ —", site.displayName as NSString))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            // Independent of any placement error: shifting the whole body moves
            // both stick estimates equally, so this checks scale rather than
            // position. CAD says 46.0mm.
            if let sep = probe.stickSeparation() {
                Text(String(format: "stick separation %.1f mm  (CAD %.1f)",
                            sep * 1000,
                            simd_distance(IbexModel.leftStickCentre, IbexModel.rightStickCentre) * 1000))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("all four Δ agreeing = grip anchor off by that much")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("index rows have no CAD reference (trigger moves) — raw mm")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            // Which guard is eating samples. "Measures nothing" looks identical
            // from the outside across six of them.
            let d = probe.diagnostics()
            Text(String(format: "calls %d  ok %d  · rejected: conf %d  grip %d  touch %d  track %d  joint %d  bounds %d",
                        d.calls, d.accepted,
                        d.gatedByConfidence, d.gatedByGrip, d.gatedByTouch,
                        d.gatedByTracking, d.gatedByJoint, d.gatedByBounds))
                .font(.system(size: 10, design: .monospaced))
            Button("Reset probe") { probe.reset() }
                .font(.system(size: 11))
                .padding(.top, 2)
        }
    }

    /// Every button the device can report, always all 30, so an input that never
    /// arrives is as visible as one that does. Buttons the active profile has no
    /// binding for are tinted differently — otherwise a dead paddle and an
    /// unbound paddle look identical.
    @ViewBuilder
    private func buttonGrid(_ held: ButtonSet) -> some View {
        let mapped = Self.boundButtons(in: session.profile)
        let columns = Array(repeating: GridItem(.flexible(minimum: 70), spacing: 6), count: 5)
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(ButtonSet.allNames, id: \.1) { bit, name in
                let isHeld = held.contains(bit)
                let isMapped = mapped.contains(bit)
                Text(name)
                    .font(.system(size: 11, weight: isHeld ? .bold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(isHeld ? (isMapped ? Color.green : Color.orange) : Color.gray.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder
    private func axisRow(_ label: String, _ value: Float, bipolar: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 80, alignment: .leading)
            bar(value, bipolar: bipolar)
            Text(String(format: "%+.3f", value))
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }

    /// Bipolar axes fill outward from the centre so a stick at rest reads as
    /// "nothing" rather than "half".
    @ViewBuilder
    private func bar(_ value: Float, bipolar: Bool) -> some View {
        let width: CGFloat = 180
        let clamped = CGFloat(max(-1, min(1, value)))
        ZStack(alignment: bipolar ? .center : .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.25))
                .frame(width: width, height: 10)
            if bipolar {
                // The fill is centred by the ZStack, so shifting it by half its
                // own length pins one end to the middle of the track.
                let fill = abs(clamped) * width / 2
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: fill, height: 10)
                    .offset(x: clamped < 0 ? -fill / 2 : fill / 2)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: max(0, clamped) * width, height: 10)
            }
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func touchpad(_ label: String, _ pad: TouchpadSample?) -> some View {
        let size: CGFloat = 90
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size, height: size)
                if let pad, pad.isTouched {
                    // TouchpadSample's origin is bottom-left; SwiftUI's is
                    // top-left, hence the Y flip.
                    Circle()
                        .fill(pad.isClicked ? Color.orange : Color.accentColor)
                        .frame(width: 12, height: 12)
                        .offset(x: CGFloat(pad.position.x) * size - 6,
                                y: (1 - CGFloat(pad.position.y)) * size - 6)
                }
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 11))
            Text(String(format: "p %.2f", pad?.pressure ?? 0))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Accel magnitude is shown because it is the standing sanity check on the
    /// device-to-OpenXR rotation: at rest it must read ~9.81.
    @ViewBuilder
    private func motion(_ motion: MotionSample?) -> some View {
        let m = motion ?? MotionSample()
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "gyro   %+7.3f %+7.3f %+7.3f rad/s", m.gyro.x, m.gyro.y, m.gyro.z))
            Text(String(format: "accel  %+7.3f %+7.3f %+7.3f m/s²", m.accel.x, m.accel.y, m.accel.z))
            Text(String(format: "|accel| %.3f  (expect ~9.81 at rest)", simd_length(m.accel)))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }

    // MARK: Routed output

    /// The profile's binding table, in declaration order, with whatever the sink
    /// last received for each target. This is exactly what a server would see.
    @ViewBuilder
    private func mappedColumn(_ values: [UInt64: DebugInputSink.Value]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.profile.name)
                    .font(.system(size: 15, weight: .bold))
                Text("\(session.profile.bindings.count) bindings")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach(Array(session.profile.bindings.enumerated()), id: \.offset) { _, binding in
                    HStack(spacing: 8) {
                        Text(AlvrPathNames.name(for: binding.target))
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(width: 200, alignment: .leading)
                        switch values[binding.target] {
                        case .bool(let b):
                            Text(b ? "true" : "false")
                                .font(.system(size: 11, weight: b ? .bold : .regular))
                                .foregroundStyle(b ? Color.green : Color.secondary)
                                .frame(width: 60, alignment: .leading)
                        case .scalar(let v):
                            Text(String(format: "%+.3f", v))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(abs(v) > 0.001 ? Color.primary : Color.secondary)
                                .frame(width: 60, alignment: .leading)
                        case nil:
                            Text("—")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(width: 60, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Buttons the profile reads at all, in any binding.
    static func boundButtons(in profile: InteractionProfile) -> ButtonSet {
        var set = ButtonSet()
        for binding in profile.bindings {
            switch binding.source {
            case .buttons(let s):              set.formUnion(s)
            case .scalarOrButtons(_, let s):   set.formUnion(s)
            case .scalar:                      break
            }
        }
        return set
    }
}
