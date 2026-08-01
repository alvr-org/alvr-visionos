// Triton (Steam Controller 2026) BLE probe — macOS CLI
// Validates Valve GATT service layout + report parsing against real hardware
// before any visionOS code is written.
//
// Build: swiftc -O triton_probe.swift -o triton_probe -framework CoreBluetooth
// Run:   ./triton_probe

import Foundation
import CoreBluetooth

let VALVE_SERVICE   = CBUUID(string: "100F6C32-1735-4313-B402-38567131E5F3")
let INPUT_D0G       = CBUUID(string: "100F6C33-1735-4313-B402-38567131E5F3")
let INPUT_TRITON_45 = CBUUID(string: "100F6C7A-1735-4313-B402-38567131E5F3")
let INPUT_TRITON_47 = CBUUID(string: "100F6C7C-1735-4313-B402-38567131E5F3")
let REPORT_CHAR     = CBUUID(string: "100F6C34-1735-4313-B402-38567131E5F3")
let DEVICE_INFO     = CBUUID(string: "180A")

// Button bits, from SDL_hidapi_steam_triton.c
let BUTTON_NAMES: [(UInt32, String)] = [
    (0x00000001, "A"),             (0x00000002, "B"),
    (0x00000004, "X"),             (0x00000008, "Y"),
    (0x00000010, "QAM"),           (0x00000020, "R3"),
    (0x00000040, "VIEW"),          (0x00000080, "R4"),
    (0x00000100, "R5"),            (0x00000200, "R"),
    (0x00000400, "DPAD_DOWN"),     (0x00000800, "DPAD_RIGHT"),
    (0x00001000, "DPAD_LEFT"),     (0x00002000, "DPAD_UP"),
    (0x00004000, "MENU"),          (0x00008000, "L3"),
    (0x00010000, "STEAM"),         (0x00020000, "L4"),
    (0x00040000, "L5"),            (0x00080000, "L"),
    (0x00100000, "RSTICK_TOUCH"),  (0x00200000, "RPAD_TOUCH"),
    (0x00400000, "RPAD_CLICK"),    (0x00800000, "RTRIGGER_CLICK"),
    (0x01000000, "LSTICK_TOUCH"),  (0x02000000, "LPAD_TOUCH"),
    (0x04000000, "LPAD_CLICK"),    (0x08000000, "LTRIGGER_CLICK"),
    (0x10000000, "RGRIP_TOUCH"),   (0x20000000, "LGRIP_TOUCH"),
]

struct TritonReport {
    var seq: UInt8 = 0
    var buttons: UInt32 = 0
    var trigL: Int16 = 0, trigR: Int16 = 0
    var lsX: Int16 = 0, lsY: Int16 = 0
    var rsX: Int16 = 0, rsY: Int16 = 0
    var padTimestamp: UInt16 = 0        // 0x47 only
    var lPadX: Int16 = 0, lPadY: Int16 = 0, lPressure: UInt16 = 0
    var rPadX: Int16 = 0, rPadY: Int16 = 0, rPressure: UInt16 = 0
    var imuTimestamp: UInt32 = 0
    var accelX: Int16 = 0, accelY: Int16 = 0, accelZ: Int16 = 0
    var gyroX: Int16 = 0, gyroY: Int16 = 0, gyroZ: Int16 = 0
}

// Little-endian scalar reads at explicit byte offsets (structs are #pragma pack(1))
extension Data {
    func u8 (_ o: Int) -> UInt8  { self[startIndex + o] }
    func u16(_ o: Int) -> UInt16 { UInt16(u8(o)) | (UInt16(u8(o+1)) << 8) }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | (UInt32(u16(o+2)) << 16) }
    func i16(_ o: Int) -> Int16  { Int16(bitPattern: u16(o)) }
}

