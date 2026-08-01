// Offline macOS harness for the *actual* SteamControllerDevice driver.
//
// This compiles the real ALVRClient/Input sources rather than a parallel
// reimplementation, so what it validates is the code that ships. Build via
// build_harness.sh.

import Foundation
import CoreBluetooth

private func bar(_ v: Float, width: Int = 10) -> String {
    let n = Int((abs(v) * Float(width)).rounded())
    return String(repeating: "#", count: min(n, width))
        + String(repeating: ".", count: max(0, width - n))
}

print("[*] Starting SteamControllerManager (real driver)…")
print("[*] Waiting for a Steam Controller. Ctrl-C to stop.\n")
SteamControllerManager.shared.start()

var lastPrint = Date.distantPast
var everSawDevice = false

// Report-rate measurement. Poll far faster than reports arrive and count
// distinct hostTimestamps — each one is a fresh packet. SDL assumes ~250Hz
// over USB; BLE connection intervals may be much slower, which matters for
// motion-to-photon latency.
var seenTimestamps = Set<TimeInterval>()
var rateWindowStart = Date()
var measuredHz: Double = 0

// Peak tracking, so a quick stick flick or trigger pull is still visible even
// if it lands between printed lines.
var peakStick: Float = 0
var peakTrigger: Float = 0
var peakGyro: Float = 0
var everSeenButtons = Set<String>()
var everSeenPadTouch = false

// Signed extremes. Absolute peaks can't answer polarity questions — whether
// pushing a stick up yields +Y, or which corner of a touchpad is the origin.
struct Extent {
    var lo: Float = .greatestFiniteMagnitude
    var hi: Float = -.greatestFiniteMagnitude
    mutating func add(_ v: Float) { lo = min(lo, v); hi = max(hi, v) }
    var desc: String {
        lo > hi ? "(never moved)" : String(format: "%+.2f … %+.2f", lo, hi)
    }
}
var lsX = Extent(), lsY = Extent(), rsX = Extent(), rsY = Extent()
var lpX = Extent(), lpY = Extent(), rpX = Extent(), rpY = Extent()
var padPressure = Extent()

// Gyro axis identification. Printing every sample is unreadable, so only
// report when one axis clearly dominates — that makes it possible to rotate
// deliberately about one physical axis and read off which device axis moves
// and in which direction.
let gyroEventThreshold: Float = 1.5   // rad/s
var lastGyroEvent = Date.distantPast

// Rumble is driven from the triggers: squeeze left for the low motor, right
// for the high one. Resent continuously because the controller's own safety
// timeout is ~50ms — a single write stops almost immediately.
var lastRumble = Date.distantPast
var rumbleWasActive = false
let rumbleResendInterval: TimeInterval = 0.030
var everFeltBattery = false

