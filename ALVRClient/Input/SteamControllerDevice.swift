//
//  SteamControllerDevice.swift
//
//  Steam Controller (2026, "Triton") support over CoreBluetooth.
//
//  Why this isn't a GCController: the controller exposes a *vendor-specific*
//  GATT service rather than HID-over-GATT (0x1812). visionOS reserves HOGP
//  devices for the system, so an app can never see them as raw HID — but a
//  custom service is fair game for CoreBluetooth. That's what makes this
//  possible at all, and it's also why the device cannot be represented by the
//  existing GameController-shaped code paths.
//
//  Protocol details were derived from SDL3 (../SDL):
//    - src/joystick/hidapi/SDL_hidapi_steam_triton.c  (button bits, scaling)
//    - src/joystick/hidapi/steam/controller_structs.h (packed report layout)
//    - src/hidapi/ios/hid.m                           (GATT UUIDs, BLE framing)
//

import Foundation
import CoreBluetooth
import QuartzCore
import simd
import os

private let log = Logger(subsystem: "com.alvr.client", category: "SteamController")

// MARK: - Protocol constants

private enum Valve {
    static let service    = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")
    static let inputD0G   = CBUUID(string: "100F6C33-1735-4313-B402-38567131E5F3")
    static let report     = CBUUID(string: "100F6C34-1735-4313-B402-38567131E5F3")
    static let inputTriton45 = CBUUID(string: "100F6C7A-1735-4313-B402-38567131E5F3")
    static let inputTriton47 = CBUUID(string: "100F6C7C-1735-4313-B402-38567131E5F3")
    /// Device Information — used only to find already-connected peripherals,
    /// because the Valve service is not advertised.
    static let deviceInfo = CBUUID(string: "180A")

    /// Battery arrives over the *standard* GATT Battery Service, which is far
    /// simpler than parsing the vendor battery report (0x43 on 100F6C78).
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevel   = CBUUID(string: "2A19")

    /// The controller reverts to lizard mode unless the setting is refreshed.
    /// SDL re-sends every 3000ms; matching that.
    static let lizardRefreshInterval: TimeInterval = 3.0

    /// Feature-report message type. Note this shares a number with output
    /// report 0x87 but is a *different namespace*: output reports are
    /// ValveTritonOutReportMessageIDs (0x80...0x85, all haptics), while this is
    /// a FeatureReportMsg type. Settings must go via the feature report
    /// characteristic; there is no output report for them.
    static let idSetSettingsValues: UInt8 = 0x87
    static let idOutReportHapticRumble: UInt8 = 0x80
    static let settingLizardMode:   UInt8 = 9
    static let lizardModeOff:       UInt16 = 0
    static let featureReportBytes = 64

    /// Output reports live on their own characteristics named
    /// `100F6C<id + 0x35>`, e.g. report 0x87 is `100F6CBC`. Confirmed against
    /// hardware: the controller advertises 100F6CB5...BE, i.e. reports
    /// 0x80...0x89.
    static let outputCharacteristicOffset: UInt8 = 0x35

    static func outputReportId(for uuid: CBUUID) -> UInt8? {
        let s = uuid.uuidString.uppercased()
        guard s.hasPrefix("100F6C"), s.count >= 8,
              let byte = UInt8(s.dropFirst(6).prefix(2), radix: 16),
              byte > outputCharacteristicOffset else { return nil }
        let id = byte - outputCharacteristicOffset
        // Only reports >= 0x80 are host->device; below that they're inputs.
        return id >= 0x80 ? id : nil
    }
}

/// Button bits in the Triton report's 32-bit `buttons` field.
private enum TritonButton {
    static let a: UInt32              = 0x00000001
    static let b: UInt32              = 0x00000002
    static let x: UInt32              = 0x00000004
    static let y: UInt32              = 0x00000008
    static let qam: UInt32            = 0x00000010
    static let r3: UInt32             = 0x00000020
    static let view: UInt32           = 0x00000040
    static let r4: UInt32             = 0x00000080
    static let r5: UInt32             = 0x00000100
    static let r: UInt32              = 0x00000200
    static let dpadDown: UInt32       = 0x00000400
    static let dpadRight: UInt32      = 0x00000800
    static let dpadLeft: UInt32       = 0x00001000
    static let dpadUp: UInt32         = 0x00002000
    static let menu: UInt32           = 0x00004000
    static let l3: UInt32             = 0x00008000
    static let steam: UInt32          = 0x00010000
    static let l4: UInt32             = 0x00020000
    static let l5: UInt32             = 0x00040000
    static let l: UInt32              = 0x00080000
    static let rightStickTouch: UInt32 = 0x00100000
    static let rightPadTouch: UInt32  = 0x00200000
    static let rightPadClick: UInt32  = 0x00400000
    static let rightTriggerClick: UInt32 = 0x00800000
    static let leftStickTouch: UInt32 = 0x01000000
    static let leftPadTouch: UInt32   = 0x02000000
    static let leftPadClick: UInt32   = 0x04000000
    static let leftTriggerClick: UInt32 = 0x08000000
    static let rightGripTouch: UInt32 = 0x10000000
    static let leftGripTouch: UInt32  = 0x20000000
}

