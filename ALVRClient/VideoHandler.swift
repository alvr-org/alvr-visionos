//
//  VideoHandler.swift
//

import Foundation
import VideoToolbox
import AVKit

let forceFastSecretTextureFormats = true
#if !targetEnvironment(simulator)
let forceFastSecretTextureFormats = true
#else
let forceFastSecretTextureFormats = false
#endif

let H264_NAL_TYPE_SPS = 7
let HEVC_NAL_TYPE_VPS: UInt8 = 32
let HEVC_NAL_TYPE_SPS: UInt8 = 33
let HEVC_NAL_TYPE_PPS: UInt8 = 34

//
// Non-conclusive list of interesting private Metal pixel formats
//
let MTLPixelFormatYCBCR8_420_2P: UInt = 500
let MTLPixelFormatYCBCR8_422_1P: UInt = 501
let MTLPixelFormatYCBCR8_422_2P: UInt = 502
let MTLPixelFormatYCBCR8_444_2P: UInt = 503
let MTLPixelFormatYCBCR10_444_1P: UInt = 504
let MTLPixelFormatYCBCR10_420_2P: UInt = 505
let MTLPixelFormatYCBCR10_422_2P: UInt = 506
let MTLPixelFormatYCBCR10_444_2P: UInt = 507
let MTLPixelFormatYCBCR10_420_2P_PACKED: UInt = 508
let MTLPixelFormatYCBCR10_422_2P_PACKED: UInt = 509
let MTLPixelFormatYCBCR10_444_2P_PACKED: UInt = 510

let MTLPixelFormatYCBCR8_420_2P_sRGB: UInt = 520
let MTLPixelFormatYCBCR8_422_1P_sRGB: UInt = 521
let MTLPixelFormatYCBCR8_422_2P_sRGB: UInt = 522
let MTLPixelFormatYCBCR8_444_2P_sRGB: UInt = 523
let MTLPixelFormatYCBCR10_444_1P_sRGB: UInt = 524
let MTLPixelFormatYCBCR10_420_2P_sRGB: UInt = 525
let MTLPixelFormatYCBCR10_422_2P_sRGB: UInt = 526
let MTLPixelFormatYCBCR10_444_2P_sRGB: UInt = 527
let MTLPixelFormatYCBCR10_420_2P_PACKED_sRGB: UInt = 528
let MTLPixelFormatYCBCR10_422_2P_PACKED_sRGB: UInt = 529
let MTLPixelFormatYCBCR10_444_2P_PACKED_sRGB: UInt = 530

let MTLPixelFormatRGB8_420_2P: UInt = 540
let MTLPixelFormatRGB8_422_2P: UInt = 541
let MTLPixelFormatRGB8_444_2P: UInt = 542
let MTLPixelFormatRGB10_420_2P: UInt = 543
let MTLPixelFormatRGB10_422_2P: UInt = 544
let MTLPixelFormatRGB10_444_2P: UInt = 545
let MTLPixelFormatRGB10_420_2P_PACKED: UInt = 546
let MTLPixelFormatRGB10_422_2P_PACKED: UInt = 547
let MTLPixelFormatRGB10_444_2P_PACKED: UInt = 548

let MTLPixelFormatRGB10A8_2P_XR10: UInt = 550
let MTLPixelFormatRGB10A8_2P_XR10_sRGB: UInt = 551
let MTLPixelFormatBGRA10_XR: UInt = 552
let MTLPixelFormatBGRA10_XR_sRGB: UInt = 553
let MTLPixelFormatBGR10_XR: UInt = 554
let MTLPixelFormatBGR10_XR_sRGB: UInt = 555
let MTLPixelFormatRGBA16Float_XR: UInt = 556

let MTLPixelFormatYCBCRA8_444_1P: UInt = 560

