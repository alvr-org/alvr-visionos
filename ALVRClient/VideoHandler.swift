//
//  VideoHandler.swift
//

import Foundation
import VideoToolbox

let H264_NAL_TYPE_SPS = 7
let HEVC_NAL_TYPE_VPS = 32

struct VideoHandler {
    // Useful for debugging.
    static let coreVideoPixelFormatToStr: [OSType:String] = [
        kCVPixelFormatType_128RGBAFloat: "128RGBAFloat",
        kCVPixelFormatType_14Bayer_BGGR: "BGGR",
        kCVPixelFormatType_14Bayer_GBRG: "GBRG",
        kCVPixelFormatType_14Bayer_GRBG: "GRBG",
        kCVPixelFormatType_14Bayer_RGGB: "RGGB",
        kCVPixelFormatType_16BE555: "16BE555",
        kCVPixelFormatType_16BE565: "16BE565",
        kCVPixelFormatType_16Gray: "16Gray",
        kCVPixelFormatType_16LE5551: "16LE5551",
        kCVPixelFormatType_16LE555: "16LE555",
        kCVPixelFormatType_16LE565: "16LE565",
        kCVPixelFormatType_16VersatileBayer: "16VersatileBayer",
        kCVPixelFormatType_1IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_1Monochrome: "1Monochrome",
        kCVPixelFormatType_24BGR: "24BGR",
        kCVPixelFormatType_24RGB: "24RGB",
        kCVPixelFormatType_2Indexed: "2Indexed",
        kCVPixelFormatType_2IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_30RGB: "30RGB",
        kCVPixelFormatType_30RGBLEPackedWideGamut: "30RGBLEPackedWideGamut",
        kCVPixelFormatType_32ABGR: "32ABGR",
        kCVPixelFormatType_32ARGB: "32ARGB",
        kCVPixelFormatType_32AlphaGray: "32AlphaGray",
        kCVPixelFormatType_32BGRA: "32BGRA",
        kCVPixelFormatType_32RGBA: "32RGBA",
        kCVPixelFormatType_40ARGBLEWideGamut: "40ARGBLEWideGamut",
        kCVPixelFormatType_40ARGBLEWideGamutPremultiplied: "40ARGBLEWideGamutPremultiplied",
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: "420YpCbCr10BiPlanarFullRange",
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: "420YpCbCr10BiPlanarVideoRange",
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: "420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: "420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_420YpCbCr8Planar: "420YpCbCr8Planar",
        kCVPixelFormatType_420YpCbCr8PlanarFullRange: "420YpCbCr8PlanarFullRange",
        kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar: "TriPlanar",
        kCVPixelFormatType_422YpCbCr10: "422YpCbCr10",
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: "422YpCbCr10BiPlanarFullRange",
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: "422YpCbCr10BiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr16: "422YpCbCr16",
        kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange: "422YpCbCr16BiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr8: "422YpCbCr8",
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: "422YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: "422YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr8FullRange: "422YpCbCr8FullRange",
        kCVPixelFormatType_422YpCbCr8_yuvs: "yuvs",
        kCVPixelFormatType_422YpCbCr_4A_8BiPlanar: "8BiPlanar",
        kCVPixelFormatType_4444AYpCbCr16: "4444AYpCbCr16",
        kCVPixelFormatType_4444AYpCbCr8: "4444AYpCbCr8",
        kCVPixelFormatType_4444YpCbCrA8: "4444YpCbCrA8",
        kCVPixelFormatType_4444YpCbCrA8R: "4444YpCbCrA8R",
        kCVPixelFormatType_444YpCbCr10: "444YpCbCr10",
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: "444YpCbCr10BiPlanarFullRange",
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: "444YpCbCr10BiPlanarVideoRange",
        kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange: "444YpCbCr16BiPlanarVideoRange",
        kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar: "TriPlanar",
        kCVPixelFormatType_444YpCbCr8: "444YpCbCr8",
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: "444YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: "444YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_48RGB: "48RGB",
        kCVPixelFormatType_4Indexed: "4Indexed",
        kCVPixelFormatType_4IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_64ARGB: "64ARGB",
        kCVPixelFormatType_64RGBAHalf: "64RGBAHalf",
        kCVPixelFormatType_64RGBALE: "64RGBALE",
        kCVPixelFormatType_64RGBA_DownscaledProResRAW: "DownscaledProResRAW",
        kCVPixelFormatType_8Indexed: "8Indexed",
        kCVPixelFormatType_8IndexedGray_WhiteIsZero: "WhiteIsZero",
        kCVPixelFormatType_ARGB2101010LEPacked: "ARGB2101010LEPacked",
        kCVPixelFormatType_DepthFloat16: "DepthFloat16",
        kCVPixelFormatType_DepthFloat32: "DepthFloat32",
        kCVPixelFormatType_DisparityFloat16: "DisparityFloat16",
        kCVPixelFormatType_DisparityFloat32: "DisparityFloat32",
        kCVPixelFormatType_Lossless_32BGRA: "32BGRA",
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange: "420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange: "420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange: "420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange: "422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossy_32BGRA: "32BGRA",
        kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange: "420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange: "420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange: "420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange: "422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_OneComponent10: "OneComponent10",
        kCVPixelFormatType_OneComponent12: "OneComponent12",
        kCVPixelFormatType_OneComponent16: "OneComponent16",
        kCVPixelFormatType_OneComponent16Half: "OneComponent16Half",
        kCVPixelFormatType_OneComponent32Float: "OneComponent32Float",
        kCVPixelFormatType_OneComponent8: "OneComponent8",
        kCVPixelFormatType_TwoComponent16: "TwoComponent16",
        kCVPixelFormatType_TwoComponent16Half: "TwoComponent16Half",
        kCVPixelFormatType_TwoComponent32Float: "TwoComponent32Float",
        kCVPixelFormatType_TwoComponent8: "TwoComponent8",
        
        // Internal formats?
        0x61766331: "NonDescriptH264",
        0x68766331: "NonDescriptHVC1"
    ]
    
