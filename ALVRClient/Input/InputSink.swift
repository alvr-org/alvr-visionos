//
//  InputSink.swift
//
//  Where routed input actually goes.
//
//  Putting the alvr_* calls behind a protocol means input can be exercised
//  with no server attached: an offline ImmersiveSpace can install a
//  DebugInputSink, see every button and axis, and never touch the FFI. It also
//  gives the button-value union exactly one home, instead of the two identical
//  nested copies currently in WorldTracker.
//

import Foundation

protocol InputSink: AnyObject {
    func send(pathId: UInt64, bool: Bool)
    func send(pathId: UInt64, scalar: Float)
    /// Announce an OpenXR interaction profile for a device. No-op for sinks
    /// that aren't talking to a server.
    func announceProfile(deviceId: UInt64, profilePathId: UInt64)
    /// Offered the raw pre-mapping snapshot. Sinks that only forward bindings
    /// ignore this; it exists so inputs with no binding at all (paddles, QAM,
    /// touchpads) are still observable downstream.
    func record(snapshot: InputSnapshot)
}

extension InputSink {
    func announceProfile(deviceId: UInt64, profilePathId: UInt64) {}
    func record(snapshot: InputSnapshot) {}
}

// MARK: - Real ALVR sink

/// Forwards to the ALVR client core over the C FFI.
final class ALVRInputSink: InputSink {
    static let shared = ALVRInputSink()

    /// The two conversions that currently exist as duplicated nested functions
    /// inside `sendGamepadInputs()` and `sendTracking()`.
    static func boolVal(_ val: Bool) -> AlvrButtonValue {
        AlvrButtonValue(
            tag: ALVR_BUTTON_VALUE_BINARY,
            AlvrButtonValue.__Unnamed_union___Anonymous_field1(
                AlvrButtonValue.__Unnamed_union___Anonymous_field1.__Unnamed_struct___Anonymous_field0(binary: val)))
    }

    static func scalarVal(_ val: Float) -> AlvrButtonValue {
        AlvrButtonValue(
            tag: ALVR_BUTTON_VALUE_SCALAR,
            AlvrButtonValue.__Unnamed_union___Anonymous_field1(
                AlvrButtonValue.__Unnamed_union___Anonymous_field1.__Unnamed_struct___Anonymous_field1(scalar: val)))
    }

    func send(pathId: UInt64, bool: Bool) {
        alvr_send_button(pathId, Self.boolVal(bool))
    }

    func send(pathId: UInt64, scalar: Float) {
        alvr_send_button(pathId, Self.scalarVal(scalar))
    }

    func announceProfile(deviceId: UInt64, profilePathId: UInt64) {
        alvr_send_active_interaction_profile(deviceId, profilePathId)
    }
}

// MARK: - Debug sink

/// Records everything routed through it, for display without a server.
///
/// Deliberately lock-protected and pull-based rather than `@Observable`:
/// values arrive on the CoreBluetooth queue at ~250Hz, and driving SwiftUI
/// observation from a background thread at that rate is both incorrect and
/// pointless. UI should poll `snapshotOfValues()` from a TimelineView.
final class DebugInputSink: InputSink {
    static let shared = DebugInputSink()

    enum Value: Equatable {
        case bool(Bool)
        case scalar(Float)
    }

    private let lock = NSLock()
    private var values: [UInt64: Value] = [:]
    private var lastDeviceSnapshot: InputSnapshot?

    func send(pathId: UInt64, bool: Bool) {
        lock.lock(); values[pathId] = .bool(bool); lock.unlock()
    }

    func send(pathId: UInt64, scalar: Float) {
        lock.lock(); values[pathId] = .scalar(scalar); lock.unlock()
    }

    /// Retains the raw pre-mapping snapshot too, so unmapped inputs (paddles,
    /// QAM, touchpads) remain observable even though no binding emits them.
    func record(snapshot: InputSnapshot) {
        lock.lock(); lastDeviceSnapshot = snapshot; lock.unlock()
    }

    func snapshotOfValues() -> [UInt64: Value] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func latestDeviceSnapshot() -> InputSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return lastDeviceSnapshot
    }

    func reset() {
        lock.lock(); values.removeAll(); lastDeviceSnapshot = nil; lock.unlock()
    }
}

// MARK: - Fan-out

/// Sends to several sinks at once, e.g. the real FFI plus a debug overlay
/// while streaming.
final class TeeInputSink: InputSink {
    private let sinks: [InputSink]

    init(_ sinks: [InputSink]) { self.sinks = sinks }

    func send(pathId: UInt64, bool: Bool) {
        for s in sinks { s.send(pathId: pathId, bool: bool) }
    }

    func send(pathId: UInt64, scalar: Float) {
        for s in sinks { s.send(pathId: pathId, scalar: scalar) }
    }

    func announceProfile(deviceId: UInt64, profilePathId: UInt64) {
        for s in sinks { s.announceProfile(deviceId: deviceId, profilePathId: profilePathId) }
    }

    func record(snapshot: InputSnapshot) {
        for s in sinks { s.record(snapshot: snapshot) }
    }
}
