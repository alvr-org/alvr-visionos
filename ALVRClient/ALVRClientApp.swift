//
//  App.swift
//

import SwiftUI
#if os(visionOS)
import CompositorServices
#endif
import VideoToolbox

#if os(visionOS)
struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb
    
        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled
        
        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)
        
        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
    }
}
#endif

#if os(visionOS)
@main
struct MetalRendererApp: App {
    var body: some Scene {
#if false
        WindowGroup {
            ContentView()
        }.windowStyle(.volumetric)
#endif
        ImmersiveSpace {
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = Renderer(layerRenderer)
                renderer.startRenderLoop()
            }
        }
    }
}
#endif

#if false && !os(visionOS)
@main
struct Main {
    static func main() {
        let refreshRates:[Float] = [60]
        alvr_initialize(nil, nil, 1024, 1024, refreshRates, Int32(refreshRates.count), true)
        alvr_resume()
        print("alvr resume!")
        var alvrEvent = AlvrEvent()
        while true {
            let res = alvr_poll_event(&alvrEvent)
            if res {
                print(alvrEvent.tag)
                switch UInt32(alvrEvent.tag) {
                case ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue:
                        print("hud message updated")
                    let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                    alvr_hud_message(hudMessageBuffer.baseAddress)
                    print(String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8))
                    hudMessageBuffer.deallocate()
                case ALVR_EVENT_STREAMING_STARTED.rawValue:
                    print("streaming started: \(alvrEvent.STREAMING_STARTED)")
                case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                    print("streaming stopped")
                case ALVR_EVENT_HAPTICS.rawValue:
                    print("haptics: \(alvrEvent.HAPTICS)")
                case ALVR_EVENT_CREATE_DECODER.rawValue:
                    print("create decoder: \(alvrEvent.CREATE_DECODER)")
                case ALVR_EVENT_FRAME_READY.rawValue:
                    print("frame ready")
                default:
                    print("what")
                }
            }
            usleep(100000)
        }
    }
}
#endif

#if true && !os(visionOS)
@main
struct Main {
    static var theFrameData:Data!
    static func main() {
        let videoData = try! Data(contentsOf: URL(fileURLWithPath: "/Users/zhuowei/Documents/Projects/ALVRClient/recording.2024-02-03.20-50-26.h264"))
        let nalHeader:[UInt8] = [0x00, 0x00, 0x00, 0x01]
        let nalHeaderShort:[UInt8] = [0x00, 0x00, 0x01]
        let firstTwoNalsAndRest:[Data] = videoData.withUnsafeBytes { (b:UnsafeRawBufferPointer) in
            let nalOffset0 = b.baseAddress!
            let nalOffset1 = memmem(nalOffset0 + 4, b.count - 4, nalHeader, nalHeader.count)!
            let nalLength0 = UnsafeRawPointer(nalOffset1) - nalOffset0
            let nalOffset2 = memmem(nalOffset1 + 4, b.count - (nalLength0 + 4), nalHeaderShort, nalHeaderShort.count)!
            let nalLength1 = UnsafeRawPointer(nalOffset2) - UnsafeRawPointer(nalOffset1)
            
            // TODO(zhuowei): lol fix this
            
            let nalOffset3 = memmem(nalOffset2 + 4, b.count - (nalLength0 + nalLength1 + 4), nalHeader, nalHeader.count)!
            let nalLength2 = UnsafeRawPointer(nalOffset3) - UnsafeRawPointer(nalOffset2)
            return [Data(bytes: nalOffset0, count: nalLength0), Data(bytes: nalOffset1, count: nalLength1), Data(bytes: nalOffset2, count: nalLength2)]
        }
        
        // First two are the SPS and PPS
        // https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/sdk/objc/components/video_codec/nalu_rewriter.cc;l=228;drc=6f86f6af008176e631140e6a80e0a0bca9550143
        
        var videoFormat:CMFormatDescription? = nil
        var err:OSStatus = 0
        err = firstTwoNalsAndRest[0].withUnsafeBytes { a in
            firstTwoNalsAndRest[1].withUnsafeBytes { b in
                let parameterSetPointers = [unsafeBitCast(a.baseAddress! + 4, to: UnsafePointer<UInt8>.self), unsafeBitCast(b.baseAddress! + 4, to: UnsafePointer<UInt8>.self)]
                let parameterSetSizes = [a.count - 4, b.count - 4]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: parameterSetPointers, parameterSetSizes: parameterSetSizes, nalUnitHeaderLength: 4, formatDescriptionOut: &videoFormat)
            }
        }


        if err != 0 {
            fatalError("format?!")
        }
        print(videoFormat)
        
        let videoDecoderSpecification:[NSString: AnyObject] = [:]
        let destinationImageBufferAttributes:[NSString: AnyObject] = [:]

        var decompressionSession:VTDecompressionSession? = nil
        err = VTDecompressionSessionCreate(allocator: nil, formatDescription: videoFormat!, decoderSpecification: videoDecoderSpecification as CFDictionary, imageBufferAttributes: destinationImageBufferAttributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &decompressionSession)
        if err != 0 {
            fatalError("format?!")
        }
        print(decompressionSession)
        
        guard let decompressionSession = decompressionSession else {
            fatalError("fail")
        }
        
        var sampleBuffer:CMSampleBuffer? = nil
        theFrameData = firstTwoNalsAndRest[2]
        let nalLen = theFrameData.count - 4
        theFrameData[0] = UInt8((nalLen >> 24) & 0xff);
        theFrameData[1] = UInt8((nalLen >> 16) & 0xff);
        theFrameData[2] = UInt8((nalLen >> 8) & 0xff);
        theFrameData[3] = UInt8(nalLen & 0xff);

        theFrameData!.withUnsafeBytes {
            let contiguousBuffer1 = try! CMBlockBuffer(buffer: UnsafeMutableRawBufferPointer(mutating: $0))
            var contiguousBuffer:CMBlockBuffer! = nil
            CMBlockBufferCreateWithBufferReference(allocator: nil, referenceBuffer: contiguousBuffer1, offsetToData: 4, dataLength: $0.count - 4, flags: 0, blockBufferOut: &contiguousBuffer)
            print(contiguousBuffer)
            
            err = CMSampleBufferCreate(allocator: nil, dataBuffer: contiguousBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        }
        guard let sampleBuffer = sampleBuffer else {
            fatalError("sampleBuffer")
        }
        VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer: sampleBuffer, flags: ._EnableAsynchronousDecompression, infoFlagsOut: nil) { (status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, taggedBuffers: [CMTaggedBuffer]?, presentationTimeStamp: CMTime, presentationDuration: CMTime) in
            print(status, infoFlags, imageBuffer, taggedBuffers, presentationTimeStamp, presentationDuration)
        }
        CFRunLoopRun()
    }
}
#endif