// MARK: - Report parsing

/// Little-endian field reads at explicit offsets. The wire structs are
/// `#pragma pack(1)`, so there is no padding to account for.
private extension Data {
    func u8 (_ o: Int) -> UInt8  { self[startIndex + o] }
    func u16(_ o: Int) -> UInt16 { UInt16(u8(o)) | (UInt16(u8(o + 1)) << 8) }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | (UInt32(u16(o + 2)) << 16) }
    func i16(_ o: Int) -> Int16  { Int16(bitPattern: u16(o)) }
}

struct TritonReport {
    var buttons: UInt32 = 0
    var trigL: Int16 = 0, trigR: Int16 = 0
    var lsX: Int16 = 0, lsY: Int16 = 0
    var rsX: Int16 = 0, rsY: Int16 = 0
    var lPadX: Int16 = 0, lPadY: Int16 = 0, lPressure: UInt16 = 0
    var rPadX: Int16 = 0, rPadY: Int16 = 0, rPressure: UInt16 = 0
    var imuTimestamp: UInt32 = 0
    var accel = SIMD3<Int16>(0, 0, 0)
    var gyro  = SIMD3<Int16>(0, 0, 0)

    /// Expected payload size for both known Triton report variants.
    static let expectedLength = 45

    /// Parses a raw notification payload. Note the BLE payload carries **no**
    /// leading report-ID byte — the ID is implied by which characteristic
    /// delivered it (see hid.m, which stores it separately and only prepends it
    /// when emulating `hid_read`).
    init?(_ d: Data, reportId: UInt8) {
        guard d.count >= TritonReport.expectedLength else { return nil }
        buttons = d.u32(1)
        trigL = d.i16(5);  trigR = d.i16(7)
        lsX   = d.i16(9);  lsY   = d.i16(11)
        rsX   = d.i16(13); rsY   = d.i16(15)

        if reportId == 0x47 {
            // TritonMTUNoQuat32TS_t: adds a 16-bit trackpad timestamp and
            // narrows the IMU timestamp to 16 bits.
            lPadX = d.i16(19); lPadY = d.i16(21); lPressure = d.u16(23)
            rPadX = d.i16(25); rPadY = d.i16(27); rPressure = d.u16(29)
            imuTimestamp = UInt32(d.u16(31))
            accel = SIMD3(d.i16(33), d.i16(35), d.i16(37))
            gyro  = SIMD3(d.i16(39), d.i16(41), d.i16(43))
        } else {
            // TritonMTUNoQuat_t: no trackpad timestamp, 32-bit IMU timestamp.
            lPadX = d.i16(17); lPadY = d.i16(19); lPressure = d.u16(21)
            rPadX = d.i16(23); rPadY = d.i16(25); rPressure = d.u16(27)
            imuTimestamp = d.u32(29)
            accel = SIMD3(d.i16(33), d.i16(35), d.i16(37))
            gyro  = SIMD3(d.i16(39), d.i16(41), d.i16(43))
        }
    }
}

// MARK: - Snapshot conversion

private extension TritonReport {
    /// Full-scale ranges, from the SDL driver's sensor conversion.
    static let gyroDegPerSecFullScale: Float = 2000
    static let accelGFullScale: Float = 2

