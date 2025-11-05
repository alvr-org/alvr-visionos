//
//  AV1Parser.swift
//
// I gotta be real, I ChatGPT'd like 70% of this.
// Of course, it didn't work and I had to parse the bitstream by hand anyway,
// but it at least left some nice comments on the AV1 atoms.
//
// Everyone has my (Max T's) personal permission to use this file specifically,
// with or without attribution, bc nobody deserves to parse bitstream video formats.
// But attribution would be nice if this saved you some time.
//

import Foundation
import CoreMedia

public enum AV1FormatDescriptionError: Error {
    case sequenceHeaderNotFound
    case parseFailed(String)
    case cmCreationFailed(OSStatus)
}

/// Struct of the parsed info we need for av1C + dimensions
fileprivate struct AV1SequenceInfo {
    var seq_profile: Int
    var seq_level_idx_0: Int
    var seq_tier_0: Int
    var high_bitdepth: Int
    var twelve_bit: Int
    var monochrome: Int
    var chroma_subsampling_x: Int
    var chroma_subsampling_y: Int
    var chroma_sample_position: Int
    var initial_presentation_delay_present: Int
    var initial_presentation_delay_minus_one: Int // valid only if present==1
    var width: Int
    var height: Int
    var bitsPerComponent: Int
    var isFullRange: Bool
    var colorPrimaries: Int
    var transferCharacteristics: Int
    var matrixCoefficients: Int
}

let CSP_UNKNOWN = 0
let CSP_VERTICAL = 1
let CSP_COLOCATED = 2
let CSP_RESERVED = 3

// Color Profile Constants
let CP_BT_709 	    = 1  // BT.709
let CP_UNSPECIFIED  = 2  // Unspecified
let CP_BT_470_M     = 4  // BT.470 System M (historical)
let CP_BT_470_B_G   = 5  // BT.470 System B, G (historical)
let CP_BT_601 	    = 6  // BT.601
let CP_SMPTE_240 	= 7  // SMPTE 240
let CP_GENERIC_FILM = 8  // Generic film (color filters using illuminant C)
let CP_BT_2020 	    = 9  // BT.2020, BT.2100
let CP_XYZ          = 10 // SMPTE 428 (CIE 1921 XYZ)
let CP_SMPTE_431 	= 11 // SMPTE RP 431-2
let CP_SMPTE_432 	= 12 // SMPTE EG 432-1
let CP_EBU_3213 	= 22 // EBU Tech. 3213-E

// Transfer Encoding Constants
let TC_RESERVED_0 	    = 0 //For future use
let TC_BT_709 	        = 1 //BT.709
let TC_UNSPECIFIED 	    = 2 //Unspecified
let TC_RESERVED_3 	    = 3 //For future use
let TC_BT_470_M 	    = 4 //BT.470 System M (historical)
let TC_BT_470_B_G 	    = 5 //BT.470 System B, G (historical)
let TC_BT_601 	        = 6 //BT.601
let TC_SMPTE_240 	    = 7 //SMPTE 240 M
let TC_LINEAR 	        = 8 //Linear
let TC_LOG_100 	        = 9 //Logarithmic (100 : 1 range)
let TC_LOG_100_SQRT10 	= 10 //Logarithmic (100 * Sqrt(10) : 1 range)
let TC_IEC_61966 	    = 11 //IEC 61966-2-4
let TC_BT_1361 	        = 12 //BT.1361
let TC_SRGB 	        = 13 //sRGB or sYCC
let TC_BT_2020_10_BIT 	= 14 //BT.2020 10-bit systems
let TC_BT_2020_12_BIT 	= 15 //BT.2020 12-bit systems
let TC_SMPTE_2084 	    = 16 //SMPTE ST 2084, ITU BT.2100 PQ
let TC_SMPTE_428 	    = 17 //SMPTE ST 428
let TC_HLG 	            = 18 //BT.2100 HLG, ARIB STD-B67