func parse(_ d: Data, reportId: UInt8) -> TritonReport? {
    guard d.count >= 45 else { return nil }
    var r = TritonReport()
    r.seq     = d.u8(0)
    r.buttons = d.u32(1)
    r.trigL   = d.i16(5);  r.trigR = d.i16(7)
    r.lsX     = d.i16(9);  r.lsY   = d.i16(11)
    r.rsX     = d.i16(13); r.rsY   = d.i16(15)

    if reportId == 0x47 {
        // TritonMTUNoQuat32TS_t — adds 16-bit trackpad timestamp, 16-bit IMU timestamp
        r.padTimestamp = d.u16(17)
        r.lPadX = d.i16(19); r.lPadY = d.i16(21); r.lPressure = d.u16(23)
        r.rPadX = d.i16(25); r.rPadY = d.i16(27); r.rPressure = d.u16(29)
        r.imuTimestamp = UInt32(d.u16(31))
        r.accelX = d.i16(33); r.accelY = d.i16(35); r.accelZ = d.i16(37)
        r.gyroX  = d.i16(39); r.gyroY  = d.i16(41); r.gyroZ  = d.i16(43)
    } else {
        // TritonMTUNoQuat_t — no trackpad timestamp, 32-bit IMU timestamp
        r.lPadX = d.i16(17); r.lPadY = d.i16(19); r.lPressure = d.u16(21)
        r.rPadX = d.i16(23); r.rPadY = d.i16(25); r.rPressure = d.u16(27)
        r.imuTimestamp = d.u32(29)
        r.accelX = d.i16(33); r.accelY = d.i16(35); r.accelZ = d.i16(37)
        r.gyroX  = d.i16(39); r.gyroY  = d.i16(41); r.gyroZ  = d.i16(43)
    }
    return r
}

func describe(_ r: TritonReport) -> String {
    let pressed = BUTTON_NAMES.filter { r.buttons & $0.0 != 0 }.map(\.1).joined(separator: " ")
    let gyroScale  = 2000.0 / 32768.0            // deg/s
    let accelScale = 2.0 / 32768.0               // g
    var s = ""
    s += String(format: "seq=%3d  ", r.seq)
    s += String(format: "LS(%+.2f,%+.2f) RS(%+.2f,%+.2f)  ",
                Float(r.lsX)/32767, Float(r.lsY)/32767,
                Float(r.rsX)/32767, Float(r.rsY)/32767)
    s += String(format: "T(%.2f,%.2f)  ", Float(r.trigL)/32767, Float(r.trigR)/32767)
    s += String(format: "gyro(%+7.1f,%+7.1f,%+7.1f)deg/s  ",
                Double(r.gyroX)*gyroScale, Double(r.gyroY)*gyroScale, Double(r.gyroZ)*gyroScale)
    s += String(format: "accel(%+5.2f,%+5.2f,%+5.2f)g  ",
                Double(r.accelX)*accelScale, Double(r.accelY)*accelScale, Double(r.accelZ)*accelScale)
    if r.buttons & 0x02000000 != 0 {   // LPAD_TOUCH
        s += String(format: "LPad(%+.2f,%+.2f p=%.2f) ",
                    Float(r.lPadX)/65536 + 0.5, -Float(r.lPadY)/65536 + 0.5,
                    Float(r.lPressure)/32768)
    }
    if r.buttons & 0x00200000 != 0 {   // RPAD_TOUCH
        s += String(format: "RPad(%+.2f,%+.2f p=%.2f) ",
                    Float(r.rPadX)/65536 + 0.5, -Float(r.rPadY)/65536 + 0.5,
                    Float(r.rPressure)/32768)
    }
    if !pressed.isEmpty { s += "[\(pressed)]" }
    return s
}