    func toButtonSet() -> ButtonSet {
        var s = ButtonSet()
        func map(_ bit: UInt32, _ member: ButtonSet) {
            if buttons & bit != 0 { s.insert(member) }
        }
        map(TritonButton.a, .a)
        map(TritonButton.b, .b)
        map(TritonButton.x, .x)
        map(TritonButton.y, .y)
        map(TritonButton.steam, .system)
        map(TritonButton.menu, .menu)
        map(TritonButton.view, .view)
        map(TritonButton.qam, .quickAccess)
        map(TritonButton.l, .leftShoulder)
        map(TritonButton.r, .rightShoulder)
        map(TritonButton.l3, .leftStickClick)
        map(TritonButton.r3, .rightStickClick)
        map(TritonButton.dpadUp, .dpadUp)
        map(TritonButton.dpadDown, .dpadDown)
        map(TritonButton.dpadLeft, .dpadLeft)
        map(TritonButton.dpadRight, .dpadRight)
        map(TritonButton.l4, .leftPaddle1)
        map(TritonButton.l5, .leftPaddle2)
        map(TritonButton.r4, .rightPaddle1)
        map(TritonButton.r5, .rightPaddle2)
        map(TritonButton.leftTriggerClick, .leftTriggerClick)
        map(TritonButton.rightTriggerClick, .rightTriggerClick)
        map(TritonButton.leftPadTouch, .leftPadTouch)
        map(TritonButton.rightPadTouch, .rightPadTouch)
        map(TritonButton.leftPadClick, .leftPadClick)
        map(TritonButton.rightPadClick, .rightPadClick)
        map(TritonButton.leftStickTouch, .leftStickTouch)
        map(TritonButton.rightStickTouch, .rightStickTouch)
        map(TritonButton.leftGripTouch, .leftGripTouch)
        map(TritonButton.rightGripTouch, .rightGripTouch)
        return s
    }

    func toAxes() -> AnalogAxes {
        var a = AnalogAxes()
        // Sticks are int16 with +Y already meaning "up" — SDL negates Y only
        // because SDL's own axis convention is +Y down. We want +Y up.
        a.leftStick  = SIMD2(Float(lsX) / 32767, Float(lsY) / 32767)
        a.rightStick = SIMD2(Float(rsX) / 32767, Float(rsY) / 32767)
        // Triggers arrive as 0...32767 (SDL rescales via `raw * 2 - 32768`).
        a.leftTrigger  = max(0, Float(trigL) / 32767)
        a.rightTrigger = max(0, Float(trigR) / 32767)
        return a
    }

    func touchpad(left: Bool) -> TouchpadSample {
        var t = TouchpadSample()
        let x = left ? lPadX : rPadX
        let y = left ? lPadY : rPadY
        let p = left ? lPressure : rPressure
        // Raw pad Y is +up; our TouchpadSample origin is bottom-left, so unlike
        // SDL (which flips for a top-left origin) we use it directly.
        t.position = SIMD2(Float(x) / 65536 + 0.5, Float(y) / 65536 + 0.5)
        t.pressure = Float(p) / 32768
        t.isTouched = buttons & (left ? TritonButton.leftPadTouch : TritonButton.rightPadTouch) != 0
        t.isClicked = buttons & (left ? TritonButton.leftPadClick : TritonButton.rightPadClick) != 0
        return t
    }

    /// Rotates a raw IMU vector from the sensor's frame into the ARKit/OpenXR
    /// convention (+X right, +Y up, +Z toward the user).
    ///
    /// Measured against hardware rather than inferred: rotating about raw X
    /// produces pitch, raw Y roll, and raw Z yaw. That makes raw X the lateral
    /// axis, raw Y forward, and raw Z up — corroborated by the resting
    /// accelerometer, which reports gravity along +Z when the controller lies
    /// on its back.
    ///
    /// Since OpenXR pitches about X, yaws about Y and rolls about Z, Y and Z
    /// swap. The negation is not cosmetic: a bare swap mirrors the basis
    /// (determinant -1) and would invert every rotation. This lands on the same
    /// (X, Z, -Y) permutation SDL uses.
    static func deviceToOpenXR(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(v.x, v.z, -v.y)
    }

    func toMotion() -> MotionSample {
        var m = MotionSample()
        let gScale = (TritonReport.gyroDegPerSecFullScale / 32768) * (.pi / 180)
        let aScale = (TritonReport.accelGFullScale / 32768) * 9.80665
        m.gyro = TritonReport.deviceToOpenXR(
            SIMD3(Float(gyro.x), Float(gyro.y), Float(gyro.z)) * gScale)
        m.accel = TritonReport.deviceToOpenXR(
            SIMD3(Float(accel.x), Float(accel.y), Float(accel.z)) * aScale)
        m.deviceTimestampNs = UInt64(imuTimestamp) * 1_000   // device ticks are microseconds
        return m
    }
}

// MARK: - Device