let MTLPixelFormatYCBCR12_420_2P: UInt = 570
let MTLPixelFormatYCBCR12_422_2P: UInt = 571
let MTLPixelFormatYCBCR12_444_2P: UInt = 572
let MTLPixelFormatYCBCR12_420_2P_PQ: UInt = 573
let MTLPixelFormatYCBCR12_422_2P_PQ: UInt = 574
let MTLPixelFormatYCBCR12_444_2P_PQ: UInt = 575
let MTLPixelFormatR10Unorm_X6: UInt = 576
let MTLPixelFormatR10Unorm_X6_sRGB: UInt = 577
let MTLPixelFormatRG10Unorm_X12: UInt = 578
let MTLPixelFormatRG10Unorm_X12_sRGB: UInt = 579
let MTLPixelFormatYCBCR12_420_2P_PACKED: UInt = 580
let MTLPixelFormatYCBCR12_422_2P_PACKED: UInt = 581
let MTLPixelFormatYCBCR12_444_2P_PACKED: UInt = 582
let MTLPixelFormatYCBCR12_420_2P_PACKED_PQ: UInt = 583
let MTLPixelFormatYCBCR12_422_2P_PACKED_PQ: UInt = 584
let MTLPixelFormatYCBCR12_444_2P_PACKED_PQ: UInt = 585
let MTLPixelFormatRGB10A2Unorm_sRGB: UInt = 586
let MTLPixelFormatRGB10A2Unorm_PQ: UInt = 587
let MTLPixelFormatR10Unorm_PACKED: UInt = 588
let MTLPixelFormatRG10Unorm_PACKED: UInt = 589
let MTLPixelFormatYCBCR10_444_1P_XR: UInt = 590
let MTLPixelFormatYCBCR10_420_2P_XR: UInt = 591
let MTLPixelFormatYCBCR10_422_2P_XR: UInt = 592
let MTLPixelFormatYCBCR10_444_2P_XR: UInt = 593
let MTLPixelFormatYCBCR10_420_2P_PACKED_XR: UInt = 594
let MTLPixelFormatYCBCR10_422_2P_PACKED_XR: UInt = 595
let MTLPixelFormatYCBCR10_444_2P_PACKED_XR: UInt = 596
let MTLPixelFormatYCBCR12_420_2P_XR: UInt = 597
let MTLPixelFormatYCBCR12_422_2P_XR: UInt = 598
let MTLPixelFormatYCBCR12_444_2P_XR: UInt = 599
let MTLPixelFormatYCBCR12_420_2P_PACKED_XR: UInt = 600
let MTLPixelFormatYCBCR12_422_2P_PACKED_XR: UInt = 601
let MTLPixelFormatYCBCR12_444_2P_PACKED_XR: UInt = 602
let MTLPixelFormatR12Unorm_X4: UInt = 603
let MTLPixelFormatR12Unorm_X4_PQ: UInt = 604
let MTLPixelFormatRG12Unorm_X8: UInt = 605
let MTLPixelFormatR10Unorm_X6_PQ: UInt = 606
//
// end Metal pixel formats
//

// https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
let kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange = 0x70663230 as OSType // pf20
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange = 0x70663232 as OSType // pf22
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange = 0x70663434 as OSType // pf44

let kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange = 0x70343230 as OSType // p420
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange = 0x70343232 as OSType // p422
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange = 0x70343434 as OSType // p444

// Apparently kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange is known as kCVPixelFormatType_AGX_420YpCbCr8BiPlanarVideoRange in WebKit.

// Other formats Apple forgot
let kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange = 0x2D786630 as OSType // -xf0
let kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange = 0x26786632 as OSType // &xf2
let kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange = 0x2D786632 as OSType // -xf2
let kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat = 0x26786630 as OSType // &xf0

//
// Non-conclusive list of interesting private Metal pixel formats
//
let MTLPixelFormatYCBCR8_420_2P: UInt = 500
let MTLPixelFormatYCBCR8_422_1P: UInt = 501
let MTLPixelFormatYCBCR8_422_2P: UInt = 502
let MTLPixelFormatYCBCR8_444_2P: UInt = 503
let MTLPixelFormatYCBCR10_444_1P: UInt = 504
let MTLPixelFormatYCBCR10_420_2P: UInt = 505
let MTLPixelFormatYCBCR10_422_2P: UInt = 506
let MTLPixelFormatYCBCR10_444_2P: UInt = 507
let MTLPixelFormatYCBCR10_420_2P_PACKED: UInt = 508
let MTLPixelFormatYCBCR10_422_2P_PACKED: UInt = 509
let MTLPixelFormatYCBCR10_444_2P_PACKED: UInt = 510

let MTLPixelFormatYCBCR8_420_2P_sRGB: UInt = 520
let MTLPixelFormatYCBCR8_422_1P_sRGB: UInt = 521
let MTLPixelFormatYCBCR8_422_2P_sRGB: UInt = 522
let MTLPixelFormatYCBCR8_444_2P_sRGB: UInt = 523
let MTLPixelFormatYCBCR10_444_1P_sRGB: UInt = 524
let MTLPixelFormatYCBCR10_420_2P_sRGB: UInt = 525
let MTLPixelFormatYCBCR10_422_2P_sRGB: UInt = 526
let MTLPixelFormatYCBCR10_444_2P_sRGB: UInt = 527
let MTLPixelFormatYCBCR10_420_2P_PACKED_sRGB: UInt = 528
let MTLPixelFormatYCBCR10_422_2P_PACKED_sRGB: UInt = 529
let MTLPixelFormatYCBCR10_444_2P_PACKED_sRGB: UInt = 530

let MTLPixelFormatRGB8_420_2P: UInt = 540
let MTLPixelFormatRGB8_422_2P: UInt = 541
let MTLPixelFormatRGB8_444_2P: UInt = 542
let MTLPixelFormatRGB10_420_2P: UInt = 543
let MTLPixelFormatRGB10_422_2P: UInt = 544
let MTLPixelFormatRGB10_444_2P: UInt = 545
let MTLPixelFormatRGB10_420_2P_PACKED: UInt = 546
let MTLPixelFormatRGB10_422_2P_PACKED: UInt = 547
let MTLPixelFormatRGB10_444_2P_PACKED: UInt = 548

