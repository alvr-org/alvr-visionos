//
//  EventHandler.swift
//

import Foundation
import Metal
import VideoToolbox
import Combine
import AVKit

class EventHandler: ObservableObject {
    static let shared = EventHandler()

    var eventsThread : Thread?
    var eventsWatchThread : Thread?
        
    var alvrInitialized = false
    var streamingActive = false
    
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var hostname: String = ""
    @Published var IP: String = ""
    
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

    var framesSinceLastIDR:Int = 0
    var framesSinceLastDecode:Int = 0

    var streamEvent: AlvrEvent? = nil
    
    var framesRendered:Int = 0
    var eventHeartbeat:Int = 0
    var lastEventHeartbeat:Int = -1
    
    var timeLastSentPeriodicUpdatedValues: Double = 0.0
    var timeLastAlvrEvent: Double = 0.0
    var timeLastFrameGot: Double = 0.0
    var timeLastFrameSent: Double = 0.0
    var numberOfEventThreadRestarts: Int = 0
    
    init() {}
    
    func initializeAlvr() {
        fixAudioForDirectStereo()
        if !alvrInitialized {
            print("Initialize ALVR")
            alvrInitialized = true
            let refreshRates:[Float] = [100, 96, 90]
            alvr_initialize(/*java_vm=*/nil, /*context=*/nil, UInt32(1920*2), UInt32(1824*2), refreshRates, Int32(refreshRates.count), /*supports_foveated_encoding=*/true, /*external_decoder=*/ true)
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

    func fixAudioForDirectStereo() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(true)
            try audioSession.setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
            try audioSession.setPreferredOutputNumberOfChannels(2)
            try audioSession.setIntendedSpatialExperience(.bypassed)
        } catch {
            print("Failed to set the audio session configuration?")
        }
    }
    
