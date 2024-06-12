//
//  SampleHandler.swift
//  ALVREyeBroadcast
//
//  Created by Max Thomas on 6/11/24.
//

import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Lock the base address of the pixel buffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)

        // Access the pixel buffer data
        /*let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        print(CVPixelBufferGetPixelFormatType(pixelBuffer).description)*/
        
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
        processNV12PixelBufferData(yPlane: yPlane, yWidth: yWidth, yHeight: yHeight, yBytesPerRow: yBytesPerRow,
                                    uvPlane: uvPlane, uvWidth: uvWidth, uvHeight: uvHeight, uvBytesPerRow: uvBytesPerRow)

        // Unlock the base address of the pixel buffer
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        
        /*var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                               textureCache,
                                                               pixelBuffer,
                                                               nil,
                                                               .rgba8Unorm_srgb,
                                                               CVPixelBufferGetWidth(pixelBuffer),
                                                               CVPixelBufferGetHeight(pixelBuffer),
                                                               0,
                                                               &cvMetalTexture)
        
        guard status == kCVReturnSuccess, let metalTexture = CVMetalTextureGetTexture(cvMetalTexture!) else {
            print("Failed to create Metal texture")
            return
        }

        currentViewRecorded = metalTexture*/
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

    private func processNV12PixelBufferData(yPlane: UnsafeMutableRawPointer?, yWidth: Int, yHeight: Int, yBytesPerRow: Int,
                                        uvPlane: UnsafeMutableRawPointer?, uvWidth: Int, uvHeight: Int, uvBytesPerRow: Int) {
        guard let yPlane = yPlane, let uvPlane = uvPlane else { return }

        //print(yBytesPerRow, uvBytesPerRow)
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
            
            if gClamped < 230 {
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

            //if rClamped < 30 && gClamped > 240 && bClamped < 30 {
            if rClamped != 42 && gClamped != 42 && bClamped != 42 {
                //eyeXIdx = gClamped//Int((Float(x) / Float(yWidth)) * 255.0)
                //print("Pixel at (\(x), \(y)): R=\(rClamped), G=\(gClamped), B=\(bClamped)")
                //break
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
            
            if gClamped < 230 {
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

            //if rClamped < 30 && gClamped > 240 && bClamped < 30 {
            if rClamped != 42 && gClamped != 42 && bClamped != 42 {
                //eyeXIdx = gClamped//Int((Float(x) / Float(yWidth)) * 255.0)
                //print("Pixel at (\(x), \(y)): R=\(rClamped), G=\(gClamped), B=\(bClamped)")
                //break
            }
        }
        
        let xPred = largestXStart + ((largestXEnd - largestXStart) / 2)
        let yPred = largestYStart + ((largestYEnd - largestYStart) / 2)
        
        //let eyeXIdx = Int((Float(xPred) / Float(yWidth)) * Float(/*mipColorTextures2.count - 1*/ 255))
        //let eyeYIdx = Int((Float(yPred) / Float(yHeight)) * Float(/*mipColorTextures2.count - 1*/ 255))
        
        excavateValue(to: "X", val: Float(xPred) / Float(yWidth))
        excavateValue(to: "Y", val: Float(yPred) / Float(yHeight))
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