let MTLPixelFormatRGB10A8_2P_XR10: UInt = 550
let MTLPixelFormatRGB10A8_2P_XR10_sRGB: UInt = 551
let MTLPixelFormatBGRA10_XR: UInt = 552
let MTLPixelFormatBGRA10_XR_sRGB: UInt = 553
let MTLPixelFormatBGR10_XR: UInt = 554
let MTLPixelFormatBGR10_XR_sRGB: UInt = 555
let MTLPixelFormatRGBA16Float_XR: UInt = 556

let MTLPixelFormatYCBCRA8_444_1P: UInt = 560

let MTLPixelFormatYCBCR12_420_2P: UInt = 570
let MTLPixelFormatYCBCR12_422_2P: UInt = 571
let MTLPixelFormatYCBCR12_444_2P: UInt = 572
let MTLPixelFormatYCBCR12_420_2P_PQ: UInt = 573
let MTLPixelFormatYCBCR12_422_2P_PQ: UInt = 574
let MTLPixelFormatYCBCR12_444_2P_PQ: UInt = 575
let MTLPixelFormatR10Unorm_X6: UInt = 576
let MTLPixelFormatR10Unorm_X6_sRGB: UInt = 577
let MTLPixelFormatRG10Unorm_X12: UInt = 578
let MTLPixelFormatRG10Unorm_X12_sRGB: UInt = 579
let MTLPixelFormatYCBCR12_420_2P_PACKED: UInt = 580
let MTLPixelFormatYCBCR12_422_2P_PACKED: UInt = 581
let MTLPixelFormatYCBCR12_444_2P_PACKED: UInt = 582
let MTLPixelFormatYCBCR12_420_2P_PACKED_PQ: UInt = 583
let MTLPixelFormatYCBCR12_422_2P_PACKED_PQ: UInt = 584
let MTLPixelFormatYCBCR12_444_2P_PACKED_PQ: UInt = 585
let MTLPixelFormatRGB10A2Unorm_sRGB: UInt = 586
let MTLPixelFormatRGB10A2Unorm_PQ: UInt = 587
let MTLPixelFormatR10Unorm_PACKED: UInt = 588
let MTLPixelFormatRG10Unorm_PACKED: UInt = 589
let MTLPixelFormatYCBCR10_444_1P_XR: UInt = 590
let MTLPixelFormatYCBCR10_420_2P_XR: UInt = 591
let MTLPixelFormatYCBCR10_422_2P_XR: UInt = 592
let MTLPixelFormatYCBCR10_444_2P_XR: UInt = 593
let MTLPixelFormatYCBCR10_420_2P_PACKED_XR: UInt = 594
let MTLPixelFormatYCBCR10_422_2P_PACKED_XR: UInt = 595
let MTLPixelFormatYCBCR10_444_2P_PACKED_XR: UInt = 596
let MTLPixelFormatYCBCR12_420_2P_XR: UInt = 597
let MTLPixelFormatYCBCR12_422_2P_XR: UInt = 598
let MTLPixelFormatYCBCR12_444_2P_XR: UInt = 599
let MTLPixelFormatYCBCR12_420_2P_PACKED_XR: UInt = 600
let MTLPixelFormatYCBCR12_422_2P_PACKED_XR: UInt = 601
let MTLPixelFormatYCBCR12_444_2P_PACKED_XR: UInt = 602
let MTLPixelFormatR12Unorm_X4: UInt = 603
let MTLPixelFormatR12Unorm_X4_PQ: UInt = 604
let MTLPixelFormatRG12Unorm_X8: UInt = 605
let MTLPixelFormatR10Unorm_X6_PQ: UInt = 606
//
// end Metal pixel formats
//

// https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
let kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange = 0x70663230 as OSType // pf20
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange = 0x70663232 as OSType // pf22
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange = 0x70663434 as OSType // pf44

let kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange = 0x70343230 as OSType // p420
let kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange = 0x70343232 as OSType // p422
let kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange = 0x70343434 as OSType // p444

// Apparently kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange is known as kCVPixelFormatType_AGX_420YpCbCr8BiPlanarVideoRange in WebKit.

