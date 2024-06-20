//
//  EventHandler.swift
//

import Foundation
import Metal
import VideoToolbox
import Combine
import AVKit
import Foundation
import Network
import UIKit

class EventHandler: ObservableObject {
    static let shared = EventHandler()

    var eventsThread : Thread?
    var eventsWatchThread : Thread?
        
    var alvrInitialized = false
    var streamingActive = false
    
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var hostname: String = ""
    @Published var IP: String = ""
    @Published var alvrVersion: String = ""
    
    var renderStarted = false
    
    var inputRunning = false
    var vtDecompressionSession:VTDecompressionSession? = nil
    var videoFormat:CMFormatDescription? = nil
    var frameQueueLock = NSObject()

    var frameQueue = [QueuedFrame]()
    var frameQueueLastTimestamp: UInt64 = 0
    var frameQueueLastImageBuffer: CVImageBuffer? = nil
    var lastQueuedFrame: QueuedFrame? = nil
    var lastQueuedFramePose: simd_float4x4? = nil
    var lastRequestedTimestamp: UInt64 = 0
    var lastSubmittedTimestamp: UInt64 = 0
    var lastIpd: Float = -1
    var viewTransforms: [simd_float4x4] = [matrix_identity_float4x4, matrix_identity_float4x4]
    var viewFovs: [AlvrFov] = [AlvrFov(left: -1.0471973, right: 0.7853982, up: 0.7853982, down: -0.8726632), AlvrFov(left: -0.7853982, right: 1.0471973, up: 0.7853982, down: -0.8726632)]

    var framesSinceLastIDR:Int = 0
    var framesSinceLastDecode:Int = 0

    var streamEvent: AlvrEvent? = nil
    
    var framesRendered:Int = 0
    var totalFramesRendered:Int = 0
    var eventHeartbeat:Int = 0
    var lastEventHeartbeat:Int = -1
    
    var timeLastSentPeriodicUpdatedValues: Double = 0.0
    var timeLastSentMdnsBroadcast: Double = 0.0
    var timeLastAlvrEvent: Double = 0.0
    var timeLastFrameGot: Double = 0.0
    var timeLastFrameSent: Double = 0.0
    var timeLastFrameDecoded: Double = 0.0
    var numberOfEventThreadRestarts: Int = 0
    var mdnsListener: NWListener? = nil
    
    var viewWidth = 1920*2
    var viewHeight = 1824*2
    
    var stutterSampleStart = 0.0
    var stutterEventsCounted = 0
    var lastStutterTime = 0.0
    var awdlAlertPresented = false
    var audioIsOff = false
    
    init() {}
    
    func initializeAlvr() {
        fixAudioForDirectStereo()
        if !alvrInitialized {
            print("Initialize ALVR")
            alvrInitialized = true
            let refreshRates:[Float] = [100, 96, 90]
            let capabilities = AlvrClientCapabilities(default_view_width: UInt32(1920*2), default_view_height: UInt32(1824*2), external_decoder: true, refresh_rates: refreshRates, refresh_rates_count: Int32(refreshRates.count), foveated_encoding: true, encoder_high_profile: true, encoder_10_bits: true, encoder_av1: false)
            alvr_initialize(/*capabilities=*/capabilities)
            alvr_resume()
        }
    }
    
    func start() {
        alvr_resume()

        fixAudioForDirectStereo()
        if !inputRunning {
            print("Starting event thread")
            inputRunning = true
            eventsThread = Thread {
                self.handleAlvrEvents()
            }
            eventsThread?.name = "Events Thread"
            eventsThread?.start()
            
            eventsWatchThread = Thread {
                self.eventsWatchdog()
            }
            eventsWatchThread?.name = "Events Watchdog Thread"
            eventsWatchThread?.start()
        }
    }
    
    func stop() {
        /*inputRunning = false
        if alvrInitialized {
            print("Stopping")
            renderStarted = false
            alvr_destroy()
            alvrInitialized = false
        }*/
        
        print("EventHandler.Stop")
        streamingActive = false
        vtDecompressionSession = nil
        videoFormat = nil
        lastRequestedTimestamp = 0
        lastSubmittedTimestamp = 0
        framesRendered = 0
        framesSinceLastIDR = 0
        framesSinceLastDecode = 0
        lastIpd = -1
        lastQueuedFrame = nil
        
        updateConnectionState(.disconnected)
    }
    