final class Probe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var reportId: UInt8 = 0
    var packetCount = 0
    var firstPacketLogged = false
    var seenServices = Set<String>()

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("[*] Bluetooth on. Looking for Valve controller…")
            // The Valve service is NOT advertised, so we can't filter the scan by it.
            // Check already-connected peripherals first (this is what SDL's hid.m does),
            // then fall back to a broad scan.
            let connected = c.retrieveConnectedPeripherals(withServices: [DEVICE_INFO, VALVE_SERVICE])
            if !connected.isEmpty {
                print("[*] \(connected.count) already-connected peripheral(s):")
                for p in connected { print("      - \(p.name ?? "(unnamed)")  \(p.identifier)") }
            }
            for p in connected { connect(p) }
            c.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            print("[!] Bluetooth unauthorized — grant Terminal Bluetooth access in")
            print("    System Settings > Privacy & Security > Bluetooth, then re-run.")
            exit(1)
        case .poweredOff:
            print("[!] Bluetooth is off."); exit(1)
        default:
            print("[*] state=\(c.state.rawValue)")
        }
    }

    func connect(_ p: CBPeripheral) {
        guard target == nil else { return }
        print("[*] Connecting to \(p.name ?? "(unnamed)") \(p.identifier)")
        target = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = p.name ?? (ad[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let svcs = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let looksValve = svcs.contains(VALVE_SERVICE)
            || name.lowercased().contains("steam")
            || name.lowercased().contains("valve")
        if looksValve {
            print("[+] Candidate: '\(name)' rssi=\(rssi) services=\(svcs)")
            c.stopScan()
            connect(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("[+] Connected. Discovering services…")
        p.discoverServices(nil)   // discover everything so we learn the real layout
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        print("[!] Failed to connect: \(error?.localizedDescription ?? "?")")
        target = nil
        c.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        print("[!] Disconnected: \(error?.localizedDescription ?? "clean")")
        target = nil
        c.scanForPeripherals(withServices: nil, options: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = p.services else { return }
        print("[*] \(services.count) service(s):")
        for s in services {
            print("      \(s.uuid)\(s.uuid == VALVE_SERVICE ? "   <-- VALVE" : "")")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard let chars = s.characteristics else { return }
        print("[*] service \(s.uuid) characteristics:")
        for ch in chars {
            var props: [String] = []
            if ch.properties.contains(.read)   { props.append("read") }
            if ch.properties.contains(.write)  { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            if ch.properties.contains(.notify) { props.append("notify") }
            print("      \(ch.uuid)  [\(props.joined(separator: ","))]")
        }
        guard s.uuid == VALVE_SERVICE else { return }

        // Explicit priority: 0x47 (newest) > 0x45 > D0G. SDL's Android code is
        // last-match-wins over an arbitrary characteristic order; be deterministic.
        let pick: (CBCharacteristic, UInt8)? =
            chars.first(where: { $0.uuid == INPUT_TRITON_47 }).map { ($0, 0x47) }
            ?? chars.first(where: { $0.uuid == INPUT_TRITON_45 }).map { ($0, 0x45) }
            ?? chars.first(where: { $0.uuid == INPUT_D0G       }).map { ($0, 0x03) }

        guard let (ch, rid) = pick else {
            print("[!] No known input characteristic on the Valve service.")
            print("    The 2026 controller may use a new UUID — see the dump above.")
            return
        }
        reportId = rid
        print(String(format: "[+] Subscribing to input characteristic, report 0x%02x", rid))
        p.setNotifyValue(true, for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let e = error { print("[!] notify error: \(e.localizedDescription)"); return }
        print("[+] Notifications \(ch.isNotifying ? "ON" : "OFF") for \(ch.uuid)")
        print("[*] Move sticks / press buttons / touch pads. Ctrl-C to stop.\n")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        packetCount += 1

        if !firstPacketLogged {
            firstPacketLogged = true
            print("[+] First packet: \(d.count) bytes (expected 45)")
            print("    raw: \(d.map { String(format: "%02x", $0) }.joined(separator: " "))\n")
            if d.count != 45 {
                print("[!] LENGTH MISMATCH — the 2026 report layout differs from SDL's.")
                print("    Parsed fields below are unreliable; we'll need to re-derive offsets.\n")
            }
        }
        // Throttle console output; reports arrive at ~250Hz
        guard packetCount % 25 == 0 else { return }
        if let r = parse(d, reportId: reportId) {
            print(describe(r))
        }
    }
}

let probe = Probe()
probe.start()
signal(SIGINT) { _ in print("\n[*] bye"); exit(0) }
RunLoop.main.run()