// Other formats Apple forgot
let kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange = 0x2D786630 as OSType // -xf0
let kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange = 0x26786632 as OSType // &xf2
let kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange = 0x2D786632 as OSType // -xf2
let kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat = 0x26786630 as OSType // &xf0

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
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat: "Lossless_420YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange: "Lossless_420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange: "Lossless_420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange: "Lossless_420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange: "Lossless_422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange: "Lossless_422YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossy_32BGRA: "32BGRA",
        kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange: "Lossy_420YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange: "Lossy_420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange: "Lossy_420YpCbCr8BiPlanarFullRange",
        kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange: "Lossy_420YpCbCr8BiPlanarVideoRange",
        kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange: "Lossy_422YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange: "Lossy_422YpCbCr10PackedBiPlanarVideoRange",
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
        
        kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange: "420YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange: "kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange: "kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange",
        kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange",
        kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange: "kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange",
        
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
                return forceFastSecretTextureFormats ? [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR8_420_2P_sRGB)!, MTLPixelFormat.invalid] : [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm]

            // 10-bit biplanar
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
                return forceFastSecretTextureFormats ? [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_420_2P_sRGB)!, MTLPixelFormat.invalid] : [MTLPixelFormat.r16Unorm, MTLPixelFormat.rg16Unorm]

            //
            // If it's good enough for WebKit, it's good enough for me.
            // https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/MetalSPI.h#L30
            // https://github.com/WebKit/WebKit/blob/f86d3400c875519b3f3c368f1ea9a37ed8a1d11b/Source/WebGPU/WebGPU/BindGroup.mm#L43
            // https://github.com/WebKit/WebKit/blob/ef1916c078676dca792cef30502a765d398dcc18/Source/WebGPU/WebGPU/BindGroup.mm#L416
            //
            // 10-bit packed biplanar 4:2:0
            case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange:
                return [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_420_2P_PACKED_sRGB)!, MTLPixelFormat.invalid] // MTLPixelFormatYCBCR10_420_2P_PACKED
            
            // 10-bit packed biplanar 4:2:2
            case kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange:
                return [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_422_2P_PACKED_sRGB)!, MTLPixelFormat.invalid] // MTLPixelFormatYCBCR10_422_2P_PACKED
            
            // 10-bit packed biplanar 4:4:4
            case kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange:
                return [MTLPixelFormat.init(rawValue: MTLPixelFormatYCBCR10_444_2P_PACKED_sRGB)!, MTLPixelFormat.invalid] // MTLPixelFormatYCBCR10_444_2P_PACKED

            // Guess 8-bit biplanar otherwise
            default:
                let formatStr = coreVideoPixelFormatToStr[format, default: "unknown"]
                print("Warning: Pixel format \(formatStr) (\(format)) is not currently accounted for! Returning 8-bit vals")
                return [MTLPixelFormat.r8Unorm, MTLPixelFormat.rg8Unorm]
        }
    }
    
    static func isFormatSecret(_ format: OSType) -> Bool
    {
        switch(format) {
            // Packed formats, requires secret MTLTexture pixel formats
            case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange_compat,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10PackedBiPlanarFullRange,
                 kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10PackedBiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10PackedBiPlanarVideoRange:
            return true;
            
            // Not packed, but there's still a nice pixel format for them that's a
            // few hundred microseconds faster.
            case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange, // 8-bit
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
                 kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
                 
                 // 10-bit
                 kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
                return forceFastSecretTextureFormats
            default:
                return false
        }
    }
    
    static func getYUVTransformForVideoFormat(_ videoFormat: CMFormatDescription) -> simd_float4x4 {
        let fmtYCbCrMatrixRaw = videoFormat.extensions["CVImageBufferYCbCrMatrix" as CFString]
        let fmtYCbCrMatrix = (fmtYCbCrMatrixRaw != nil ? fmtYCbCrMatrixRaw as! CFString : "unknown" as CFString)

        // Bless this page for ending my stint of plugging in random values
        // from other projects:
        // https://kdashg.github.io/misc/colors/from-coeffs.html
        let ycbcrJPEGToRGB = simd_float4x4([
            simd_float4(+1.0000, +1.0000, +1.0000, +0.0000), // Y
            simd_float4(+0.0000, -0.3441, +1.7720, +0.0000), // Cb
            simd_float4(+1.4020, -0.7141, +0.0000, +0.0000), // Cr
            simd_float4(-0.7010, +0.5291, -0.8860, +1.0000)]  // offsets
        );

        // BT.601 Full range (8-bit)
        let bt601ToRGBFull8bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000), // Y
            simd_float4(+0.0000000, -0.3454912, +1.7789764, +0.0000), // Cb
            simd_float4(+1.4075197, -0.7169478, -0.0000000, +0.0000), // Cr
            simd_float4(-0.7065197, +0.5333027, -0.8929764, +1.0000)]
        );

        // BT.2020 Full range (8-bit)
        let bt2020ToRGBFull8bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000), // Y
            simd_float4(-0.0000000, -0.1652010, +1.8888071, +0.0000), // Cb
            simd_float4(+1.4804055, -0.5736025, +0.0000000, +0.0000), // Cr
            simd_float4(-0.7431055, +0.3708504, -0.9481071, +1.0000)]
        );
 
        // BT.709 Full range (8-bit)
        let bt709ToRGBFull8bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000), // Y
            simd_float4(+0.0000000, -0.1880618, +1.8629055, +0.0000), // Cb
            simd_float4(+1.5810000, -0.4699673, +0.0000000, +0.0000), // Cr
            simd_float4(-0.7936000, +0.3303048, -0.9351055, +1.0000)]
        );

        // BT.601 Full range (10-bit)
        let bt601ToRGBFull10bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000), // Y
            simd_float4(+0.0000000, -0.3444730, +1.7737339, +0.0000), // Cb
            simd_float4(+1.4033718, -0.7148350, +0.0000000, +0.0000), // Cr
            simd_float4(-0.7023718, +0.5301718, -0.8877339, +1.0000)]
        );

        // BT.2020 Full range (10-bit)
        let bt2020ToRGBFull10bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000), // Y
            simd_float4(-0.0000000, -0.1647141, +1.8832409, +0.0000), // Cb
            simd_float4(+1.4760429, -0.5719122, +0.0000000, +0.0000), // Cr
            simd_float4(-0.7387429, +0.3686732, -0.9425409, +1.0000)]
        );

        // BT.709 Full range (10-bit)
        let bt709ToRGBFull10bit = simd_float4x4([
            simd_float4(+1.0000000, +1.0000000, +1.0000000, +0.0000), // Y
            simd_float4(+0.0000000, -0.1875076, +1.8574157, +0.0000), // Cb
            simd_float4(+1.5763409, -0.4685823, +0.0000000, +0.0000), // Cr
            simd_float4(-0.7889409, +0.3283656, -0.9296157, +1.0000)]
        );

        // BT.2020 Limited range
        /*let bt2020ToRGBLimited = simd_float4x4([
            simd_float4(+1.1632, +1.1632, +1.1632, +0.0000), // Y
            simd_float4(+0.0002, -0.1870, +2.1421, +0.0000), // Cb
            simd_float4(+1.6794, -0.6497, +0.0008, +0.0000), // Cr
            simd_float4(-0.91607960784, +0.34703254902, -1.14866392157, +1.0000)]  // offsets
        );*/

        // BT.709 Limited range
        /*let bt709ToRGBLimited = simd_float4x4([
            simd_float4(+1.1644, +1.1644, +1.1644, +0.0000), // Y
            simd_float4(+0.0001, -0.2133, +2.1125, +0.0000), // Cb
            simd_float4(+1.7969, -0.5342, -0.0002, +0.0000), // Cr
            simd_float4(-0.97506392156, 0.30212823529, -1.1333145098, +1.0000)]  // offsets
        );*/

        let bpc = getBpcForVideoFormat(videoFormat)
        if bpc == 10 {
            switch(fmtYCbCrMatrix) {
                case kCVImageBufferYCbCrMatrix_ITU_R_601_4:
                    return bt601ToRGBFull10bit;
                case kCVImageBufferYCbCrMatrix_ITU_R_709_2:
                    return bt709ToRGBFull10bit;
                case kCVImageBufferYCbCrMatrix_ITU_R_2020:
                    return bt2020ToRGBFull10bit;
                default:
                    return ycbcrJPEGToRGB;
            }
        }
        else {
            switch(fmtYCbCrMatrix) {
                case kCVImageBufferYCbCrMatrix_ITU_R_601_4:
                    return bt601ToRGBFull8bit;
                case kCVImageBufferYCbCrMatrix_ITU_R_709_2:
                    return bt709ToRGBFull8bit;
                case kCVImageBufferYCbCrMatrix_ITU_R_2020:
                    return bt2020ToRGBFull8bit;
                default:
                    return ycbcrJPEGToRGB;
            }
        }
    }

    static func pollNal() -> (UInt64, [AlvrViewParams], Data)? {
        let nalLength = alvr_poll_nal(nil, nil, nil)
        if nalLength == 0 {
            return nil
        }
        let nalBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: Int(nalLength*16)) // HACK: idk how to handle this, there's a ToCToU here
        let nalViewsPtr = UnsafeMutablePointer<AlvrViewParams>.allocate(capacity: 2)
        defer { nalBuffer.deallocate() }
        defer { nalViewsPtr.deallocate() }
        var nalTimestamp:UInt64 = 0
        let realNalLength = alvr_poll_nal(&nalTimestamp, nalViewsPtr, nalBuffer.baseAddress)
        
        let nalViews = [nalViewsPtr[0], nalViewsPtr[1]]
        
        let ret = (nalTimestamp, nalViews, Data(bytes: nalBuffer.baseAddress!, count: Int(realNalLength & 0xFFFFFFFF)))
        return ret
    }
    
    static func abandonAllPendingNals() {
        while let _ = VideoHandler.pollNal() {}
    }
    
    static func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .filter({ $0.activationState == .foregroundActive })
            .map({ $0 as? UIWindowScene })
            .compactMap({ $0 })
            .first?.windows
            .filter({ $0.isKeyWindow })
            .first
    }
    
    static func applyRefreshRate(videoFormat: CMFormatDescription?) {
        if videoFormat == nil {
            return
        }
        DispatchQueue.main.async {
            if let window = currentKeyWindow() {
                let avDisplayManager = window.avDisplayManager
                avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: Float(ALVRClientApp.gStore.settings.streamFPS) ?? 90, formatDescription: videoFormat!)
            }
        }
    }
    
    static func createVideoDecoder(initialNals: Data, codec: Int) -> (VTDecompressionSession?, CMFormatDescription?) {
    static func createVideoDecoder(initialNals: UnsafeMutableBufferPointer<UInt8>, codec: Int) -> (VTDecompressionSession?, CMFormatDescription?) {
        let nalHeader:[UInt8] = [0x00, 0x00, 0x00, 0x01]
        var videoFormat:CMFormatDescription? = nil
        var err:OSStatus = 0
        
        if (codec == ALVR_CODEC_H264.rawValue) {
            err = initialNals.withUnsafeBytes { (b:UnsafeRawBufferPointer) in
                // First two are the SPS and PPS
                // https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/sdk/objc/components/video_codec/nalu_rewriter.cc;l=228;drc=6f86f6af008176e631140e6a80e0a0bca9550143
                let nalOffset0 = b.baseAddress!
                let nalOffset1 = memmem(nalOffset0 + 4, b.count - 4, nalHeader, nalHeader.count)!
                let nalLength0 = UnsafeRawPointer(nalOffset1) - nalOffset0 - 4
                let nalLength1 = b.baseAddress! + b.count - UnsafeRawPointer(nalOffset1) - 4

                let parameterSetPointers = [(nalOffset0 + 4).assumingMemoryBound(to: UInt8.self), UnsafeRawPointer(nalOffset1 + 4).assumingMemoryBound(to: UInt8.self)]
                let parameterSetSizes = [nalLength0, nalLength1]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: parameterSetPointers, parameterSetSizes: parameterSetSizes, nalUnitHeaderLength: 4, formatDescriptionOut: &videoFormat)
            }
        } else if (codec == HEVC_NAL_TYPE_VPS) {
        } else if (codec == ALVR_CODEC_HEVC.rawValue) {
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
            print("format?!")
            return (nil, nil)
        }

        if videoFormat == nil {
            return (nil, nil)
        }

        else if codec == ALVR_CODEC_AV1.rawValue {
            print("UNHANDLED/WIP AV1!!")
            
            /*var s = ""
            for i in 0..<initialNals.count {
                s += String(format: "%02x ", initialNals[i])
            }
            //print(s)
            */
            
            //var config_blob:[UInt8] = [0x81, 0x05, 0x0c, 0x00, 0x0a, 0x0f, 0x00, 0x00, 0x00, 0x66, 0xEA, 0x7F, 0xE1, 0xF8, 0x04, 0x33, 0x20, 0x21, 0xA0, 0x30, 0x80]
            
            // TODO: Parse OBUs for all of this.
            // https://forums.developer.apple.com/forums/thread/739953
            var config_blob:[UInt8] = [0x81, 0x05, 0x0c, 0x00, 0x0a, 0x0e, 0x00, 0x00, 0x00, 0x2c, 0xd5, 0x9f, 0x3f, 0xdd, 0xaf, 0x99, 0x01, 0x01, 0x01, 0x04]
            var atoms:[NSString: AnyObject] = [:]
            atoms["av1C"] = NSData.init(bytes: config_blob, length: config_blob.count)
            var av1_exts:[NSString: AnyObject] = [:]
            av1_exts[kCMFormatDescriptionExtension_BitsPerComponent] = 8 as NSNumber
            av1_exts[kCMFormatDescriptionExtension_FieldCount] = 1 as NSNumber
            av1_exts[kCMFormatDescriptionExtension_ChromaLocationBottomField] = kCVImageBufferChromaLocation_Left
            av1_exts[kCMFormatDescriptionExtension_ChromaLocationTopField] = kCVImageBufferChromaLocation_Left
            av1_exts[kCMFormatDescriptionExtension_ColorPrimaries] = kCVImageBufferColorPrimaries_ITU_R_709_2
            av1_exts[kCMFormatDescriptionExtension_TransferFunction] = kCVImageBufferColorPrimaries_ITU_R_709_2
            av1_exts[kCMFormatDescriptionExtension_YCbCrMatrix] = kCVImageBufferColorPrimaries_ITU_R_709_2
            av1_exts[kCMFormatDescriptionExtension_Depth] = 24 as NSNumber
            av1_exts[kCMFormatDescriptionExtension_FormatName] = "av01" as NSString
            av1_exts[kCMFormatDescriptionExtension_FullRangeVideo] = true as NSNumber
            av1_exts[kCMFormatDescriptionExtension_RevisionLevel] = 0 as NSNumber
            av1_exts[kCMFormatDescriptionExtension_SpatialQuality] = 0 as NSNumber
            av1_exts[kCMFormatDescriptionExtension_TemporalQuality] = 0 as NSNumber
            //av1_exts[kCMFormatDescriptionExtension_VerbatimISOSampleEntry] =
            av1_exts[kCMFormatDescriptionExtension_Version] = 0 as NSNumber
            av1_exts[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary
            err = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AV1, width: /*2559+1*/720, height: /*1087+1*/1280, extensions: av1_exts as CFDictionary, formatDescriptionOut: &videoFormat)
        }
        else {
            print("Unknown codec type \(codec)")
            return (nil, nil)
        }

        if err != 0 {
            print("format fail?! \(err)")
            return (nil, nil)
        }

        if videoFormat == nil {
            return (nil, nil)
        }

        print(videoFormat!)
        
        // We need our pixels unpacked for 10-bit so that the Metal textures actually work
        //var pixelFormat:OSType? = nil
        //let bpc = getBpcForVideoFormat(videoFormat!)
        //let isFullRange = getIsFullRangeForVideoFormat(videoFormat!)
        
        // TODO: figure out how to check for 422/444, CVImageBufferChromaLocationBottomField?
        // On visionOS 2, setting pixelFormat *at all* causes a copy to an uncompressed MTLTexture buffer, so we are avoiding it for now.
        //if bpc == 10 {
        //    //pixelFormat = isFullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        //    //pixelFormat = isFullRange ? kCVPixelFormatType_420YpCbCr10PackedBiPlanarFullRange : kCVPixelFormatType_420YpCbCr10PackedBiPlanarVideoRange // default
        //}
        
        let videoDecoderSpecification:[NSString: AnyObject] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:kCFBooleanTrue]
        let destinationImageBufferAttributes:[NSString: AnyObject] = [kCVPixelBufferMetalCompatibilityKey: true as NSNumber, kCVPixelBufferPoolMinimumBufferCountKey: 3 as NSNumber]
        // TODO come back to this maybe idk
        //if pixelFormat != nil {
        //    destinationImageBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = pixelFormat! as NSNumber
        //}

        var decompressionSession:VTDecompressionSession? = nil
        err = VTDecompressionSessionCreate(allocator: nil, formatDescription: videoFormat!, decoderSpecification: videoDecoderSpecification as CFDictionary, imageBufferAttributes: destinationImageBufferAttributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &decompressionSession)
        if err != 0 {
            print("format?!")
            print("VTDecompressionSessionCreate err?! \(err)")
            return (nil, nil)
        }
        
        // Optimize display for 24P film viewing if selected
        VideoHandler.applyRefreshRate(videoFormat: videoFormat)
        
        if decompressionSession == nil {
            print("no session??")
            return (nil, nil)
        }
        
        return (decompressionSession!, videoFormat!)
    }

    // Function to parse NAL units and extract VPS, SPS, and PPS data
    static func extractParameterSets(from nalData: UnsafeMutableBufferPointer<UInt8>) -> (vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?) {
        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        
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
    private static func findNaluIndices(bufferBounded: UnsafeMutableBufferPointer<UInt8>) -> ([NaluIndex], Bool) {
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
    
    private struct NaluIndex {
        var startOffset: Int
        var payloadStartOffset: Int
        var payloadSize: Int
        var threeByteHeader: Bool
    }
    
    // Based on https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/objc/components/video_codec/nalu_rewriter.cc
    private static func annexBBufferToCMSampleBuffer(buffer: Data, videoFormat: CMFormatDescription) -> CMSampleBuffer? {
        // no SPS/PPS, handled with the initial nals
    private static func annexBBufferToCMSampleBuffer(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription) -> CMSampleBuffer? {
        let (naluIndices, elgibleForModifyInPlace) = findNaluIndices(bufferBounded: buffer)
        
        if elgibleForModifyInPlace {
            return annexBBufferToCMSampleBufferModifyInPlace(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
        else {
            return annexBBufferToCMSampleBufferWithCopy(buffer: buffer, videoFormat: videoFormat, naluIndices: naluIndices)
        }
    }
    
    private static func annexBBufferToCMSampleBufferWithCopy(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription, naluIndices: [NaluIndex]) -> CMSampleBuffer? {
        var err: OSStatus = 0
        defer { buffer.deallocate() }

        // we're replacing the 3/4 nalu headers with a 4 byte length, so add an extra byte on top of the original length for each 3-byte nalu header
        let blockBufferLength = buffer.count + naluIndices.filter(\.threeByteHeader).count
        let blockBuffer = try! CMBlockBuffer(length: blockBufferLength, flags: .assureMemoryNow)
        
        var contiguousBuffer: CMBlockBuffer!
        if !CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) {
            err = CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: blockBuffer, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &contiguousBuffer)
            if err != 0 {
                print("CMBlockBufferCreateContiguous error")
                return nil
            }
        } else {
            contiguousBuffer = blockBuffer
        }
        
        var blockBufferSize = 0
        var dataPtr: UnsafeMutablePointer<Int8>!
        err = CMBlockBufferGetDataPointer(contiguousBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &blockBufferSize, dataPointerOut: &dataPtr)
        if err != 0 {
            print("CMBlockBufferGetDataPointer error")
            return nil
        }
        
        //dataPtr.withMemoryRebound(to: UInt8.self, capacity: blockBufferSize) { pointer in
        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(dataPtr))!
        var offset = 0
        
        buffer.withUnsafeBytes { (unsafeBytes) in
            let bytes = unsafeBytes.bindMemory(to: UInt8.self).baseAddress!

            for index in naluIndices {
                pointer.advanced(by: offset    ).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
                pointer.advanced(by: offset + 1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
                pointer.advanced(by: offset + 2).pointee = UInt8((index.payloadSize >>  8) & 0xFF)
                pointer.advanced(by: offset + 3).pointee = UInt8((index.payloadSize      ) & 0xFF)
                offset += 4
                
                pointer.advanced(by: offset).update(from: bytes.advanced(by: index.payloadStartOffset), count: blockBufferSize - offset)
                offset += index.payloadSize
            }
        }
        
        var sampleBuffer: CMSampleBuffer!
        err = CMSampleBufferCreate(allocator: nil, dataBuffer: contiguousBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        if err != 0 {
            print("CMSampleBufferCreate error")
            return nil
        }
        
        return sampleBuffer
    }
    
    private static func annexBBufferToCMSampleBufferModifyInPlace(buffer: UnsafeMutableBufferPointer<UInt8>, videoFormat: CMFormatDescription, naluIndices: [NaluIndex]) -> CMSampleBuffer? {
        var err: OSStatus = 0
        var offset = 0

        let umrbp = UnsafeMutableRawBufferPointer(start: buffer.baseAddress, count: buffer.count)
        let bb = try! CMBlockBuffer.init(buffer: umrbp, deallocator: {(_, _) in /*buffer.deallocate()*/ }, flags: .assureMemoryNow)

        let pointer = UnsafeMutablePointer<UInt8>(OpaquePointer(buffer.baseAddress!))!
        for index in naluIndices {
            pointer.advanced(by: offset+0).pointee = UInt8((index.payloadSize >> 24) & 0xFF)
            pointer.advanced(by: offset+1).pointee = UInt8((index.payloadSize >> 16) & 0xFF)
            pointer.advanced(by: offset+2).pointee = UInt8((index.payloadSize >>  8) & 0xFF)
            pointer.advanced(by: offset+3).pointee = UInt8((index.payloadSize      ) & 0xFF)
            offset += 4
            
            offset += index.payloadSize
        }
        
        var sampleBuffer: CMSampleBuffer!
        err = CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: videoFormat, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        if err != 0 {
            print("CMSampleBufferCreate error")
            return nil
        }
        
        return sampleBuffer
    }
    
    static func feedVideoIntoDecoder(decompressionSession: VTDecompressionSession, nals: UnsafeMutableBufferPointer<UInt8>, timestamp: UInt64, videoFormat: CMFormatDescription, callback: @escaping (_ imageBuffer: CVImageBuffer?) -> Void) {
        var err:OSStatus = 0
        guard let sampleBuffer = annexBBufferToCMSampleBuffer(buffer: nals, videoFormat: videoFormat) else {
            print("Failed in annexBBufferToCMSampleBuffer")
            return
        }
        err = VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer: sampleBuffer, flags: ._EnableAsynchronousDecompression, infoFlagsOut: nil) { (status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, taggedBuffers: [CMTaggedBuffer]?, presentationTimeStamp: CMTime, presentationDuration: CMTime) in
        err = VTDecompressionSessionDecodeFrame(decompressionSession, sampleBuffer: sampleBuffer, flags: VTDecodeFrameFlags.init(rawValue: 0), infoFlagsOut: nil) { (status: OSStatus, infoFlags: VTDecodeInfoFlags, imageBuffer: CVImageBuffer?, taggedBuffers: [CMTaggedBuffer]?, presentationTimeStamp: CMTime, presentationDuration: CMTime) in
            //print(status, infoFlags, imageBuffer, taggedBuffers, presentationTimeStamp, presentationDuration)
            //print("status: \(status), image_nil?: \(imageBuffer == nil), infoFlags: \(infoFlags)")
            
            // If the decoder is failing somehow, request an IDR and get back on track
            if status < 0 && EventHandler.shared.framesSinceLastIDR > 90*2 {
                EventHandler.shared.framesSinceLastIDR = 0
                EventHandler.shared.resetEncoding()
                //alvr_report_fatal_decoder_error("VideoToolbox decoder failed with status: \(status)")
            }

            callback(imageBuffer)
        }
        if err != 0 {
            //fatalError("VTDecompressionSessionDecodeFrame")
        }
    }
}