    func preventAudioCracklingOnExit() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setActive(false)
        } catch {
            print("Failed to set the audio session configuration?")
        }
    }

    // Data which only needs to be sent periodically, such as battery percentage
    func handlePeriodicUpdatedValues() {
        if !UIDevice.current.isBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging
        alvr_send_battery(WorldTracker.deviceIdHead, batteryLevel, isCharging)
        
        timeLastSentPeriodicUpdatedValues = CACurrentMediaTime()
    }
    
    func eventsWatchdog() {
        while true {
            if eventHeartbeat == lastEventHeartbeat {
                if renderStarted || numberOfEventThreadRestarts > 10 {
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
            lastEventHeartbeat = eventHeartbeat
            for _ in 0...5 {
                usleep(1000*1000)
            }
        }
    }
    
    func handleNals() {
        timeLastFrameGot = CACurrentMediaTime()
        while renderStarted {
            guard let (nal, timestamp) = VideoHandler.pollNal() else {
                break
            }

            //print("nal bytecount:", nal.count, "for ts:", timestamp)
            framesSinceLastIDR += 1

            // Don't submit NALs for decoding if we have already decoded a later frame
            objc_sync_enter(frameQueueLock)
            if timestamp < frameQueueLastTimestamp {
                //objc_sync_exit(frameQueueLock)
                //continue
            }

            // If we're receiving NALs timestamped from >400ms ago, stop decoding them
            // to prevent a cascade of needless decoding lag
            let ns_diff_from_last_req_ts = lastRequestedTimestamp > timestamp ? lastRequestedTimestamp &- timestamp : 0
            let lagSpiked = (ns_diff_from_last_req_ts > 1000*1000*600 && framesSinceLastIDR > 90*2)
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

                    alvr_report_frame_decoded(timestamp)
                    guard let imageBuffer = imageBuffer else {
                        return
                    }

                    //let imageBufferPtr = Unmanaged.passUnretained(imageBuffer).toOpaque()
                    //print("finish decode: \(timestamp), \(imageBufferPtr), \(nal_type)")

                    objc_sync_enter(frameQueueLock)
                    framesSinceLastDecode = 0
                    if frameQueueLastTimestamp != timestamp
                    {
                        // TODO: For some reason, really low frame rates seem to decode the wrong image for a split second?
                        // But for whatever reason this is fine at high FPS.
                        // From what I've read online, the only way to know if an H264 frame has actually completed is if
                        // the next frame is starting, so keep this around for now just in case.
                        if frameQueueLastImageBuffer != nil {
                            //frameQueue.append(QueuedFrame(imageBuffer: frameQueueLastImageBuffer!, timestamp: frameQueueLastTimestamp))
                            frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp))
                        }
                        else {
                            frameQueue.append(QueuedFrame(imageBuffer: imageBuffer, timestamp: timestamp))
                        }
                        if frameQueue.count > 2 {
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

    func handleAlvrEvents() {
        while inputRunning {
            eventHeartbeat += 1
            // Send periodic updated values, such as battery percentage, once every five seconds
            let currentTime = CACurrentMediaTime()
            if currentTime - timeLastSentPeriodicUpdatedValues >= 5.0 {
                handlePeriodicUpdatedValues()
            }
            
            let diffSinceLastEvent = currentTime - timeLastAlvrEvent
            let diffSinceLastNal = currentTime - timeLastFrameGot
            let diffSinceLastDecode = currentTime - timeLastFrameSent
            if (timeLastAlvrEvent != 0 && timeLastFrameGot != 0 && (diffSinceLastEvent >= 5.0 || diffSinceLastNal >= 5.0))
               || (renderStarted && timeLastFrameSent != 0 && (diffSinceLastDecode >= 5.0)) {
                EventHandler.shared.updateConnectionState(.disconnected)
                
                print("Kick ALVR...")
                print("diffSinceLastEvent:", diffSinceLastEvent)
                print("diffSinceLastNal:", diffSinceLastNal)
                print("diffSinceLastDecode:", diffSinceLastDecode)
                stop()
                alvrInitialized = false
                alvr_destroy()
                initializeAlvr()
                
                timeLastAlvrEvent = CACurrentMediaTime()
                timeLastFrameGot = CACurrentMediaTime()
                timeLastFrameSent = CACurrentMediaTime()
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
                let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                alvr_hud_message(hudMessageBuffer.baseAddress)
                let message = String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8)!
                parseMessage(message)
                print(message)
                hudMessageBuffer.deallocate()
            case ALVR_EVENT_STREAMING_STARTED.rawValue:
                print("streaming started \(alvrEvent.STREAMING_STARTED)")
                if !streamingActive {
                    streamEvent = alvrEvent
                    streamingActive = true
                    alvr_request_idr()
                    framesSinceLastIDR = 0
                    framesSinceLastDecode = 0
                    lastIpd = -1
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
                print("haptics: \(alvrEvent.HAPTICS)")
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
                   guard let (nal, _) = VideoHandler.pollNal() else {
                       fatalError("create decoder: failed to poll nal?!")
                       break
                   }
                   //NSLog("%@", nal as NSData)
                   //let val = (nal[4] & 0x7E) >> 1
                   if (nal[3] == 0x01 && nal[4] & 0x1f == H264_NAL_TYPE_SPS) || (nal[2] == 0x01 && nal[3] & 0x1f == H264_NAL_TYPE_SPS) {
                       // here we go!
                       (vtDecompressionSession, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nal, codec: H264_NAL_TYPE_SPS, setDisplayTo96Hz: WorldTracker.shared.settings.setDisplayTo96Hz)
                       break
                   } else if (nal[3] == 0x01 && (nal[4] & 0x7E) >> 1 == HEVC_NAL_TYPE_VPS) || (nal[2] == 0x01 && (nal[3] & 0x7E) >> 1 == HEVC_NAL_TYPE_VPS) {
                        // The NAL unit type is 32 (VPS)
                       (vtDecompressionSession, videoFormat) = VideoHandler.createVideoDecoder(initialNals: nal, codec: HEVC_NAL_TYPE_VPS, setDisplayTo96Hz: WorldTracker.shared.settings.setDisplayTo96Hz)
                       break
                   }
                }
            case ALVR_EVENT_FRAME_READY.rawValue:
                streamingActive = true
                //print("frame ready")
                EventHandler.shared.updateConnectionState(.connected)
                 
                handleNals()
                 
                 
             default:
                 print("msg")
             }
        }
        print("Events thread stopped")
    }
    
    func updateConnectionState(_ newState: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = newState
        }
    }

    func parseMessage(_ message: String) {
        let lines = message.components(separatedBy: "\n")
        for line in lines {
            let keyValuePair = line.split(separator: ":")
            if keyValuePair.count == 2 {
                let key = keyValuePair[0].trimmingCharacters(in: .whitespaces)
                let value = keyValuePair[1].trimmingCharacters(in: .whitespaces)
                
                if key == "hostname" {
                    updateHostname(value + ".alvr") // Hack: runtime needs to fix this D:
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

}

enum ConnectionState {
    case connected, disconnected, connecting
}

struct QueuedFrame {
    let imageBuffer: CVImageBuffer
    let timestamp: UInt64
}