    // Get bits per component for video format
    static func getBpcForVideoFormat(_ videoFormat: CMFormatDescription) -> Int {
        let bpcRaw = videoFormat.extensions["BitsPerComponent" as CFString]
        return (bpcRaw != nil ? bpcRaw as! NSNumber : 8).intValue
    }
    
    // Returns true if video format is full-range
    static func getIsFullRangeForVideoFormat(_ videoFormat: CMFormatDescription) -> Bool {
        let isFullVideoRaw = videoFormat.extensions["FullRangeVideo" as CFString]
        return ((isFullVideoRaw != nil ? isFullVideoRaw as! NSNumber : 0).intValue != 0)
    }
    
    // The Metal texture formats for each of the planes of a given CVPixelFormatType
    static func getTextureTypesForFormat(_ format: OSType) -> [MTLPixelFormat]
    {
        switch(format) {
            // 8-bit biplanar
            case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
                return [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm]

            // 10-bit biplanar
            case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
                return [MTLPixelFormat.r16Unorm, MTLPixelFormat.rg16Unorm]

            // Guess 8-bit biplanar otherwise
            default:
                let formatStr = coreVideoPixelFormatToStr[format, default: "unknown"]
                print("Warning: Pixel format \(formatStr) (\(format)) is not currently accounted for! Returning 8-bit vals")
                return [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm]
        }
    }