/// One connected Steam Controller.
///
/// A single physical unit drives both virtual hands, so `chirality` is `.both` —
/// matching how the existing generic-gamepad path in WorldTracker behaves.
final class SteamControllerDevice: InputDevice {
    let identity: DeviceIdentity
    private(set) var isConnected: Bool = false

    private let lock = NSLock()
    private var latest: InputSnapshot?

    // Must be strong: CoreBluetooth does not retain peripherals on your behalf,
    // and a deallocated CBPeripheral silently drops the connection — no
    // didConnect, no didFailToConnect, no error. Held weakly this driver found
    // the controller and then went quiet forever.
    fileprivate var peripheral: CBPeripheral?
    fileprivate var reportCharacteristic: CBCharacteristic?
    /// Host->device report ID to the characteristic that carries it.
    fileprivate var outputCharacteristics: [UInt8: CBCharacteristic] = [:]

    /// Writes a host->device report. The report ID selects the characteristic
    /// and is *not* included in the payload — the characteristic implies it.
    fileprivate func sendOutputReport(_ id: UInt8, _ payload: [UInt8]) {
        guard let p = peripheral, let ch = outputCharacteristics[id] else { return }
        p.writeValue(Data(payload), for: ch, type: .withResponse)
    }

    init(instanceKey: String, displayName: String) {
        self.identity = DeviceIdentity(
            model: .steamController,
            chirality: .both,
            instanceKey: instanceKey,
            displayName: displayName
        )
    }

    func snapshot() -> InputSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    fileprivate func ingest(_ data: Data, reportId: UInt8) {
        guard let r = TritonReport(data, reportId: reportId) else { return }
        var snap = InputSnapshot(identity: identity)
        snap.buttons = r.toButtonSet()
        snap.axes = r.toAxes()
        snap.leftTouchpad = r.touchpad(left: true)
        snap.rightTouchpad = r.touchpad(left: false)
        snap.motion = r.toMotion()
        snap.hostTimestamp = CACurrentMediaTime()

        lock.lock()
        snap.battery = batteryLevel   // arrives on its own characteristic, not in the report
        latest = snap
        lock.unlock()
    }

    /// Re-asserts lizard mode off. Must be called periodically: the setting is
    /// a watchdog, and the controller falls back to emulating keyboard and
    /// mouse if it isn't refreshed. A single write at connect time does not
    /// stick — the trackpads resume scrolling a few seconds later.
    ///
    /// Goes out as a *feature* report on 100F6C34. Settings have no output
    /// report — 0x80...0x85 are all haptics — so despite the numeric collision
    /// with output report 0x87 this cannot use the output-report path.
    ///
    /// SDL's remark that BLE feature reports "are ignored" refers to their
    /// acknowledgements, not the writes: both branches at hid.m:632 write
    /// identically and differ only in whether they wait for the ack.
    fileprivate func refreshLizardModeDisable() {
        guard let p = peripheral, let ch = reportCharacteristic else { return }
        // FeatureReportHeader { type, length } then a packed ControllerSetting
        // { settingNum: UInt8, settingValue: UInt16 }. Padded to 64; the HID
        // report-number byte is not carried over BLE.
        var payload = [UInt8](repeating: 0, count: Valve.featureReportBytes)
        payload[0] = Valve.idSetSettingsValues
        payload[1] = 3                                   // one ControllerSetting
        payload[2] = Valve.settingLizardMode
        payload[3] = UInt8(Valve.lizardModeOff & 0xff)
        payload[4] = UInt8(Valve.lizardModeOff >> 8)
        p.writeValue(Data(payload), for: ch, type: .withResponse)
    }

    /// Sets rumble intensity per grip, 0...1.
    ///
    /// These are two independent LRAs, one in each grip — confirmed by feel on
    /// hardware. `MsgHapticRumble` names them `left` and `right` accordingly.
    /// SDL drives them from its generic low/high-frequency rumble abstraction,
    /// which is lossy: for VR, per-hand haptics map onto left/right directly,
    /// so this keeps the hardware's own framing.
    ///
    /// The controller's safety timeout is ~50ms, so an effect has to be
    /// re-sent (SDL uses 40ms) for as long as it should continue. Do that only
    /// while an effect is actually running: these writes share the BLE link
    /// with input notifications, and resending at 30ms unconditionally was
    /// measured to drop the input report rate from ~68Hz to ~51Hz. Send zeros
    /// once to stop, then go quiet.
    func setRumble(left: Float, right: Float) {
        let l = UInt16(max(0, min(1, left)) * Float(UInt16.max))
        let h = UInt16(max(0, min(1, right)) * Float(UInt16.max))
        // MsgHapticRumble, packed, minus the leading report id:
        //   type u8, intensity u16, left{speed u16, gain i8}, right{speed u16, gain i8}
        sendOutputReport(Valve.idOutReportHapticRumble, [
            0,                                  // type
            0, 0,                               // intensity
            UInt8(l & 0xff), UInt8(l >> 8), 0,  // left LRA speed, gain
            UInt8(h & 0xff), UInt8(h >> 8), 0,  // right LRA speed, gain
        ])
    }