let MC_IDENTITY 	    = 0 // Identity matrix
let MC_BT_709 	        = 1 // BT.709
let MC_UNSPECIFIED 	    = 2 // Unspecified
let MC_RESERVED_3 	    = 3 // For future use
let MC_FCC 	            = 4 // US FCC 73.628
let MC_BT_470_B_G 	    = 5 // BT.470 System B, G (historical)
let MC_BT_601 	        = 6 // BT.601
let MC_SMPTE_240 	    = 7 // SMPTE 240 M
let MC_SMPTE_YCGCO 	    = 8 // YCgCo
let MC_BT_2020_NCL 	    = 9 // BT.2020 non-constant luminance, BT.2100 YCbCr
let MC_BT_2020_CL 	    = 10 // BT.2020 constant luminance
let MC_SMPTE_2085 	    = 11 // SMPTE ST 2085 YDzDx
let MC_CHROMAT_NCL 	    = 12 // Chromaticity-derived non-constant luminance
let MC_CHROMAT_CL 	    = 13 // Chromaticity-derived constant luminance
let MC_ICTCP 	        = 14 // BT.2100 ICtCp

// MARK: - Public API

/// Create a CMVideo/CMFormatDescription for AV1 from concatenated OBUs,
/// building and attaching an `av1C` payload into the SampleDescriptionExtensionAtoms.
/// Throws on failure.
public func CMVideoFormatDescriptionCreateFromAV1SequenceHeaderOBUWithAV1C(_ obuData: UnsafeMutableBufferPointer<UInt8>) throws -> CMFormatDescription {
    // 1) Find the sequence header OBU range in the buffer
    guard let seqRange = findSequenceHeaderOBURange(in: obuData) else {
        throw AV1FormatDescriptionError.sequenceHeaderNotFound
    }

    // 2) Extract the payload range (strip header + optional leb128)
    let (payloadRange, origObuHasSizeField, originalObuSlice) = try extractOBUPayloadInfo(in: obuData, obuRange: seqRange)

    /*print(seqRange, payloadRange, origObuHasSizeField, originalObuSlice)
    var s = ""
    for b in 0..<obuData.count {
        s += "\(String(obuData[b], radix: 16, uppercase: true)) "
    }
    print(s)*/

    // 3) Parse sequence header payload for both dims and av1C-related fields
    let seqPayload = obuData.extracting(payloadRange)
    let seqInfo = try parseSequenceHeaderForAv1CAndDimensions(seqPayload)
    
    /*s = ""
    for b in 0..<seqPayload.count {
        s += "\(String(seqPayload[b], radix: 16, uppercase: true)) "
    }
    print(seqInfo)
    print(s)*/

    // 4) Normalize sequence OBU bytes so configOBUs contains an OBU with obu_has_size_field == 1
    // If the original OBU had size field already, prefer copying the exact bytes from the input (header + leb128 + payload).
    // Otherwise, build a synthetic OBU header with obu_has_size_field=1 + leb128 payload size + payload.
    let configObuBytes: Data
    if origObuHasSizeField {
        // We expect originalObuSlice to contain header + leb128 + payload
        configObuBytes = Data(originalObuSlice)
    } else {
        // Build new OBU with size field set to 1
        let payload = seqPayload
        var headerByte: UInt8 = 0
        // obu_forbidden (1 bit) = 0, obu_type (4 bits) = 1 (sequence header), obu_extension_flag = 0, obu_has_size_field = 1, obu_reserved = 0
        // header layout (MSB->LSB): forbidden(1), obu_type(4), obu_extension_flag(1), obu_has_size_field(1), reserved(1)
        headerByte = (0 << 7) | ((1 & 0x0F) << 3) | (0 << 2) | (1 << 1) | (0)
        var rebuilt = Data([headerByte])
        // no extension byte
        // append leb128 size of payload
        rebuilt.append(contentsOf: encodeUnsignedLEB128(UInt64(payload.count)))
        // append payload
        rebuilt.append(Data(payload))
        configObuBytes = rebuilt
    }

    // 5) Build av1C payload (AV1CodecConfigurationRecord per spec)
    let av1Cpayload = buildAV1CodecConfigurationRecord(seqInfo: seqInfo, configOBUs: configObuBytes)

    // 6) Create CMVideoFormatDescription with av1C in the SampleDescriptionExtensionAtoms
    var formatDesc: CMFormatDescription?
    let codecType = kCMVideoCodecType_AV1

    // Build the atoms dictionary: key=FourCC string "av1C" (CFString), value=CFData of av1C payload
    let atomsKey = "av1C" as CFString
    let atomsValue = av1Cpayload as CFData
    let atomsDict = [atomsKey: atomsValue] as CFDictionary
    
    let cpMap: [Int: CFString] = [
        CP_BT_709 : kCVImageBufferColorPrimaries_ITU_R_709_2,
        CP_BT_2020 : kCVImageBufferColorPrimaries_ITU_R_2020,
        CP_BT_601 : kCVImageBufferColorPrimaries_DCI_P3,
    ];
    let tcMap: [Int: CFString] = [
        TC_BT_709 : kCVImageBufferTransferFunction_ITU_R_709_2,
        TC_BT_2020_10_BIT : kCVImageBufferTransferFunction_ITU_R_2020,
        TC_BT_2020_12_BIT : kCVImageBufferTransferFunction_ITU_R_2020,
        TC_BT_601 : kCVImageBufferTransferFunction_sRGB,
        TC_SRGB : kCVImageBufferTransferFunction_sRGB,
    ];
    let mMap: [Int: CFString] = [
        MC_BT_709 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        MC_BT_2020_NCL : kCVImageBufferYCbCrMatrix_ITU_R_2020,
        MC_BT_2020_CL : kCVImageBufferYCbCrMatrix_ITU_R_2020,
        MC_BT_601 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
    ];
    
    // I populate all this just to be consistent with the other codecs tbh
    var extensions:[NSString: AnyObject] = [:]
    extensions[kCMFormatDescriptionExtension_BitsPerComponent] = seqInfo.bitsPerComponent as NSNumber
    extensions[kCMFormatDescriptionExtension_FieldCount] = 1 as NSNumber
    extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField] = kCVImageBufferChromaLocation_Left // TODO: check chroma_x for 1
    extensions[kCMFormatDescriptionExtension_ChromaLocationTopField] = kCVImageBufferChromaLocation_Left // TODO: check chroma_y for 1
    extensions[kCMFormatDescriptionExtension_ColorPrimaries] = cpMap[seqInfo.colorPrimaries, default: kCVImageBufferColorPrimaries_ITU_R_709_2]
    extensions[kCMFormatDescriptionExtension_TransferFunction] = tcMap[seqInfo.transferCharacteristics, default: kCVImageBufferTransferFunction_ITU_R_709_2]
    extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = mMap[seqInfo.matrixCoefficients, default: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
    extensions[kCMFormatDescriptionExtension_Depth] = (seqInfo.bitsPerComponent * 3) as NSNumber
    extensions[kCMFormatDescriptionExtension_FormatName] = "av01" as NSString
    extensions[kCMFormatDescriptionExtension_FullRangeVideo] = seqInfo.isFullRange as NSNumber
    extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atomsDict as CFDictionary

    // Create the format description with width/height
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: codecType,
        width: Int32(seqInfo.width),
        height: Int32(seqInfo.height),
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &formatDesc
    )

    guard status == noErr, let fd = formatDesc else {
        throw AV1FormatDescriptionError.cmCreationFailed(status)
    }
    return fd
}

