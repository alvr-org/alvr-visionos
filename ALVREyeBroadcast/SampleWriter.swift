//
//  SampleWriter.swift
//  test
//
//  Created by linjj on 2019/6/21.
//  Copyright © 2019 linjj. All rights reserved.
//

import UIKit
import AVFoundation

enum BaseResult {
    case success
    case failure(String)
}

extension Date {
    
    static let dateFormatter: DateFormatter = iso8601DateFormatter()
    fileprivate static func iso8601DateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return formatter
    }
    
    // http://nshipster.com/nsformatter/
    // http://unicode.org/reports/tr35/tr35-6.html#Date_Format_Patterns
    public func iso8601() -> String {
        return Date.iso8601DateFormatter().string(from: self)
    }
    
}

class SampleWriter {
    
    enum AudioSource {
        case mic
        case app
    }
    
    var filePath: String?
    var callBack: ((BaseResult) -> Void)?
    
    fileprivate var audioMicInput: AVAssetWriterInput?
    fileprivate var audioMicSettings: [String : Any] = defaultAudioSettings()
    
    fileprivate var audioAppInput: AVAssetWriterInput?
    
    
    fileprivate var videoInput: AVAssetWriterInput?
    fileprivate var videoSettings: [String : Any] = defaultVideoSettings()
    fileprivate var writer: AVAssetWriter?
    fileprivate var lastTime = CMTime.zero
    
    fileprivate var videoStarted = false
    
    fileprivate let writerQueue = DispatchQueue(label: "writerQueue")
    
    fileprivate class func defaultAudioSettings() -> [String : Any] {
        return [
            AVFormatIDKey : kAudioFormatMPEG4AAC,
            AVSampleRateKey : 44100,
            AVEncoderBitRateKey : 128000,
            AVNumberOfChannelsKey: 1
        ]
    }
    
    fileprivate class func defaultVideoSettings() -> [String : Any] {
        
        
        let screenSize = CGSize(width: 1920, height: 1080)//UIScreen.main.bounds.size
        let screenScale = 1.0//UIScreen.main.scale
        var codec = AVVideoCodecType(rawValue: "")
        codec = AVVideoCodecType.h264
        
        let videoCleanApertureSettings = [AVVideoCleanApertureHeightKey: screenSize.height * screenScale,
                                          AVVideoCleanApertureWidthKey: screenSize.width * screenScale,
                                          AVVideoCleanApertureHorizontalOffsetKey: 2,
                                          AVVideoCleanApertureVerticalOffsetKey: 2
        ]
        let codecSettings  = [AVVideoAverageBitRateKey: 1024000,
                              AVVideoCleanApertureKey: videoCleanApertureSettings
            ] as [String : Any]
        
        let videoSettings = [AVVideoCodecKey: codec,
                             AVVideoCompressionPropertiesKey: codecSettings,
                             AVVideoHeightKey: screenSize.height * screenScale, AVVideoWidthKey: screenSize.width * screenScale] as [String : Any]
        return videoSettings
    }
    
    internal var _startTimestamp: CMTime = CMTime.invalid
    
    static let shared = SampleWriter()
    
    internal class func assetWriterMetadata() -> [AVMutableMetadataItem] {
        let currentDevice = UIDevice.current
        
        let modelItem = AVMutableMetadataItem()
        modelItem.keySpace = AVMetadataKeySpace.common
        modelItem.key = AVMetadataKey.commonKeyModel as (NSCopying & NSObjectProtocol)
        modelItem.value = currentDevice.localizedModel as (NSCopying & NSObjectProtocol)
        
        let softwareItem = AVMutableMetadataItem()
        softwareItem.keySpace = AVMetadataKeySpace.common
        softwareItem.key = AVMetadataKey.commonKeySoftware as (NSCopying & NSObjectProtocol)
        softwareItem.value = "prfCloud" as (NSCopying & NSObjectProtocol)
        
        let artistItem = AVMutableMetadataItem()
        artistItem.keySpace = AVMetadataKeySpace.common
        artistItem.key = AVMetadataKey.commonKeyArtist as (NSCopying & NSObjectProtocol)
        artistItem.value = "prfCloud" as (NSCopying & NSObjectProtocol)
        
        let creationDateItem = AVMutableMetadataItem()
        creationDateItem.keySpace = AVMetadataKeySpace.common
        creationDateItem.key = AVMetadataKey.commonKeyCreationDate as (NSCopying & NSObjectProtocol)
        creationDateItem.value = Date().iso8601() as (NSCopying & NSObjectProtocol)
        
        return [modelItem, softwareItem, artistItem, creationDateItem]
    }
    