    fileprivate func setBattery(_ percent: Float) {
        lock.lock()
        batteryLevel = percent
        latest?.battery = percent
        lock.unlock()
    }

    private var batteryLevel: Float?

    fileprivate func setConnected(_ v: Bool) {
        lock.lock()
        isConnected = v
        if !v { latest = nil }
        lock.unlock()
    }
}

// MARK: - Manager

/// Owns the CoreBluetooth central and vends `SteamControllerDevice`s.
///
/// Discovery note: the Valve service is *not* advertised, so we cannot filter
/// the scan by it. We check already-connected peripherals (which is what SDL's
/// hid.m does) and otherwise scan broadly, confirming identity only after
/// service discovery.
final class SteamControllerManager: NSObject {
    static let shared = SteamControllerManager()

    private var central: CBCentralManager?
    private let queue = DispatchQueue(label: "com.alvr.client.steamcontroller")

    private var devices: [UUID: SteamControllerDevice] = [:]
    private var reportIds: [UUID: UInt8] = [:]
    private let devicesLock = NSLock()
    private var lizardTimer: DispatchSourceTimer?

    /// All currently connected Steam Controllers.
    var connectedDevices: [SteamControllerDevice] {
        devicesLock.lock(); defer { devicesLock.unlock() }
        return devices.values.filter(\.isConnected)
    }

    /// Whether we are currently driving controllers. Mutated only on `queue`.
    private var isActive = false

    /// Starts the central manager. Safe to call more than once, and safe to
    /// call again after `stop()`.
    /// Requires `NSBluetoothAlwaysUsageDescription` in Info.plist.
    func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            if central == nil {
                central = CBCentralManager(delegate: self, queue: queue)
            } else if central?.state == .poweredOn {
                // Coming back from stop(): the delegate callback that normally
                // kicks off scanning already fired, so do it here.
                central?.scanForPeripherals(withServices: nil, options: nil)
            }
            startLizardKeepalive()
        }
    }

    /// Stops driving controllers and lets them fall back to lizard mode.
    ///
    /// There is deliberately no "lizard mode on" write. The setting is a
    /// watchdog rather than a latch (see `refreshLizardModeDisable`), so simply
    /// ceasing to refresh the disable is what restores it — the controller does
    /// it on its own within `lizardRefreshInterval`. Inventing a re-enable
    /// value would be a guess at a protocol we have not verified, and it would
    /// buy at most three seconds.
    ///
    /// A useful consequence: because this is the *absence* of traffic rather
    /// than a write, it survives the app being killed. `exit(0)` on
    /// backgrounding restores lizard mode for free, with no BLE write needing
    /// to flush before the process dies.
    func stop() {
        queue.async { [self] in
            guard isActive else { return }
            isActive = false
            lizardTimer?.cancel()
            lizardTimer = nil
            central?.stopScan()
            log.notice("Stopped — controllers revert to lizard mode within \(Valve.lizardRefreshInterval, privacy: .public)s")
        }
    }

    /// Lizard mode is a watchdog on the controller, so the disable has to be
    /// re-asserted or the pads go back to scrolling the desktop.
    private func startLizardKeepalive() {
        lizardTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Valve.lizardRefreshInterval,
                   repeating: Valve.lizardRefreshInterval)
        t.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            self.devicesLock.lock()
            let all = Array(self.devices.values)
            self.devicesLock.unlock()
            for d in all where d.isConnected {
                d.refreshLizardModeDisable()
            }
        }
        t.resume()
        lizardTimer = t
    }

    private func device(for p: CBPeripheral) -> SteamControllerDevice {
        devicesLock.lock(); defer { devicesLock.unlock() }
        if let d = devices[p.identifier] { return d }
        let d = SteamControllerDevice(
            instanceKey: p.identifier.uuidString,
            displayName: p.name ?? "Steam Controller"
        )
        d.peripheral = p
        devices[p.identifier] = d
        return d
    }
}