// MARK: - Sequence header discovery & payload extraction (returns also raw OBU bytes slice if possible)

fileprivate let OBU_SEQUENCE_HEADER: UInt8 = 1

/// Walk the input Data containing concatenated OBUs, returning the Range covering the *full* OBU (header + optional ext + optional size + payload)
fileprivate func findSequenceHeaderOBURange(in data: UnsafeMutableBufferPointer<UInt8>) -> Range<Int>? {
    let bytes = [UInt8](data)
    var i = 0
    while i < bytes.count {
        // header min 1 byte
        if i >= bytes.count { break }
        let headerByte = bytes[i]
        let obuForbidden = (headerByte >> 7) & 0x1
        if obuForbidden != 0 {
            i += 1
            continue
        }
        let obuType = (headerByte >> 3) & 0x0F
        let obuExtensionFlag = (headerByte >> 2) & 0x01
        let obuHasSize = (headerByte >> 1) & 0x01

        var offset = i + 1
        if obuExtensionFlag == 1 {
            // extension byte present
            guard offset < bytes.count else { break }
            offset += 1
        }

        var payloadSize: Int? = nil
        if obuHasSize == 1 {
            let (val, len) = readUnsignedLEB128(bytes: bytes, index: offset)
            if len == 0 { break } // malformed
            payloadSize = Int(val)
            offset += len
        } else {
            // no explicit size; scan for next OBU header (heuristic)
            var nextHeader: Int? = nil
            var scan = offset
            while scan < bytes.count {
                if ((bytes[scan] >> 7) & 0x1) == 0 {
                    nextHeader = scan
                    break
                }
                scan += 1
            }
            let endIndex = nextHeader ?? bytes.count
            payloadSize = endIndex - offset
        }

        guard let psize = payloadSize else { break }
        let obuTotalEnd = offset + psize
        if obuTotalEnd > bytes.count { break }
        let fullRange = i ..< obuTotalEnd
        if obuType == OBU_SEQUENCE_HEADER {
            return fullRange
        }
        i = obuTotalEnd
    }
    return nil
}

