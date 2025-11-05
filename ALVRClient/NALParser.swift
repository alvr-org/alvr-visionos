//
//  NALParser.swift
//  ALVRClient
//
//  Created by Max Thomas on 11/4/25.
//

let H264_NAL_TYPE_SPS = 7
let HEVC_NAL_TYPE_VPS: UInt8 = 32
let HEVC_NAL_TYPE_SPS: UInt8 = 33
let HEVC_NAL_TYPE_PPS: UInt8 = 34
let HEVC_NAL_TYPE_SEI: UInt8 = 39

public struct NaluIndex {
    var startOffset: Int
    var payloadStartOffset: Int
    var payloadSize: Int
    var threeByteHeader: Bool
}

// Function to parse NAL units and extract VPS, SPS, PPS, and SEI data
public func extractParameterSets(from nalData: UnsafeMutableBufferPointer<UInt8>) -> (vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?, sei: [UInt8]?) {
    var vps: [UInt8]?
    var sps: [UInt8]?
    var pps: [UInt8]?
    var sei: [UInt8]? // = [0x4E, 0x01, 0x88, 0x06, 0,0,0,0,0, 0x10, 0x80]
    
    let nalDataNoBounds = nalData.baseAddress!
    
    var index = 0
    while index < nalData.count - 4 {
        // Find the start code (0x00000001 or 0x000001)
        if nalDataNoBounds[index] == 0 && nalDataNoBounds[index + 1] == 0 && nalDataNoBounds[index + 2] == 0 && nalDataNoBounds[index + 3] == 1 {
            // NAL unit starts after the start code
            let nalUnitStartIndex = index + 4
            var nalUnitEndIndex = index + 4
            
            // Find the next start code to determine the end of this NAL unit
            for nextIndex in nalUnitStartIndex..<nalData.count - 4 {
                if nalDataNoBounds[nextIndex] == 0 && nalDataNoBounds[nextIndex + 1] == 0 && nalDataNoBounds[nextIndex + 2] == 0 && nalDataNoBounds[nextIndex + 3] == 1 {
                    nalUnitEndIndex = nextIndex
                    break
                }
                nalUnitEndIndex = nalData.count // If no more start codes, this NAL unit goes to the end of the data
            }
            
            let nalUnitType = (nalDataNoBounds[nalUnitStartIndex] & 0x7E) >> 1 // Get NAL unit type (HEVC)
            let nalUnitData = nalData.extracting(nalUnitStartIndex..<nalUnitEndIndex)
            
            print("Switch nalUnitType of: \(nalUnitType)")
            switch nalUnitType {
            case HEVC_NAL_TYPE_VPS:
                vps = [UInt8](nalUnitData)
            case HEVC_NAL_TYPE_SPS:
                sps = [UInt8](nalUnitData)
            case HEVC_NAL_TYPE_PPS:
                pps = [UInt8](nalUnitData)
            case HEVC_NAL_TYPE_SEI:
                sei = [UInt8](nalUnitData)
            default:
                break
            }
            
            index = nalUnitEndIndex
        } else {
            index += 1 // Move to the next byte if start code not found
        }
    }
    
    return (vps, sps, pps, sei)
}



// Based on https://webrtc.googlesource.com/src/+/refs/heads/main/common_video/h264/h264_common.cc
public func findNaluIndices(bufferBounded: UnsafeMutableBufferPointer<UInt8>) -> ([NaluIndex], Bool) {
    var elgibleForModifyInPlace = true
    guard bufferBounded.count >= /* kNaluShortStartSequenceSize */ 3 else {
        return ([], false)
    }
    
    var sequences = [NaluIndex]()
    
    let end = bufferBounded.count - /* kNaluShortStartSequenceSize */ 3
    var i = 0
    let buffer = Data(bytesNoCopy: bufferBounded.baseAddress!, count: bufferBounded.count, deallocator: .none) // ?? why is this faster
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
                else {
                    elgibleForModifyInPlace = false
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
        sequences[sequences.count - 1].payloadSize = bufferBounded.count - sequences.last!.payloadStartOffset
    }
    
    return (sequences, elgibleForModifyInPlace)
}