    // Currently unused
    func handleHeadsetRemovedOrReentry() {
        print("EventHandler.handleHeadsetRemovedOrReentry")
        lastIpd = -1
        framesRendered = 0
        framesSinceLastIDR = 0
        framesSinceLastDecode = 0
        lastRequestedTimestamp = 0
        lastSubmittedTimestamp = 0
        lastQueuedFrame = nil
    }
    
    func handleHeadsetRemoved() {
        preventAudioCracklingOnExit()
    }
    
    func handleHeadsetEntered() {
        fixAudioForDirectStereo()
    }
    
    func handleRenderStarted() {
        // Prevent event thread rebooting if we can
        timeLastAlvrEvent = CACurrentMediaTime()
        timeLastFrameGot = CACurrentMediaTime()
        timeLastFrameSent = CACurrentMediaTime()
        timeLastFrameDecoded = CACurrentMediaTime()
    }

    func fixAudioForDirectStereo() {
        audioIsOff = false
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(true)
            try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
            try audioSession.setMode(.voiceChat)
            try audioSession.setPreferredOutputNumberOfChannels(2)
            try audioSession.setIntendedSpatialExperience(.bypassed)
        } catch {
            print("Failed to set the audio session configuration?")
        }
    }
    
    func preventAudioCracklingOnExit() {
        if audioIsOff {
            return
        }
        audioIsOff = true
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to set the audio session configuration? \(error)")
        }
    }

    // Handle mDNS broadcasts
    func handleMdnsBroadcasts() {
        // HACK: Some mDNS clients seem to only see edge updates (ie, when a client appears/disappears)
        // so we just create/destroy this every 2s until we're streaming.
        if mdnsListener != nil {
            mdnsListener!.cancel()
            mdnsListener = nil
        }

        if mdnsListener == nil && !streamingActive {
            do {
                mdnsListener = try NWListener(using: .tcp)
            } catch {
                mdnsListener = nil
                print("Failed to create mDNS NWListener?")
            }
            
            if let listener = mdnsListener {
                let txtRecord = NWTXTRecord(["protocol" : getMdnsProtocolId(), "device_id" : getHostname()])
                listener.service = NWListener.Service(name: "ALVR Apple Vision Pro", type: getMdnsService(), txtRecord: txtRecord)

                // Handle errors if any
                listener.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        print("mDNS listener is ready")
                    case .waiting(let error):
                        print("mDNS listener is waiting with error: \(error)")
                    case .failed(let error):
                        print("mDNS listener failed with error: \(error)")
                    default:
                        break
                    }
                }
                listener.serviceRegistrationUpdateHandler = { change in
                    print("mDNS registration updated:", change)
                }
                listener.newConnectionHandler = { connection in
                    connection.cancel()
                }

                listener.start(queue: DispatchQueue.main)
            }
        }
        
        timeLastSentMdnsBroadcast = CACurrentMediaTime()
    }

    // Data which only needs to be sent periodically, such as battery percentage
    func handlePeriodicUpdatedValues() {
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging
        if streamingActive {
            alvr_send_battery(WorldTracker.deviceIdHead, batteryLevel, isCharging)
        }
        
        timeLastSentPeriodicUpdatedValues = CACurrentMediaTime()
    }
    
    func eventsWatchdog() {
        while true {
            if eventHeartbeat == lastEventHeartbeat {
                if (renderStarted && numberOfEventThreadRestarts > 3) || numberOfEventThreadRestarts > 10 {
                    print("Event thread is MIA, exiting")
                    exit(0)
                }
                else {
                    print("Event thread is MIA, restarting event thread")
                    eventsThread = Thread {
                        self.handleAlvrEvents()
                    }
                    eventsThread?.name = "Events Thread"
                    eventsThread?.start()
                    numberOfEventThreadRestarts += 1
                }
            }
            
            DispatchQueue.main.async {
                let state = UIApplication.shared.applicationState
                if state == .background {
                    print("App in background, exiting")
                    if let service = self.mdnsListener {
                        service.cancel()
                        self.mdnsListener = nil
                    }
                    exit(0)
                }
            }
            
            lastEventHeartbeat = eventHeartbeat
            for _ in 0...5 {
                usleep(1000*1000)
            }
        }
    }
    
    func handleNals() {
        timeLastFrameGot = CACurrentMediaTime()
        while renderStarted {
            guard let (timestamp, viewParams, nal) = VideoHandler.pollNal() else {
                break
            }
            
            objc_sync_enter(frameQueueLock)
            framesSinceLastIDR += 1

            // If we're receiving NALs timestamped from >400ms ago, stop decoding them
            // to prevent a cascade of needless decoding lag
            let ns_diff_from_last_req_ts = lastRequestedTimestamp > timestamp ? lastRequestedTimestamp &- timestamp : 0
            let lagSpiked = (ns_diff_from_last_req_ts > 1000*1000*600 && framesSinceLastIDR > 90*2)
            
            if CACurrentMediaTime() - stutterSampleStart >= 60.0 {
                print("Stuttter events in the last minute:", stutterEventsCounted)
                stutterSampleStart = CACurrentMediaTime()
                
                if stutterEventsCounted >= 50 {
                    print("AWDL detected!")
                    if ALVRClientApp.gStore.settings.dontShowAWDLAlertAgain {
                        print("User doesn't want to see the alert.")
                    }
                    else {
                        DispatchQueue.main.async {
                            if self.awdlAlertPresented {
                                return
                            }
                            self.awdlAlertPresented = true
                            
                            // Not super kosher but I don't see another way.
                            ALVRClientApp.shared.openWindow(id: "AWDLAlert")
                        }
                    }
                }
                
                stutterEventsCounted = 0
            }
            if ns_diff_from_last_req_ts > 1000*1000*40 {
                if (CACurrentMediaTime() - lastStutterTime > 0.25 && CACurrentMediaTime() - lastStutterTime < 10.0) || ns_diff_from_last_req_ts > 1000*1000*100 {
                    stutterEventsCounted += 1
                    //print(ns_diff_from_last_req_ts, CACurrentMediaTime() - lastStutterTime)
                }
                lastStutterTime = CACurrentMediaTime()
            }
            // TODO: adjustable framerate
            // TODO: maybe also call this if we fail to decode for too long.
            if lastRequestedTimestamp != 0 && (lagSpiked || framesSinceLastDecode > 90*2) {
                objc_sync_exit(frameQueueLock)

                print("Handle spike!", framesSinceLastDecode, framesSinceLastIDR, ns_diff_from_last_req_ts)

                // We have to request an IDR to resume the video feed
                VideoHandler.abandonAllPendingNals()
                alvr_request_idr()
                framesSinceLastIDR = 0
                framesSinceLastDecode = 0

                continue
            }
            objc_sync_exit(frameQueueLock)

            if let vtDecompressionSession = vtDecompressionSession {
                VideoHandler.feedVideoIntoDecoder(decompressionSession: vtDecompressionSession, nals: nal, timestamp: timestamp, videoFormat: videoFormat!) { [self] imageBuffer in
                    guard let imageBuffer = imageBuffer else {
                        return
                    }
                    
                    //print(timestamp, (CACurrentMediaTime() - timeLastFrameDecoded) * 1000.0)
                    timeLastFrameDecoded = CACurrentMediaTime()

                    //let imageBufferPtr = Unmanaged.passUnretained(imageBuffer).toOpaque()
                    //print("finish decode: \(timestamp), \(imageBufferPtr), \(nal_type)")

                    objc_sync_enter(frameQueueLock)
                    framesSinceLastDecode = 0
                    if frameQueueLastTimestamp != timestamp || true
                    {
                        alvr_report_frame_decoded(timestamp)

                        // TODO: For some reason, really low frame rates seem to decode the wrong image for a split second?
                        // But for whatever reason this is fine at high FPS.
                        // From what I've read online, the only way to know if an H264 frame has actually completed is if
                        // the next frame is starting, so keep this around for now just in case.
                        if frameQueueLastImageBuffer != nil {
                            //frameQueue.append(QueuedFrame(imageBuffer: frameQueueLastImageBuffer!, timestamp: frameQueueLastTimestamp))
                            frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp, viewParams: viewParams))
                        }
                        else {
                            frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp, viewParams: viewParams))
                        }
                        if frameQueue.count > 3 {
                            frameQueue.removeFirst()
                        }


                        frameQueueLastTimestamp = timestamp
                        frameQueueLastImageBuffer = imageBuffer
                        timeLastFrameSent = CACurrentMediaTime()
                    }

                    // Pull the very last imageBuffer for a given timestamp
                    if frameQueueLastTimestamp == timestamp {
                        frameQueueLastImageBuffer = imageBuffer
                    }

                    objc_sync_exit(frameQueueLock)
                }
            } else {
                alvr_report_frame_decoded(timestamp)
                alvr_report_compositor_start(timestamp)
                alvr_report_submit(timestamp, 0)
            }
        }
    }
    
    func getHostname() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_hostname(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret + ".alvr"; // Hack: runtime needs to fix this D:
        } else {
            print("Unable to decode alvr_hostname into a UTF-8 string.")
            return "unknown.client.alvr";
        }
    }
    
    func getMdnsService() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_mdns_service(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret.replacing(".local", with: "", maxReplacements: 1);
        } else {
            print("Unable to decode alvr_mdns_service into a UTF-8 string.")
            return "_alvr._tcp";
        }
    }
    
    func getMdnsProtocolId() -> String {
        var byteArray = [UInt8](repeating: 0, count: 256)

        byteArray.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Void in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            
            alvr_protocol_id(cStringPtr)
        }
        
        if let utf8String = String(bytes: byteArray, encoding: .utf8) {
            let ret = utf8String.trimmingCharacters(in: ["\0"]);
            return ret;
        } else {
            print("Unable to decode alvr_protocol_id into a UTF-8 string.")
            return "unknown";
        }
    }
    
    func kickAlvr() {
        stop()
        alvrInitialized = false
        alvr_destroy()
        initializeAlvr()
        
        timeLastAlvrEvent = CACurrentMediaTime()
        timeLastFrameGot = CACurrentMediaTime()
        timeLastFrameSent = CACurrentMediaTime()
    }

    func handleAlvrEvents() {
        print("Start event thread...")
        while inputRunning {
            eventHeartbeat += 1
            // Send periodic updated values, such as battery percentage, once every five seconds
            let currentTime = CACurrentMediaTime()
            if currentTime - timeLastSentPeriodicUpdatedValues >= 5.0 {
                handlePeriodicUpdatedValues()
            }
            if currentTime - timeLastSentMdnsBroadcast >= 5.0 {
                handleMdnsBroadcasts()
            }
            
            DispatchQueue.main.async {
                let state = UIApplication.shared.applicationState
                if state == .background {
                    print("App in background, exiting")
                    if let service = self.mdnsListener {
                        service.cancel()
                        self.mdnsListener = nil
                    }
                    exit(0)
                }
            }
            
            let diffSinceLastEvent = currentTime - timeLastAlvrEvent
            let diffSinceLastNal = currentTime - timeLastFrameGot
            let diffSinceLastDecode = currentTime - timeLastFrameSent
            if (!renderStarted && timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 20.0 || diffSinceLastNal >= 20.0))
               || (renderStarted && timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 30.0 || diffSinceLastNal >= 30.0))
               || (renderStarted && timeLastFrameSent != 0 && (diffSinceLastDecode >= 30.0)) {
                EventHandler.shared.updateConnectionState(.disconnected)
                
                print("Kick ALVR...")
                print("diffSinceLastEvent:", diffSinceLastEvent)
                print("diffSinceLastNal:", diffSinceLastNal)
                print("diffSinceLastDecode:", diffSinceLastDecode)
                kickAlvr()
            }
            
            if alvrInitialized && (diffSinceLastNal >= 5.0) {
                print("Request IDR")
                //alvr_request_idr()
                timeLastFrameGot = CACurrentMediaTime()
            }

            var alvrEvent = AlvrEvent()
            let res = alvr_poll_event(&alvrEvent)
            if !res {
                usleep(1000)
                continue
            }
            timeLastAlvrEvent = CACurrentMediaTime()
            switch UInt32(alvrEvent.tag) {
            case ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue:
                print("hud message updated")
                if !renderStarted {
                    let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                    alvr_hud_message(hudMessageBuffer.baseAddress)
                    let message = String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8)!
                    parseMessage(message)
                    print(message)
                    hudMessageBuffer.deallocate()
                }
            case ALVR_EVENT_STREAMING_STARTED.rawValue:
                print("streaming started \(alvrEvent.STREAMING_STARTED)")
                numberOfEventThreadRestarts = 0
                if !streamingActive {
                    streamEvent = alvrEvent
                    streamingActive = true
                    alvr_request_idr()
                    framesSinceLastIDR = 0
                    framesSinceLastDecode = 0
                    lastIpd = -1
                    EventHandler.shared.updateConnectionState(.connected)
                }
                if !renderStarted {
                    WorldTracker.shared.sendFakeTracking(viewFovs: viewFovs, targetTimestamp: CACurrentMediaTime() - 1.0)
                }
            case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                print("streaming stopped")
                if streamingActive {
                    streamingActive = false
                    stop()
                    timeLastAlvrEvent = CACurrentMediaTime()
                    timeLastFrameSent = CACurrentMediaTime()
                }
            case ALVR_EVENT_HAPTICS.rawValue:
                //print("haptics: \(alvrEvent.HAPTICS)")
                let haptics = alvrEvent.HAPTICS
                var duration = Double(haptics.duration_s)
                
                // Hack: Controllers can't do 10ms vibrations.
                if duration < 0.032 {
                    duration = 0.032
                }
                if haptics.device_id == WorldTracker.deviceIdLeftHand {
                    WorldTracker.shared.leftHapticsStart = CACurrentMediaTime()
                    WorldTracker.shared.leftHapticsEnd = CACurrentMediaTime() + duration
                    WorldTracker.shared.leftHapticsFreq = haptics.frequency
                    WorldTracker.shared.leftHapticsAmplitude = haptics.amplitude
                }
                else {
                    WorldTracker.shared.rightHapticsStart = CACurrentMediaTime()
                    WorldTracker.shared.rightHapticsEnd = CACurrentMediaTime() + duration
                    WorldTracker.shared.rightHapticsFreq = haptics.frequency
                    WorldTracker.shared.rightHapticsAmplitude = haptics.amplitude
                }
            case ALVR_EVENT_DECODER_CONFIG.rawValue:
                streamingActive = true
                print("create decoder \(alvrEvent.DECODER_CONFIG)")
                // Don't reinstantiate the decoder if it's already created.
                // TODO: Switching from H264 -> HEVC at runtime?
                if vtDecompressionSession != nil {
                    handleNals()
                    continue
                }
                while alvrInitialized {
                   guard let (_, _, nal) = VideoHandler.pollNal() else {
                       print("create decoder: failed to poll nal?!")
                       break
                   }
                   //NSLog("%@", nal as NSData)
                   //let val = (nal[4] & 0x7E) >> 1
                   if (nal[3] == 0x01 && nal[4] & 0x1f == H264_NAL_TYPE_SPS) || (nal[2] == 0x01 && nal[3] & 0x1f == H264_NAL_TYPE_SPS) {
                       // here we go!
                       (vtDecompressionSession, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nal, codec: H264_NAL_TYPE_SPS)
                       break
                   } else if (nal[3] == 0x01 && (nal[4] & 0x7E) >> 1 == HEVC_NAL_TYPE_VPS) || (nal[2] == 0x01 && (nal[3] & 0x7E) >> 1 == HEVC_NAL_TYPE_VPS) {
                        // The NAL unit type is 32 (VPS)
                       (vtDecompressionSession, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nal, codec: HEVC_NAL_TYPE_VPS)
                       break
                   }
                }
            case ALVR_EVENT_FRAME_READY.rawValue:
                streamingActive = true
                //print("frame ready")
                
                handleNals()
                EventHandler.shared.updateConnectionState(.connected)
                 
                 
             default:
                 print("msg")
             }
        }
        
        print("Events thread stopped")
    }
    
    func updateConnectionState(_ newState: ConnectionState) {
        if renderStarted || self.connectionState == newState {
            return
        }
        DispatchQueue.main.async {
            self.connectionState = newState
        }
    }

    func parseMessage(_ message: String) {
        let lines = message.components(separatedBy: "\n")
        for line in lines {
            if line.starts(with: "ALVR") {
                let split = line.split(separator: " ")
                if split.count == 2 {
                    updateVersion(split[1].trimmingCharacters(in: .whitespaces))
                    continue
                }
            }
            let keyValuePair = line.split(separator: ":")
            if keyValuePair.count == 2 {
                let key = keyValuePair[0].trimmingCharacters(in: .whitespaces)
                let value = keyValuePair[1].trimmingCharacters(in: .whitespaces)
                
                if key == "hostname" {
                    updateHostname(getHostname())
                } else if key == "IP" {
                    updateIP(value)
                }
            }
        }
    }

    func updateHostname(_ newHostname: String) {
        DispatchQueue.main.async {
            self.hostname = newHostname
        }
    }

    func updateIP(_ newIP: String) {
        DispatchQueue.main.async {
            self.IP = newIP
        }
    }

    func updateVersion(_ newVersion: String) {
        DispatchQueue.main.async {
            self.alvrVersion = newVersion
        }
    }
}

enum ConnectionState {
    case connected, disconnected, connecting
}

struct QueuedFrame {
    let imageBuffer: CVImageBuffer
    let timestamp: UInt64
    let viewParams: [AlvrViewParams]
}