/// Returns: (payloadRange, origObuHasSizeField, originalObuSlice (header+leb128+payload) if available)
fileprivate func extractOBUPayloadInfo(in data: UnsafeMutableBufferPointer<UInt8>, obuRange: Range<Int>) throws -> (Range<Int>, Bool, UnsafeMutableBufferPointer<UInt8>) {
    let bytes = [UInt8](data)
    let start = obuRange.lowerBound
    let headerByte = bytes[start]
    let obuExtensionFlag = (headerByte >> 2) & 0x01
    let obuHasSize = (headerByte >> 1) & 0x01

    var offset = start + 1
    if obuExtensionFlag == 1 {
        guard offset < bytes.count else { throw AV1FormatDescriptionError.parseFailed("missing extension byte") }
        offset += 1
    }

    if obuHasSize == 1 {
        let (_, len) = readUnsignedLEB128(bytes: bytes, index: offset)
        if len == 0 { throw AV1FormatDescriptionError.parseFailed("malformed leb128 in OBU") }
        offset += len
        let payloadEnd = obuRange.upperBound
        if offset > payloadEnd { throw AV1FormatDescriptionError.parseFailed("payload offset > end") }
        // original OBU slice includes header + leb128 + payload
        let originalSlice = data.extracting(start..<payloadEnd)
        return (offset..<payloadEnd, true, originalSlice)
    } else {
        // no size field: payload runs from offset ..< obuRange.upperBound
        let payloadEnd = obuRange.upperBound
        let originalSlice = data.extracting(start..<payloadEnd) // header + payload (no leb128)
        return (offset..<payloadEnd, false, originalSlice)
    }
}

// Read unsigned LEB128 from bytes[index...] returning (value,length).
fileprivate func readUnsignedLEB128(bytes: [UInt8], index: Int) -> (UInt64, Int) {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    var i = index
    while i < bytes.count {
        let b = bytes[i]
        value |= UInt64(b & 0x7F) << shift
        if (b & 0x80) == 0 {
            return (value, i - index + 1)
        }
        shift += 7
        i += 1
        if shift > 63 { return (0, 0) }
    }
    return (0, 0)
}

fileprivate func encodeUnsignedLEB128(_ v: UInt64) -> [UInt8] {
    var value = v
    var out = [UInt8]()
    while true {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 {
            byte |= 0x80
            out.append(byte)
        } else {
            out.append(byte)
            break
        }
    }
    return out
}