let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
    let devices = SteamControllerManager.shared.connectedDevices
    guard let d = devices.first, let s = d.snapshot() else { return }

    if !everSawDevice {
        everSawDevice = true
        print("[+] Device: \(d.identity.displayName)  chirality=\(d.identity.chirality)\n")
    }

    if seenTimestamps.insert(s.hostTimestamp).inserted {
        peakStick = max(peakStick, max(abs(s.axes.leftStick.x), abs(s.axes.leftStick.y),
                                       abs(s.axes.rightStick.x), abs(s.axes.rightStick.y)))
        peakTrigger = max(peakTrigger, max(s.axes.leftTrigger, s.axes.rightTrigger))
        lsX.add(s.axes.leftStick.x);  lsY.add(s.axes.leftStick.y)
        rsX.add(s.axes.rightStick.x); rsY.add(s.axes.rightStick.y)

        if let m = s.motion {
            peakGyro = max(peakGyro, max(abs(m.gyro.x), abs(m.gyro.y), abs(m.gyro.z)))
            // Report only a clearly dominant axis, at most a few times a second.
            let mags = [abs(m.gyro.x), abs(m.gyro.y), abs(m.gyro.z)]
            let top = mags.firstIndex(of: mags.max()!)!
            let others = mags.enumerated().filter { $0.offset != top }.map(\.element).max() ?? 0
            if mags[top] > gyroEventThreshold, mags[top] > others * 2,
               Date().timeIntervalSince(lastGyroEvent) > 0.25 {
                lastGyroEvent = Date()
                let axis = ["X", "Y", "Z"][top]
                let signed = [m.gyro.x, m.gyro.y, m.gyro.z][top]
                print(String(format: "    >> gyro dominant: %@ %@  (%+.2f rad/s)",
                             axis, signed < 0 ? "negative" : "positive", signed))
            }
        }
        everSeenButtons.formUnion(s.buttons.names)
        if let lp = s.leftTouchpad, lp.isTouched {
            everSeenPadTouch = true
            lpX.add(lp.position.x); lpY.add(lp.position.y); padPressure.add(lp.pressure)
        }
        if let rp = s.rightTouchpad, rp.isTouched {
            everSeenPadTouch = true
            rpX.add(rp.position.x); rpY.add(rp.position.y); padPressure.add(rp.pressure)
        }
    }
    // Only write while an effect is actually running, plus one final zero to
    // stop it. Resending zeros costs real input bandwidth: continuous 30ms
    // writes drop the report rate from ~68Hz to ~51Hz on this link.
    let wantLow = s.axes.leftTrigger, wantHigh = s.axes.rightTrigger
    let active = wantLow > 0.01 || wantHigh > 0.01
    if (active || rumbleWasActive), Date().timeIntervalSince(lastRumble) > rumbleResendInterval {
        lastRumble = Date()
        d.setRumble(left: wantLow, right: wantHigh)
        rumbleWasActive = active
    }

    let elapsed = Date().timeIntervalSince(rateWindowStart)
    if elapsed >= 1.0 {
        measuredHz = Double(seenTimestamps.count) / elapsed
        seenTimestamps.removeAll(keepingCapacity: true)
        rateWindowStart = Date()
    }

    // Throttle to ~8Hz so the console stays readable.
    guard Date().timeIntervalSince(lastPrint) > 0.125 else { return }
    lastPrint = Date()

    var line = String(format: "%5.1fHz ", measuredHz)
    if let b = s.battery {
        everFeltBattery = true
        line += String(format: "bat%3.0f%% ", b * 100)
    } else {
        line += "bat  ?  "
    }
    line += String(format: "LS(%+.2f,%+.2f) RS(%+.2f,%+.2f) ",
                   s.axes.leftStick.x, s.axes.leftStick.y,
                   s.axes.rightStick.x, s.axes.rightStick.y)
    line += "LT[\(bar(s.axes.leftTrigger))] RT[\(bar(s.axes.rightTrigger))] "

    if let m = s.motion {
        line += String(format: "gyro(%+6.2f,%+6.2f,%+6.2f) ", m.gyro.x, m.gyro.y, m.gyro.z)
        line += String(format: "acc(%+5.1f,%+5.1f,%+5.1f) ", m.accel.x, m.accel.y, m.accel.z)
    }
    if let lp = s.leftTouchpad, lp.isTouched {
        line += String(format: "LPad(%.2f,%.2f p%.2f) ", lp.position.x, lp.position.y, lp.pressure)
    }
    if let rp = s.rightTouchpad, rp.isTouched {
        line += String(format: "RPad(%.2f,%.2f p%.2f) ", rp.position.x, rp.position.y, rp.pressure)
    }
    let names = s.buttons.names
    if !names.isEmpty { line += "[\(names.joined(separator: " "))]" }

    print(line)
}
RunLoop.main.add(timer, forMode: .default)

signal(SIGINT) { _ in
    print("\n--- coverage over this run ---")
    print(String(format: "peak stick deflection : %.2f  (want ~1.00 at full throw)", peakStick))
    print(String(format: "peak trigger          : %.2f  (want ~1.00 fully pulled)", peakTrigger))
    print(String(format: "peak gyro             : %.2f rad/s", peakGyro))
    print("touchpad touch seen   : \(everSeenPadTouch)")
    print("battery reported      : \(everFeltBattery)")
    print("")
    print("stick range (push UP should give positive Y):")
    print("  left  X \(lsX.desc)   Y \(lsY.desc)")
    print("  right X \(rsX.desc)   Y \(rsY.desc)")
    print("touchpad range (expect roughly 0.00 … 1.00 corner to corner):")
    print("  left  X \(lpX.desc)   Y \(lpY.desc)")
    print("  right X \(rpX.desc)   Y \(rpY.desc)")
    print("  pressure \(padPressure.desc)")
    print("")

    let names = everSeenButtons.sorted()
    print("buttons seen (\(names.count)): \(names.isEmpty ? "none" : names.joined(separator: " "))")
    let all = ButtonSet.allNames.map(\.1)
    let missing = all.filter { !everSeenButtons.contains($0) }
    if !missing.isEmpty {
        print("NOT seen (\(missing.count)): \(missing.joined(separator: " "))")
        print("  Either untested, or the bit is wrong in TritonButton.")
    }
    print("\n[*] bye")
    exit(0)
}
RunLoop.main.run()
