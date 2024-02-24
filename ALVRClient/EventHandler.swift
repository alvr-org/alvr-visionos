//
//  EventHandler.swift
//  ALVRClient
//
//

import Foundation
import Metal
import VideoToolbox
import Combine

class EventHandler: ObservableObject {
    static let shared = EventHandler()

    var eventsThread : Thread?
        
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
    var lastRequestedTimestamp: UInt64 = 0
    var lastSubmittedTimestamp: UInt64 = 0


    var framesSinceLastIDR:Int = 0
    var framesSinceLastDecode:Int = 0

    var streamEvent: AlvrEvent? = nil
    
    var framesRendered:Int = 0
    
    
    init() {}
    
    func initializeAlvr() {
        if !alvrInitialized {
            print("Initialize ALVR")
            alvrInitialized = true
            let refreshRates:[Float] = [90, 60, 45]
            alvr_initialize(/*java_vm=*/nil, /*context=*/nil, UInt32(1920*2), UInt32(1824*2), refreshRates, Int32(refreshRates.count), /*external_decoder=*/ true)
            alvr_resume()
        }
    }
    
    func start() {
        if !inputRunning {
            print("Starting event thread")
            inputRunning = true
            eventsThread = Thread {
                self.handleAlvrEvents()
            }
            eventsThread?.name = "Events Thread"
            eventsThread?.start()
        }
    }
    
    func stop() {
        print("Stopping")
        inputRunning = false
        renderStarted = false
        updateConnectionState(.disconnected)
        alvr_destroy()
        alvrInitialized = false
    }

    func handleAlvrEvents() {
        while inputRunning {
            var alvrEvent = AlvrEvent()
            let res = alvr_poll_event(&alvrEvent)
            if !res {
                usleep(1000)
                continue
            }
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
                streamEvent = alvrEvent
                streamingActive = true
                EventHandler.shared.updateConnectionState(.connected)
                alvr_request_idr()
                framesSinceLastIDR = 0
                framesSinceLastDecode = 0
            case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                print("streaming stopped")
                streamingActive = false
                EventHandler.shared.updateConnectionState(.disconnected)
                vtDecompressionSession = nil
                  videoFormat = nil
                  lastRequestedTimestamp = 0
                  lastSubmittedTimestamp = 0
                  framesRendered = 0
                  framesSinceLastIDR = 0
                  framesSinceLastDecode = 0
            case ALVR_EVENT_HAPTICS.rawValue:
                print("haptics: \(alvrEvent.HAPTICS)")
            case ALVR_EVENT_CREATE_DECODER.rawValue:
                print("create decoder \(alvrEvent.CREATE_DECODER)")
                // Don't reinstantiate the decoder if it's already created.
               // TODO: Switching from H264 -> HEVC at runtime?
                if vtDecompressionSession != nil {
                   continue
               }
               while alvrInitialized {
                   guard let (nal, timestamp) = VideoHandler.pollNal() else {
                       fatalError("create decoder: failed to poll nal?!")
                       break
                   }
                   NSLog("%@", nal as NSData)
                   let val = (nal[4] & 0x7E) >> 1
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
               //  print("frame ready")
                 
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
                    updateHostname(value)
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