// MARK: - BitReader & Sequence Header parser for av1C fields + dimensions

fileprivate struct BitReader {
    let bytes: UnsafeMutableBufferPointer<UInt8>
    var bitOffset: Int = 0
    init(_ data: UnsafeMutableBufferPointer<UInt8>) { self.bytes = data }
    mutating func readBit() -> Int {
        guard bitOffset / 8 < bytes.count else { return 0 }
        let byteIndex = bitOffset / 8
        let bitIndex = 7 - (bitOffset % 8)
        let bit = Int((bytes[byteIndex] >> bitIndex) & 1)
        bitOffset += 1
        return bit
    }
    mutating func readBits(_ n: Int) -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<n {
            v = (v << 1) | UInt32(readBit())
        }
        return v
    }
    mutating func readUVLC() -> UInt32 {
        var leadingZeros = 0
        // Read bits until a one is encountered; note: readBit() consumes bits
        while leadingZeros < 32 && readBit() == 0 {
            leadingZeros += 1
        }
        if leadingZeros == 32 { return UInt32.max }
        var val: UInt32 = 0
        for _ in 0..<leadingZeros {
            val = (val << 1) | UInt32(readBit())
        }
        let base = (1 << leadingZeros) - 1
        return UInt32(base) + val
    }
    mutating func byteAlign() {
        let mod = bitOffset % 8
        if mod != 0 { bitOffset += (8 - mod) }
    }
}

