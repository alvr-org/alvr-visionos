//
//  SampleHandler.swift
//  ALVREyeBroadcast
//
//  Created by Max Thomas on 6/11/24.
//

import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {

    var isUsingMipmapMethod = true
    var lastHeartbeat = 0.0
    var lastSentHeartbeat = 0.0

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let us = Unmanaged<SampleHandler>.fromOpaque(observer!).takeUnretainedValue()
            us.isUsingMipmapMethod = false
            us.lastHeartbeat = CACurrentMediaTime()
            //NSLog("EYES: Using HoverEffect method")
        }, "EyeTrackingInfo_UseHoverEffectMethod" as CFString, nil, .deliverImmediately)
        CFNotificationCenterAddObserver(notificationCenter, Unmanaged.passUnretained(self).toOpaque(), { (center, observer, name, object, userInfo) in
            let us = Unmanaged<SampleHandler>.fromOpaque(observer!).takeUnretainedValue()
            us.isUsingMipmapMethod = true
            us.lastHeartbeat = CACurrentMediaTime()
            //NSLog("EYES: Using mipmap method")
        }, "EyeTrackingInfo_UseMipmapMethod" as CFString, nil, .deliverImmediately)

        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.
        /*let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMddHHmmss"
        dateFormatter.string(from: Date())
        let fileName = "ScreenRecord_\(dateFormatter.string(from: Date())).mp4"
        
        guard var fileFolder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.alvr.client.ALVR")?.path else {
            return
        }
        
        fileFolder = fileFolder + "/Library/Caches/video/"
        
        if !FileManager.default.fileExists(atPath: fileFolder) {
            try? FileManager.default.createDirectory(atPath: fileFolder, withIntermediateDirectories: true, attributes: nil)
        }
        let filePath = fileFolder + fileName
        
        SampleWriter.shared.filePath = filePath
        SampleWriter.shared.callBack = { [weak self] (result) in
            guard let strongSelf = self else { return }
            switch result {
            
            case .success:
                break
            case .failure(let error):
                let error = NSError(domain: "SampleHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "writer init error: \(error)"])
                strongSelf.finishBroadcastWithError(error)
            }
        }*/
    }
    
    override func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
    }
    
    override func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
    }
    
    override func broadcastFinished() {
        /*let condition = NSCondition()
        SampleWriter.shared.finishWriting { (error) in
            
            if let e = error {
                print("\(e)")
            } else {
                print("broadcastFinished success")
            }
            condition.signal()
        }
        condition.wait()*/
    }
    
    private func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Send a heartbeat back to the client, to let it know to activate the relevant overlays
        if CACurrentMediaTime() - self.lastSentHeartbeat >= 1.0 {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("EyeTrackingInfoServerHeartbeat" as CFString), nil, nil, true)
            self.lastSentHeartbeat = CACurrentMediaTime()
        }
        
        // If the client hasn't sent its heartbeat though, stop streaming.
        if self.lastHeartbeat != 0.0 && CACurrentMediaTime() - self.lastHeartbeat > 5.0 {
            let error = NSError(domain: "SampleHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "heartbeat timed out"])
            self.finishBroadcastWithError(error)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Lock the base address of the pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        
        // Access the luminance (Y) plane
        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let yWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        
        // Access the chrominance (UV) plane
        let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        // Process the pixel buffer data on the CPU
        if isUsingMipmapMethod {
            processNV12PixelBufferDataMipmap(yPlane: yPlane, yWidth: yWidth, yHeight: yHeight, yBytesPerRow: yBytesPerRow,
                                        uvPlane: uvPlane, uvWidth: uvWidth, uvHeight: uvHeight, uvBytesPerRow: uvBytesPerRow)
        }
        else {
            processNV12PixelBufferDataHoverEffect(yPlane: yPlane, yWidth: yWidth, yHeight: yHeight, yBytesPerRow: yBytesPerRow,
                                        uvPlane: uvPlane, uvWidth: uvWidth, uvHeight: uvHeight, uvBytesPerRow: uvBytesPerRow)
        }

        // Unlock the base address of the pixel buffer
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }
    
    private func excavateValue(to: String, val: Float) {
        var shift = val.bitPattern
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("EyeTrackingInfo" + to + "Start" as CFString), nil, nil, true)
        for _ in 0..<32 {
            if (shift & 1) != 0 {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("EyeTrackingInfo" + to + "1" as CFString), nil, nil, true)
            }
            else {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("EyeTrackingInfo" + to + "0" as CFString), nil, nil, true)
            }
            shift >>= 1
        }
    }

    private func processNV12PixelBufferDataMipmap(yPlane: UnsafeMutableRawPointer?, yWidth: Int, yHeight: Int, yBytesPerRow: Int,
                                        uvPlane: UnsafeMutableRawPointer?, uvWidth: Int, uvHeight: Int, uvBytesPerRow: Int) {
        guard let yPlane = yPlane, let uvPlane = uvPlane else { return }

        // Example processing: Log pixel data
        var largestXStart = 0
        var largestXEnd = 0
        var continuous = false
        var largestX = 0
        for x2 in 0..<yWidth {
            let y = 0
            let x = x2
            let yPixel = yPlane.load(fromByteOffset: y * yBytesPerRow + x, as: UInt8.self)
            let uvIndex = (y / 2) * uvBytesPerRow + (x / 2) * 2
            let uPixel = uvPlane.load(fromByteOffset: uvIndex, as: UInt8.self)
            let vPixel = uvPlane.load(fromByteOffset: uvIndex + 1, as: UInt8.self)

            // Convert YUV to RGB (this is a simple and not highly accurate conversion)
            let yValue = Float(yPixel)
            let uValue = Float(uPixel) - 128.0
            let vValue = Float(vPixel) - 128.0

            let r = yValue + 1.402 * vValue
            let g = yValue - 0.344136 * uValue - 0.714136 * vValue
            let b = yValue + 1.772 * uValue

            // Clamping the results to [0, 255]
            let rClamped = min(max(Int(r), 0), 255)
            let gClamped = min(max(Int(g), 0), 255)
            let bClamped = min(max(Int(b), 0), 255)
            
            if gClamped > 40 {
                continue
            }
            
            if bClamped > largestX {
                largestX = bClamped
                largestXStart = x
                continuous = true
            }
            if bClamped >= largestX && continuous {
                largestXEnd = x
            }
            else {
                continuous = false
            }
        }
        
        continuous = false
        var largestYStart = 0
        var largestYEnd = 0
        var largestY = 0
        for y2 in 0..<yHeight {
            let y = y2
            let x = yWidth-1
            let yPixel = yPlane.load(fromByteOffset: y * yBytesPerRow + x, as: UInt8.self)
            let uvIndex = (y / 2) * uvBytesPerRow + (x / 2) * 2
            let uPixel = uvPlane.load(fromByteOffset: uvIndex, as: UInt8.self)
            let vPixel = uvPlane.load(fromByteOffset: uvIndex + 1, as: UInt8.self)

            // Convert YUV to RGB (this is a simple and not highly accurate conversion)
            let yValue = Float(yPixel)
            let uValue = Float(uPixel) - 128.0
            let vValue = Float(vPixel) - 128.0

            let r = yValue + 1.402 * vValue
            let g = yValue - 0.344136 * uValue - 0.714136 * vValue
            let b = yValue + 1.772 * uValue

            // Clamping the results to [0, 255]
            let rClamped = min(max(Int(r), 0), 255)
            let gClamped = min(max(Int(g), 0), 255)
            let bClamped = min(max(Int(b), 0), 255)
            
            if gClamped > 40 {
                continue
            }
            
            if bClamped > largestY {
                largestY = bClamped
                largestYStart = y
                continuous = true
            }
            if bClamped >= largestY && continuous {
                largestYEnd = y
            }
            else {
                continuous = false
            }
        }
        
        let xPred = largestXStart + ((largestXEnd - largestXStart) / 2)
        let yPred = largestYStart + ((largestYEnd - largestYStart) / 2)
        
        //let eyeXIdx = Int((Float(xPred) / Float(yWidth)) * Float(/*mipColorTextures2.count - 1*/ 255))
        //let eyeYIdx = Int((Float(yPred) / Float(yHeight)) * Float(/*mipColorTextures2.count - 1*/ 255))
        
        var eyeXRaw = (Float(xPred) / Float(yWidth)) * 1.0
        var eyeYRaw = (1.0 - (Float(yPred) / Float(yHeight))) * 1.0
        
        // convert from 0.0~1.0 to -0.5~0.5
        var eyeXCentered = (eyeXRaw - 0.5)
        var eyeYCentered = (eyeYRaw - 0.5)
        
        // Fix it to match the HoverEffect tracking
        eyeXCentered *= 2.0
        eyeYCentered *= 2.0
        
        let eyeX = eyeXCentered + 0.5
        let eyeY = eyeYCentered + 0.5
        
        excavateValue(to: "X", val: eyeX)
        excavateValue(to: "Y", val: eyeY)
    }
    
    private func processNV12PixelBufferDataHoverEffect(yPlane: UnsafeMutableRawPointer?, yWidth: Int, yHeight: Int, yBytesPerRow: Int,
                                        uvPlane: UnsafeMutableRawPointer?, uvWidth: Int, uvHeight: Int, uvBytesPerRow: Int) {
        guard let yPlane = yPlane, let uvPlane = uvPlane else { return }


        let y = 80
        let x = yWidth-1
        let yPixel = yPlane.load(fromByteOffset: y * yBytesPerRow + x, as: UInt8.self)
        let uvIndex = (y / 2) * uvBytesPerRow + (x / 2) * 2
        let uPixel = uvPlane.load(fromByteOffset: uvIndex, as: UInt8.self)
        let vPixel = uvPlane.load(fromByteOffset: uvIndex + 1, as: UInt8.self)

        // Convert YUV to RGB (this is a simple and not highly accurate conversion)
        let yValue = Float(yPixel)
        let uValue = Float(uPixel) - 128.0
        let vValue = Float(vPixel) - 128.0

        let r = yValue + 1.402 * vValue
        let g = yValue - 0.344136 * uValue - 0.714136 * vValue
        let b = yValue + 1.772 * uValue

        // Clamping the results to [0, 255]
        let rClamped = min(max(r / 255.0, 0.0), 1.0)
        let gClamped = min(max(g / 255.0, 0.0), 1.0)
        let bClamped = min(max(b / 255.0, 0.0), 1.0)
        
        let xPred = rClamped
        let yPred = gClamped
        
        //let message = String(format: "EYES: %f %f", Float(xPred), Float(yPred))
        //NSLog(message)
        
        excavateValue(to: "X", val: Float(xPred))
        excavateValue(to: "Y", val: Float(yPred))
    }
    
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            // Handle video sample buffer
            processVideoSampleBuffer(sampleBuffer)
            //SampleWriter.shared.write(videoBuffer: sampleBuffer)
            break
        case RPSampleBufferType.audioApp:
            // Handle audio sample buffer for app audio
            //SampleWriter.shared.write(audioBuffer: sampleBuffer, audioSource: .app)
            break
        case RPSampleBufferType.audioMic:
            // Handle audio sample buffer for mic audio
            //SampleWriter.shared.write(audioBuffer: sampleBuffer, audioSource: .mic)
            break
        @unknown default:
            // Handle other sample buffer types
            fatalError("Unknown type of sample buffer")
        }
    }
}