    func setupAudioInput(withSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        audioMicInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey : kAudioFormatMPEG4AAC], sourceFormatHint: formatDescription)
        
        audioAppInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey : kAudioFormatMPEG4AAC], sourceFormatHint: formatDescription)
        
        if let audioInput = audioMicInput {
            audioInput.expectsMediaDataInRealTime = true
        }
        
        if let audioAppInput = audioAppInput {
            audioAppInput.expectsMediaDataInRealTime = true
        }
    }
    
    func setupVideoInput(withSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        var codec = AVVideoCodecType(rawValue: "")
        codec = AVVideoCodecType.h264
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec], sourceFormatHint: formatDescription)
        if let videoInput = videoInput {
            videoInput.expectsMediaDataInRealTime = true
        }
    }
    
    fileprivate func setupWriter(withFilePath filePath: String) -> BaseResult {
        
//        guard let sharedUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.newcunnar.test") else {
//            return
//        }
//        let testPath = sharedUrl.path + "/aaaa.txt"
//        do {
//            try "tetetetet".write(toFile: testPath, atomically: true, encoding: .utf8)
//        }
//        catch {
//            return
//        }
//
//        let path = sharedUrl.path + "/video/tmp.mp4"
        if FileManager.default.fileExists(atPath: filePath) {
//            try? FileManager.default.removeItem(atPath: filePath)
            return .failure("file exists")
        }
        
//        FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
        do {
            if writer == nil {
                writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: filePath), fileType: .mp4)
//                writer?.movieFragmentInterval = CMTime(value: 1, timescale: 1000000)
                writer?.shouldOptimizeForNetworkUse = false
            }
            
            if let writer = writer,
                let videoInput = videoInput,
                let audioMicInput = audioMicInput,
                let audioAppInput = audioAppInput {
                writer.shouldOptimizeForNetworkUse = true
                writer.metadata = SampleWriter.assetWriterMetadata()
                writer.add(videoInput)
                writer.add(audioMicInput)
                writer.add(audioAppInput)
                if writer.startWriting() {
                    print("success")
                } else {
                    return .failure("startWriting failed")
                }
            }

            
            
        } catch {
//            print("error")
            return .failure("\(error)")
        }
        return .success
    }
    
    func startSessionIfNecessary(timestamp: CMTime) {
        if !self._startTimestamp.isValid {
            self._startTimestamp = timestamp
            self.writer?.startSession(atSourceTime: timestamp)
        }
    }
    
    func write(videoBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.writeOperate(videoBuffer:videoBuffer)
        }
    }
  
    func writeOperate(videoBuffer: CMSampleBuffer) {
        if videoInput == nil {
            setupVideoInput(withSampleBuffer: videoBuffer)
        }
        guard let videoInput = videoInput, let _ = audioMicInput, let _ = audioAppInput else {
            return
        }
        if writer == nil, let filePath = filePath {
            
            let result = setupWriter(withFilePath: filePath)
            callBack?(result)
        }
        startSessionIfNecessary(timestamp: CMSampleBufferGetPresentationTimeStamp(videoBuffer))
        videoStarted = true
        let timeStamp = CMSampleBufferGetPresentationTimeStamp(videoBuffer)
//        PCPrint("(\(Double(timeStamp.value)/Double(timeStamp.timescale)))video:\(timeStamp)")
        if timeStamp > lastTime {
            lastTime = timeStamp
        }
        
        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(videoBuffer) {
                
            } else {
                print("video append error")
            }
        } else {
            print("video unready")
        }
    }
    
    func write(audioBuffer: CMSampleBuffer, audioSource: AudioSource) {
        writerQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.writeOperate(audioBuffer:audioBuffer, audioSource: audioSource)
        }
    }
    
    func writeOperate(audioBuffer: CMSampleBuffer, audioSource: AudioSource) {
        
        let audioCurInput = audioSource == .mic ? audioMicInput : audioAppInput
        if audioCurInput == nil {
            setupAudioInput(withSampleBuffer: audioBuffer)
        }
        guard let audioInput = audioSource == .mic ? audioMicInput : audioAppInput,
            let _ = videoInput else {
            return
        }
        
        if writer == nil, let filePath = filePath {
            
            let result = setupWriter(withFilePath: filePath)
            callBack?(result)
        }
        
        guard CMSampleBufferDataIsReady(audioBuffer) else {
            return
        }
        
        guard videoStarted else {
            return
        }
        
//        let timeStamp = CMSampleBufferGetPresentationTimeStamp(audioBuffer)
//        let duration = CMSampleBufferGetDuration(audioBuffer)
//        PCPrint("(\(Double(timeStamp.value)/Double(timeStamp.timescale)))audio:\(timeStamp),duration: \(duration)")

        if audioInput.isReadyForMoreMediaData {
            if audioInput.append(audioBuffer) {
                
            } else {
                print("audion append error")
            }
        } else {
            print("audio unready")
        }

    }

    
    func finishWriting(completionHandler handler: @escaping (Error?) -> Void) {
        audioMicInput?.markAsFinished()
        audioAppInput?.markAsFinished()
        videoInput?.markAsFinished()
        writer?.endSession(atSourceTime: lastTime)
        if let writer = writer {
            writer.finishWriting {
                if writer.status == .completed {
                    handler(nil)
                } else {
                    handler(writer.error)
                }
            }
        }
        audioMicInput = nil
        audioAppInput = nil
        videoInput = nil
//        writer?.finishWriting(completionHandler: handler)
//        PCLogManager.default.willTermiate()
    }
}