// See also: https://aomediacodec.github.io/av1-spec/#sequence-header-obu-syntax
fileprivate func parseSequenceHeaderForAv1CAndDimensions(_ payload: UnsafeMutableBufferPointer<UInt8>) throws -> AV1SequenceInfo {
    var br = BitReader(payload)
    // seq_profile: 3 bits
    let seq_profile = Int(br.readBits(3))
    // still_picture & reduced_still_picture_header
    let _still_picture = br.readBit()
    let reduced_still_picture_header = br.readBit() == 1

    var seq_level_idx_0 = 0
    var seq_tier_0 = 0
    var initial_display_delay_present_flag = 0
    var decoder_model_info_present_flag = 0
    
    var initial_display_delay_present_for_this_op: [Int] = []
    var initial_display_delay_minus_1: [Int] = []

    if reduced_still_picture_header {
        // seq_level_idx_0 (5)
        seq_level_idx_0 = Int(br.readBits(5))
        // reduced mode lacks many fields — still need to read the frame width bits later
    } else {
        let timing_info_present_flag = br.readBit()
        if timing_info_present_flag == 1 {
            // timing_info( )
            // num_units_in_display_tick (32) + time_scale (32)
            _ = br.readBits(32)
            _ = br.readBits(32)
            let equal_picture_interval = br.readBit()
            if equal_picture_interval == 1 {
                _ = br.readUVLC()
            }
            decoder_model_info_present_flag = br.readBit()
            if decoder_model_info_present_flag == 1 {
                _ = br.readBits(5)
                _ = br.readBits(32)
                _ = br.readBits(5)
                _ = br.readBits(5)
            }
        }
        initial_display_delay_present_flag = br.readBit()
        
        // operating points count minus 1 (5 bits)
        let op_cnt_minus_1 = Int(br.readBits(5))
        let num_operating_points = op_cnt_minus_1 + 1
        
        // For each operating point, parse idc(12) + seq_level_idx (5) + possible tier bit
        var first_seq_level_idx: Int? = nil
        var first_seq_tier: Int? = nil
        var decoder_model_present_for_this_op: [Int] = []
        
        for opIndex in 0..<num_operating_points {
            _ = br.readBits(12) // operating_point_idc
            let seq_level_idx = Int(br.readBits(5))
            if seq_level_idx > 7 {
                let seq_tier_this_op = br.readBit()
                if opIndex == 0 { first_seq_tier = seq_tier_this_op }
            } else {
                if opIndex == 0 { first_seq_tier = 0 }
            }
            if opIndex == 0 {
                first_seq_level_idx = seq_level_idx
            }
            
            if (decoder_model_info_present_flag != 0) {
                decoder_model_present_for_this_op.append(br.readBit())
                if (decoder_model_present_for_this_op[opIndex] != 0) {
                    //operating_parameters_info( i )
                }
            } else {
                decoder_model_present_for_this_op.append(0)
            }
            
            if (initial_display_delay_present_flag != 0) {
                initial_display_delay_present_for_this_op.append(br.readBit())
                if (initial_display_delay_present_for_this_op[opIndex] != 0) {
                    initial_display_delay_minus_1.append(Int(br.readBits(4)))
                }
                else {
                    initial_display_delay_minus_1.append(0)
                }
            }
            else {
                initial_display_delay_present_for_this_op.append(0)
                initial_display_delay_minus_1.append(0)
            }
        }
        if let lv = first_seq_level_idx { seq_level_idx_0 = lv } else { seq_level_idx_0 = 0 }
        if let t = first_seq_tier { seq_tier_0 = t } else { seq_tier_0 = 0 }
    }

    // After the operational-level/ timing area, specification has these fields:
    // frame_width_bits_minus_1 (4)
    // frame_height_bits_minus_1 (4)
    let frame_width_bits_minus_1 = Int(br.readBits(4))
    let frame_height_bits_minus_1 = Int(br.readBits(4))
    let widthBits = frame_width_bits_minus_1 + 1
    let heightBits = frame_height_bits_minus_1 + 1
    let max_frame_width_minus_1 = Int(br.readBits(widthBits))
    let max_frame_height_minus_1 = Int(br.readBits(heightBits))
    let width = max_frame_width_minus_1 + 1
    let height = max_frame_height_minus_1 + 1
    
    var frame_id_numbers_present_flag = 0
    if reduced_still_picture_header {
        frame_id_numbers_present_flag = 0
    }
    else {
        frame_id_numbers_present_flag = Int(br.readBit())
    }
    
    if (frame_id_numbers_present_flag != 0) {
        let _delta_frame_id_length_minus_2 = Int(br.readBits(4))
        let _additional_frame_id_length_minus_1 = Int(br.readBits(3))
    }
    
    let _use_128x128_superblock = Int(br.readBit())
    let _enable_filter_intra = Int(br.readBit())
    let _enable_intra_edge_filter = Int(br.readBit())
    
    var seq_force_screen_content_tools = 2 // SELECT_SCREEN_CONTENT_TOOLS
    //var seq_force_integer_mv = 2 // SELECT_SCREEN_CONTENT_TOOLS
        
    if (!reduced_still_picture_header) {
        let enable_interintra_compound = Int(br.readBit())
        let enable_masked_compound = Int(br.readBit())
        let enable_warped_motion = Int(br.readBit())
        let enable_dual_filter = Int(br.readBit())
        let enable_order_hint = Int(br.readBit())
        if (enable_order_hint != 0) {
            let enable_jnt_comp = Int(br.readBit())
            let enable_ref_frame_mvs = Int(br.readBit())
        } else {
            let enable_jnt_comp = 0
            let enable_ref_frame_mvs = 0
        }
        let seq_choose_screen_content_tools = Int(br.readBit())
        if (seq_choose_screen_content_tools != 0) {
            seq_force_screen_content_tools = 2 //SELECT_SCREEN_CONTENT_TOOLS
        } else {
            seq_force_screen_content_tools = Int(br.readBit())
        } 	 
                                                               	 
        if (seq_force_screen_content_tools > 0) {
            let seq_choose_integer_mv = Int(br.readBit())
            if (seq_choose_integer_mv != 0) {
                let seq_force_integer_mv = 2 // SELECT_INTEGER_MV
            } else {
                let seq_force_integer_mv = Int(br.readBit())
            }
        } else { 	 
            let seq_force_integer_mv = 2 // SELECT_INTEGER_MV
        }
        if (enable_order_hint != 0) {
            let order_hint_bits_minus_1 = Int(br.readBits(3))
            let OrderHintBits = order_hint_bits_minus_1 + 1
        } else {
            let OrderHintBits = 0
        }
    }
    let _enable_superres = Int(br.readBit())
    let _enable_cdef = Int(br.readBit())
    let _enable_restoration = Int(br.readBit())

    // color_config()
    // Next fields: color config: high_bitdepth (1), twelve_bit (1), monochrome (1), chroma_subsampling_x (1), chroma_subsampling_y (1), chroma_sample_position (2)
    let high_bitdepth = Int(br.readBit())
    var twelve_bit = 0
    var BitDepth = 8
    if ( seq_profile == 2 && high_bitdepth != 0) {
        twelve_bit = Int(br.readBit())
        BitDepth = (twelve_bit != 0) ? 12 : 10
    } else if ( seq_profile <= 2 ) {
        BitDepth = (high_bitdepth != 0) ? 10 : 8
    }
    //let twelve_bit = Int(br.readBit())
    var monochrome = 0
    if (seq_profile != 1) {
        monochrome = Int(br.readBit())
    }
    
    let _NumPlanes = (monochrome != 0) ? 1 : 3
    let color_description_present_flag = Int(br.readBit())
    var color_primaries = CP_UNSPECIFIED
    var transfer_characteristics = TC_UNSPECIFIED
    var matrix_coefficients = MC_UNSPECIFIED
        
    if (color_description_present_flag != 0) {
        color_primaries = Int(br.readBits(8))
        transfer_characteristics = Int(br.readBits(8))
        matrix_coefficients = Int(br.readBits(8))
    }
    
    var color_range = 0
    var chroma_subsampling_x = 1
    var chroma_subsampling_y = 1
    var chroma_sample_position = CSP_UNKNOWN
    var _separate_uv_delta_q = 0
    
    if (monochrome != 0) {
        color_range = Int(br.readBit())
        chroma_subsampling_x = 1 	 
        chroma_subsampling_y = 1 	 
        chroma_sample_position = CSP_UNKNOWN 	 
        _separate_uv_delta_q = 0
    } else if ( color_primaries == CP_BT_709 &&
                transfer_characteristics == TC_SRGB && 	 
                matrix_coefficients == MC_IDENTITY ) { 	 
        color_range = 1 	 
        chroma_subsampling_x = 0 	 
        chroma_subsampling_y = 0
        _separate_uv_delta_q = Int(br.readBit())
    } else {
        color_range = Int(br.readBit())
        if ( seq_profile == 0 ) { 	 
            chroma_subsampling_x = 1 	 
            chroma_subsampling_y = 1 	 
        } else if ( seq_profile == 1 ) { 	 
            chroma_subsampling_x = 0 	 
            chroma_subsampling_y = 0 	 
        } else { 	 
            if (BitDepth == 12) {
                chroma_subsampling_x = Int(br.readBit())
                if (chroma_subsampling_x != 0) {
                    chroma_subsampling_y = Int(br.readBit())
                }
                else {
                    chroma_subsampling_y = 0
                }
            } else {
                chroma_subsampling_x = 1 	 
                chroma_subsampling_y = 0 	 
            } 	 
        } 	 
        if (chroma_subsampling_x != 0 && chroma_subsampling_y != 0) {
            chroma_sample_position = Int(br.readBits(2))
        }
        _separate_uv_delta_q = Int(br.readBit())
    }
    
    let _film_grain_params_present = Int(br.readBit())

    // Create AV1SequenceInfo
    let info = AV1SequenceInfo(
        seq_profile: seq_profile,
        seq_level_idx_0: seq_level_idx_0,
        seq_tier_0: seq_tier_0,
        high_bitdepth: high_bitdepth,
        twelve_bit: twelve_bit,
        monochrome: monochrome,
        chroma_subsampling_x: chroma_subsampling_x,
        chroma_subsampling_y: chroma_subsampling_y,
        chroma_sample_position: chroma_sample_position,
        initial_presentation_delay_present: initial_display_delay_present_flag,
        initial_presentation_delay_minus_one: initial_display_delay_minus_1[0],
        width: width,
        height: height,
        bitsPerComponent: BitDepth,
        isFullRange: color_range == 1,
        colorPrimaries: color_primaries,
        transferCharacteristics: transfer_characteristics,
        matrixCoefficients: matrix_coefficients
    )

    // Basic sanity checks
    if info.width <= 0 || info.height <= 0 || info.width > 65536 || info.height > 65536 {
        throw AV1FormatDescriptionError.parseFailed("unreasonable dimensions: \(info.width)x\(info.height)")
    }
    return info
}