extension SteamControllerManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            guard isActive else { return }
            for p in c.retrieveConnectedPeripherals(withServices: [Valve.deviceInfo, Valve.service]) {
                connect(c, p)
            }
            c.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            log.error("Bluetooth unauthorized — check NSBluetoothAlwaysUsageDescription")
        case .poweredOff:
            log.notice("Bluetooth powered off")
        default:
            break
        }
    }

    private func connect(_ c: CBCentralManager, _ p: CBPeripheral) {
        p.delegate = self
        _ = device(for: p)
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let advertised = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let candidate = advertised.contains(Valve.service)
            || name.localizedCaseInsensitiveContains("steam")
            || name.localizedCaseInsensitiveContains("valve")
        guard candidate else { return }
        log.notice("Candidate peripheral '\(name, privacy: .public)'")
        connect(c, p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log.notice("Connected, discovering services")
        p.discoverServices([Valve.service, Valve.batteryService])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        device(for: p).setConnected(false)
        // Steam Controllers sleep aggressively; keep the reconnect standing.
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log.error("Connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        device(for: p).setConnected(false)
    }
}

extension SteamControllerManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services,
              services.contains(where: { $0.uuid == Valve.service }) else {
            // Not a Steam Controller after all.
            central?.cancelPeripheralConnection(p)
            return
        }
        for svc in services {
            p.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        if svc.uuid == Valve.batteryService,
           let ch = svc.characteristics?.first(where: { $0.uuid == Valve.batteryLevel }) {
            p.readValue(for: ch)
            p.setNotifyValue(true, for: ch)
            return
        }
        guard svc.uuid == Valve.service, let chars = svc.characteristics else { return }

        let d = device(for: p)
        d.reportCharacteristic = chars.first { $0.uuid == Valve.report }

        d.outputCharacteristics = [:]
        for ch in chars {
            if let id = Valve.outputReportId(for: ch.uuid) {
                d.outputCharacteristics[id] = ch
            }
        }
        log.notice("Output reports available: \(d.outputCharacteristics.keys.sorted().map { String($0, radix: 16) }.joined(separator: " "), privacy: .public)")

        // Explicit priority. SDL's Android path is last-match-wins over an
        // arbitrary characteristic ordering; prefer the newest report format
        // deterministically instead.
        let picked: (CBCharacteristic, UInt8)? =
            chars.first(where: { $0.uuid == Valve.inputTriton47 }).map { ($0, 0x47) }
            ?? chars.first(where: { $0.uuid == Valve.inputTriton45 }).map { ($0, 0x45) }
            ?? chars.first(where: { $0.uuid == Valve.inputD0G }).map { ($0, 0x03) }

        guard let (ch, rid) = picked else {
            log.error("Valve service present but no known input characteristic")
            return
        }

        devicesLock.lock()
        reportIds[p.identifier] = rid
        devicesLock.unlock()

        // Only claim the pads if we are actually driving the controller; a
        // stray connect after stop() must not pull it back out of lizard mode.
        if isActive {
            d.refreshLizardModeDisable()
        }

        p.setNotifyValue(true, for: ch)
        log.notice("Subscribed to Triton input report 0x\(String(rid, radix: 16), privacy: .public)")
    }

    /// Acknowledgements carry no useful payload, but errors do — a rejected
    /// settings write is the difference between lizard mode off and the
    /// trackpads quietly driving the desktop.
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error {
            log.error("Write to \(ch.uuid, privacy: .public) failed: \(e.localizedDescription, privacy: .public)")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }

        if ch.uuid == Valve.batteryLevel {
            guard let pct = data.first else { return }
            device(for: p).setBattery(Float(pct) / 100.0)
            return
        }
        devicesLock.lock()
        let rid = reportIds[p.identifier] ?? 0x47
        devicesLock.unlock()

        let d = device(for: p)
        if !d.isConnected {
            // First input report is the real confirmation that pairing and
            // notification setup both succeeded — CoreBluetooth gives no
            // callback for pairing acknowledgement.
            d.setConnected(true)
            log.notice("Steam Controller ready (\(data.count) byte reports)")
            if data.count != TritonReport.expectedLength {
                log.error("Unexpected report length \(data.count), expected \(TritonReport.expectedLength) — layout may differ from SDL's")
            }
        }
        d.ingest(data, reportId: rid)
    }
}