    static func pollNal() -> (Data, UInt64)? {
        let nalLength = alvr_poll_nal(nil, nil)
        if nalLength == 0 {
            return nil
        }
        let nalBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: Int(nalLength))
        defer { nalBuffer.deallocate() }
        var nalTimestamp:UInt64 = 0
        alvr_poll_nal(nalBuffer.baseAddress, &nalTimestamp)
        return (Data(buffer: nalBuffer), nalTimestamp)
    }
    
    static func abandonAllPendingNals() {
        while let _ = VideoHandler.pollNal() {}
    }
    
    static func createVideoDecoder(initialNals: Data, codec: Int) -> (VTDecompressionSession, CMFormatDescription) {
        let nalHeader:[UInt8] = [0x00, 0x00, 0x00, 0x01]
        var videoFormat:CMFormatDescription? = nil
        var err:OSStatus = 0
        
        // First two are the SPS and PPS
        // https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/sdk/objc/components/video_codec/nalu_rewriter.cc;l=228;drc=6f86f6af008176e631140e6a80e0a0bca9550143
        
        if (codec == H264_NAL_TYPE_SPS) {
            err = initialNals.withUnsafeBytes { (b:UnsafeRawBufferPointer) in
                let nalOffset0 = b.baseAddress!
                let nalOffset1 = memmem(nalOffset0 + 4, b.count - 4, nalHeader, nalHeader.count)!
                let nalLength0 = UnsafeRawPointer(nalOffset1) - nalOffset0 - 4
                let nalLength1 = b.baseAddress! + b.count - UnsafeRawPointer(nalOffset1) - 4

                let parameterSetPointers = [(nalOffset0 + 4).assumingMemoryBound(to: UInt8.self), UnsafeRawPointer(nalOffset1 + 4).assumingMemoryBound(to: UInt8.self)]
                let parameterSetSizes = [nalLength0, nalLength1]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: parameterSetPointers, parameterSetSizes: parameterSetSizes, nalUnitHeaderLength: 4, formatDescriptionOut: &videoFormat)
            } 
        } else if (codec == HEVC_NAL_TYPE_VPS) {
            let (vps, sps, pps) = extractParameterSets(from: initialNals)
            
            // Ensure parameterSetPointers is an array of non-optional UnsafePointer<UInt8>
            var parameterSetPointers: [UnsafePointer<UInt8>?] = []
            var parameterSetSizes: [Int] = []
            
            if let vps = vps {
                vps.withUnsafeBytes { rawBufferPointer in
                    if let baseAddress = rawBufferPointer.baseAddress {
                        let typedPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
                        parameterSetPointers.append(typedPointer)
                        parameterSetSizes.append(vps.count)
                    }
                }
            }
            
            if let sps = sps {
                sps.withUnsafeBytes { rawBufferPointer in
                    if let baseAddress = rawBufferPointer.baseAddress {
                        let typedPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
                        parameterSetPointers.append(typedPointer)
                        parameterSetSizes.append(sps.count)
                    }
                }
            }
            
            if let pps = pps {
                pps.withUnsafeBytes { rawBufferPointer in
                    if let baseAddress = rawBufferPointer.baseAddress {
                        let typedPointer = baseAddress.assumingMemoryBound(to: UInt8.self)
                        parameterSetPointers.append(typedPointer)
                        parameterSetSizes.append(pps.count)
                    }
                }
            }
            
            // Flatten parameterSetPointers to non-optional before passing to the function
            let nonOptionalParameterSetPointers = parameterSetPointers.compactMap { $0 }
            
            
            // nonOptionalParameterSetPointers is an array of UnsafePointer<UInt8>
            nonOptionalParameterSetPointers.withUnsafeBufferPointer { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                
                parameterSetSizes.withUnsafeBufferPointer { sizesBufferPointer in
                guard let sizesBaseAddress = sizesBufferPointer.baseAddress else { return }
                   
                    let parameterSetCount = [vps, sps, pps].compactMap { $0 }.count // Only count non-nil parameter sets
                    print("Parameter set count: \(parameterSetCount)")

                    let nalUnitHeaderLength: Int32 = 4 // Typically 4 for HEVC

                    parameterSetSizes.enumerated().forEach { index, size in
                        print("Parameter set \(index) size: \(size)")
                    }
                
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil,
                        parameterSetCount: parameterSetPointers.count,
                        parameterSetPointers: baseAddress,
                        parameterSetSizes: sizesBaseAddress,
                        nalUnitHeaderLength: nalUnitHeaderLength,
                        extensions: nil,
                        formatDescriptionOut: &videoFormat
                    )
                    
                    // Check if the format description was successfully created
                    if status == noErr, let _ = videoFormat {
                        // Use the format description
                        print("Successfully created CMVideoFormatDescription.")
                    } else {
                        print("Failed to create CMVideoFormatDescription.")
                    }
                }
                
            }
        }
            
        if err != 0 {
            fatalError("format?!")
        }
        print(videoFormat!)
        
        // We need our pixels unpacked for 10-bit so that the Metal textures actually work
        var pixelFormat:OSType? = nil
        let bpc = getBpcForVideoFormat(videoFormat!)
        let isFullRange = getIsFullRangeForVideoFormat(videoFormat!)
        
        // TODO: figure out how to check for 422/444, CVImageBufferChromaLocationBottomField?
        if bpc == 10 {
            pixelFormat = isFullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        
        let videoDecoderSpecification:[NSString: AnyObject] = [kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder:kCFBooleanTrue]
        var destinationImageBufferAttributes:[NSString: AnyObject] = [kCVPixelBufferMetalCompatibilityKey: true as NSNumber, kCVPixelBufferPoolMinimumBufferCountKey: 3 as NSNumber]
        if pixelFormat != nil {
            destinationImageBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat! as NSNumber
        }

        var decompressionSession:VTDecompressionSession? = nil
        err = VTDecompressionSessionCreate(allocator: nil, formatDescription: videoFormat!, decoderSpecification: videoDecoderSpecification as CFDictionary, imageBufferAttributes: destinationImageBufferAttributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &decompressionSession)
        if err != 0 {
            fatalError("format?!")
        }
        
        return (decompressionSession!, videoFormat!)
    }

    // Function to parse NAL units and extract VPS, SPS, and PPS data
    static func extractParameterSets(from nalData: Data) -> (vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?) {
        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        
        var index = 0
        while index < nalData.count - 4 {
            // Find the start code (0x00000001 or 0x000001)
            if nalData[index] == 0 && nalData[index + 1] == 0 && nalData[index + 2] == 0 && nalData[index + 3] == 1 {
                // NAL unit starts after the start code
                let nalUnitStartIndex = index + 4
                var nalUnitEndIndex = index + 4
                
                // Find the next start code to determine the end of this NAL unit
                for nextIndex in nalUnitStartIndex..<nalData.count - 4 {
                    if nalData[nextIndex] == 0 && nalData[nextIndex + 1] == 0 && nalData[nextIndex + 2] == 0 && nalData[nextIndex + 3] == 1 {
                        nalUnitEndIndex = nextIndex
                        break
                    }
                    nalUnitEndIndex = nalData.count // If no more start codes, this NAL unit goes to the end of the data
                }
                
                let nalUnitType = (nalData[nalUnitStartIndex] & 0x7E) >> 1 // Get NAL unit type (HEVC)
                let nalUnitData = nalData.subdata(in: nalUnitStartIndex..<nalUnitEndIndex)
                
                print("Switch nalUnitType of: \(nalUnitType)")
                switch nalUnitType {
                case 32: // VPS
                    vps = [UInt8](nalUnitData)
                case 33: // SPS
                    sps = [UInt8](nalUnitData)
                case 34: // PPS
                    pps = [UInt8](nalUnitData)
                default:
                    break
                }
                
                index = nalUnitEndIndex
            } else {
                index += 1 // Move to the next byte if start code not found
            }
        }
        
        return (vps, sps, pps)
    }



    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/common_video/h264/h264_common.cc
    private static func findNaluIndices(buffer: Data) -> [NaluIndex] {
        guard buffer.count >= /* kNaluShortStartSequenceSize */ 3 else {
            return []
        }
        
        var sequences = [NaluIndex]()
        
        let end = buffer.count - /* kNaluShortStartSequenceSize */ 3
        var i = 0
        while i < end {
            if buffer[i + 2] > 1 {
                i += 3
            } else if buffer[i + 2] == 1 {
                if buffer[i + 1] == 0 && buffer[i] == 0 {
                    var index = NaluIndex(startOffset: i, payloadStartOffset: i + 3, payloadSize: 0, threeByteHeader: true)
                    if index.startOffset > 0 && buffer[index.startOffset - 1] == 0 {
                        index.startOffset -= 1
                        index.threeByteHeader = false
                    }
                    
                    if !sequences.isEmpty {
                        sequences[sequences.count - 1].payloadSize = index.startOffset - sequences.last!.payloadStartOffset
                    }
                    
                    sequences.append(index)
                }
                
                i += 3
            } else {
                i += 1
            }
        }
        
        if !sequences.isEmpty {
            sequences[sequences.count - 1].payloadSize = buffer.count - sequences.last!.payloadStartOffset
        }
        
        return sequences
    }
    
    private struct NaluIndex {
        var startOffset: Int
        var payloadStartOffset: Int
        var payloadSize: Int
        var threeByteHeader: Bool
    }
    
    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    private static func annexBBufferToCMSampleBuffer(buffer: Data, videoFormat: CMFormatDescription) -> CMSampleBuffer {
        // no SPS/PPS, handled with the initial nals
        
        var err: OSStatus = 0
        
        let naluIndices = findNaluIndices(buffer: buffer)
        
        // we're replacing the 3/4 nalu headers with a 4 byte length, so add an extra byte on top of the original length for each 3-byte nalu header
        let blockBufferLength = buffer.count + naluIndices.filter(\.threeByteHeader).count
        let blockBuffer = try! CMBlockBuffer(length: blockBufferLength, flags: .assureMemoryNow)
        
        var contiguousBuffer: CMBlockBuffer!
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            err = CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousBuffer)
            if err != 0 {
                fatalError("CMBlockBufferCreateContiguous")
            }
        } else {
            contiguousBuffer = blockBuffer
        }
        
        var blockBufferSize = 0
        var dataPtr: UnsafeMutablePointer<Int8>!
        err = CMBlockBufferGetDataPointer(contiguousBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &blockBufferSize, dataPointerOut: &dataPtr)
        if err != 0 {
            fatalError("CMBlockBufferGetDataPointer")
        }
        
        dataPtr.withMemoryRebound(to: UInt8.self, capacity: blockBufferSize) { pointer in
            var offset = 0
            
            for index in naluIndices {
                pointer.advanced(by: offset    ).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >>  8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize      ) & 0xFF)
                offset += 4
                _ = UnsafeMutableBufferPointer(start: pointer.advanced(by: offset), count: blockBufferSize - offset).update(from: buffer[index.payloadStartOffset..<index.payloadStartOffset + index.payloadSize])
                offset += index.payloadSize
            }
        }
        
        var sampleBuffer: CMSampleBuffer!
        err = CMSampleBufferCreate(allocator: nil, dataBuffer: contiguousBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        if err != 0 {
            fatalError("CMSampleBufferCreate")
        }
        
        return sampleBuffer
    }
    
    static func feedVideoIntoDecoder(decompressionSession: VTDecompressionSession, nals: Data, timestamp: UInt64, videoFormat: CMFormatDescription, callback: @escaping (_ imageBuffer: CVImageBuffer?) -> Void) {
        var err:OSStatus = 0
        let sampleBuffer = annexBBufferToCMSampleBuffer(buffer: nals, videoFormat: videoFormat)
        err = VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer: sampleBuffer, flags: ._EnableAsynchronousDecompression, infoFlagsOut: nil) { (status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, taggedBuffers: [CMTaggedBuffer]?, presentationTimeStamp: CMTime, presentationDuration: CMTime) in
            //print(status, infoFlags, imageBuffer, taggedBuffers, presentationTimeStamp, presentationDuration)
            //print("status: \(status), image_nil?: \(imageBuffer == nil), infoFlags: \(infoFlags)")
            callback(imageBuffer)
        }
        if err != 0 {
            //fatalError("VTDecompressionSessionDecodeFrame")
        }
    }
}