// MARK: - Build av1C payload (AV1CodecConfigurationRecord)

fileprivate func buildAV1CodecConfigurationRecord(seqInfo: AV1SequenceInfo, configOBUs: Data) -> Data {
    // Per AV1 ISOBMFF syntax:
    // aligned(8) class AV1CodecConfigurationRecord {
    //   unsigned int(1) marker = 1;
    //   unsigned int(7) version = 1;
    //   unsigned int(3) seq_profile;
    //   unsigned int(5) seq_level_idx_0;
    //   unsigned int(1) seq_tier_0;
    //   unsigned int(1) high_bitdepth;
    //   unsigned int(1) twelve_bit;
    //   unsigned int(1) monochrome;
    //   unsigned int(1) chroma_subsampling_x;
    //   unsigned int(1) chroma_subsampling_y;
    //   unsigned int(2) chroma_sample_position;
    //   unsigned int(3) reserved = 0;
    //   unsigned int(1) initial_presentation_delay_present;
    //   if(initial_presentation_delay_present) {
    //     unsigned int(4) initial_presentation_delay_minus_one;
    //   } else {
    //     unsigned int(4) reserved = 0;
    //   }
    //   unsigned int(8) configOBUs[];
    // }

    var out = Data()

    // first byte: marker(1)=1 as MSB, version (7)=1 => 0b1_0000001 = 0x81
    out.append(0x81)

    // second byte: seq_profile (3 bits) | seq_level_idx_0 (5 bits)
    let b1: UInt8 = UInt8((seqInfo.seq_profile & 0x07) << 5) | UInt8(seqInfo.seq_level_idx_0 & 0x1F)
    out.append(b1)

    // third byte bits: seq_tier_0 (1), high_bitdepth (1), twelve_bit (1), monochrome (1), chroma_subsampling_x (1), chroma_subsampling_y (1), chroma_sample_position (2)
    var third: UInt8 = 0
    third |= UInt8((seqInfo.seq_tier_0 & 0x1) << 7)
    third |= UInt8((seqInfo.high_bitdepth & 0x1) << 6)
    third |= UInt8((seqInfo.twelve_bit & 0x1) << 5)
    third |= UInt8((seqInfo.monochrome & 0x1) << 4)
    third |= UInt8((seqInfo.chroma_subsampling_x & 0x1) << 3)
    third |= UInt8((seqInfo.chroma_subsampling_y & 0x1) << 2)
    third |= UInt8(seqInfo.chroma_sample_position & 0x03)
    out.append(third)

    // fourth byte: reserved (3 bits) = 0 in MSBs; initial_presentation_delay_present (1) at bit4; then 4 bits for initial_presentation_delay_minus_one or reserved
    var fourth: UInt8 = 0
    // top 3 bits reserved (already zero)
    fourth |= UInt8((seqInfo.initial_presentation_delay_present & 0x1) << 4)
    if seqInfo.initial_presentation_delay_present == 1 {
        fourth |= UInt8(seqInfo.initial_presentation_delay_minus_one & 0x0F)
    } else {
        // 4 bits reserved zero
    }
    out.append(fourth)

    // append configOBUs (raw bytes). The spec says configOBUs[] are 8-bit array; OBUs inside must have obu_has_size_field==1.
    out.append(contentsOf: configOBUs)

    return out
}
