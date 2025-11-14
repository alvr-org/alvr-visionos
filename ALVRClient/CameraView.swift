//
//  CameraView.swift
//  Persona Avatar
//
//  Created by dev on 10/28/25.
//

import SwiftUI
import Combine
import AVFoundation
import CoreImage
import Vision
import Accelerate

struct CameraView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CameraModel()
    var enableDebug: Bool

    var body: some View {
        ZStack {
            if enableDebug {
                switch model.authorizationStatus {
                case .authorized:
                    ZStack {
                        if let image = model.currentCroppedImage {
                            Image(image, scale: 1.0, orientation: .up, label: Text("Camera frame"))
                                .resizable()
                                .scaledToFill()
                                .ignoresSafeArea()

                            // Overlay detected faces and a few landmark points
                            if let image = model.currentCroppedImage {
                                FaceOverlayView(faces: model.detectedFaces, imageSize: CGSize(width: image.width, height: image.height))
                                    .ignoresSafeArea()
                            }

                            VStack {
                                Spacer()
                                HStack {
                                    BlendShapesDebugView(blendShapes: model.blendShapes)
                                        .padding()
                                    Spacer()
                                }
                            }
                            .ignoresSafeArea()
                        } else {
                            Color.black.ignoresSafeArea()
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    Text("Tracking...")
                        .foregroundStyle(.secondary)
                case .notDetermined:
                    ProgressView("Requesting Camera Access…")
                case .denied, .restricted:
                    VStack(spacing: 12) {
                        Text("Camera Access Needed")
                            .font(.title2).bold()
                        Text("Please enable camera access in Settings to use the front camera.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Open Settings") { model.openSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                @unknown default:
                    Text("Camera unavailable")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await model.prepare()
            model.start()
        }
    }
}

struct DetectedFace: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect // in image pixel coordinates
    let landmarkPoints: [CGPoint] // subset of points in image pixel coordinates
}

struct DetectedFaceRect: Identifiable, Equatable {
    let id = UUID()
    let boundingBox: CGRect // in image pixel coordinates
}

struct BlendShape: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var value: Float
}

struct BlendShapesDebugView: View {
    let blendShapes: [String: Float]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blendShapes.keys.sorted(), id: \.self) { key in
                    let v = blendShapes[key] ?? 0
                    HStack(spacing: 8) {
                        Text(key)
                            .font(.caption)
                            .frame(width: 120, alignment: .leading)
                            .foregroundStyle(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.gray.opacity(0.2))
                                Capsule().fill(v > 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, abs(v)))))
                            }
                        }
                        .frame(height: 8)
                        Text(String(format: "%.2f", v))
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

struct FaceOverlayView: View {
    let faces: [DetectedFace]
    let imageSize: CGSize

    // Convert from image pixel space to screen space using GeometryReader
    func transform(point: CGPoint, in size: CGSize) -> CGPoint {
        // The base image uses .scaledToFill and .ignoresSafeArea(), so mapping exactly is complex.
        // Here we assume the ZStack stretches to the screen and the image is filling.
        // We'll map proportionally by fitting image into the available size preserving aspect ratio.
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = size.width / size.height
        var scale: CGFloat
        var xOffset: CGFloat = 0
        var yOffset: CGFloat = 0
        if imageAspect > viewAspect {
            // Image is wider; height matches, width cropped
            scale = size.height / imageSize.height
            let scaledWidth = imageSize.width * scale
            xOffset = (scaledWidth - size.width) / 2.0
        } else {
            // Image is taller; width matches, height cropped
            scale = size.width / imageSize.width
            let scaledHeight = imageSize.height * scale
            yOffset = (scaledHeight - size.height) / 2.0
        }
        let x = point.x * scale - xOffset
        let y = point.y * scale - yOffset
        return CGPoint(x: x, y: y)
    }

    func transform(rect: CGRect, in size: CGSize) -> CGRect {
        let tl = transform(point: CGPoint(x: rect.minX, y: rect.minY), in: size)
        let br = transform(point: CGPoint(x: rect.maxX, y: rect.maxY), in: size)
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(faces) { face in
                    let rect = transform(rect: face.boundingBox, in: geo.size)
                    Path { p in
                        p.addRect(rect)
                    }
                    .stroke(Color.green, lineWidth: 2)

                    ForEach(Array(face.landmarkPoints).indices, id: \.self) { idx in
                        let pt = transform(point: face.landmarkPoints[idx], in: geo.size)
                        Circle().fill(Color.red)
                            .frame(width: 4, height: 4)
                            .position(pt)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

final class CameraModel: NSObject, ObservableObject {
    
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    //@Published var currentFrameImage: CGImage?
    @Published var currentCroppedImage: CGImage?
    @Published var detectedFaceRect: DetectedFaceRect? = nil
    @Published var detectedFaces: [DetectedFace] = []
    @Published var blendShapes: [String: Float] = [:]

    nonisolated private let sequenceRequestHandler = VNSequenceRequestHandler()
    nonisolated private lazy var faceLandmarksRequest: VNDetectFaceLandmarksRequest = {
        let req = VNDetectFaceLandmarksRequest(completionHandler: self.handleFaceLandmarks)
        return req
    }()
    nonisolated private lazy var faceRectRequest: VNDetectFaceRectanglesRequest = {
        let req = VNDetectFaceRectanglesRequest(completionHandler: self.handleFaceRects)
        return req
    }()

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoOutputQueue = DispatchQueue(label: "camera.video.output.queue")
    private let ciContext = CIContext()
    private var currentFramePixelbuffer: CVImageBuffer? = nil
    private var currentCroppedPixelbuffer: CVImageBuffer? = nil
    private var currentFrameExtent: CGRect = CGRect()
    private var currentCroppedExtent: CGRect = CGRect()
    private var frameIdx = 0
    
    private var firstSampleMouthWidth = 0.35
    private var sampledInitialFace = false

    override init() {
        super.init()
    }

    @MainActor
    func prepare() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            self.authorizationStatus = granted ? .authorized : .denied
            if granted { configureSession() }
        } else {
            self.authorizationStatus = status
            if status == .authorized { configureSession() }
        }
    }

    @MainActor private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            // Remove existing inputs/outputs
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }

            // Front wide-angle camera
            
            let device = if #available(visionOS 2.1, *) {
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            } else {
                AVCaptureDevice.systemPreferredCamera
            }
            guard let camera = device, let input = try? AVCaptureDeviceInput(device: camera) else { return }

            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            // Configure video data output
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            // Set video connection orientation if possible
            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }

            // Set delegate
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
        }
    }

    @MainActor func start() {
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    @MainActor func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func openSettings() {
#if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#else
        // Not supported on this platform
#endif
    }
    
    func polygonArea(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 2 else { return 0 }
        var area: CGFloat = 0
        for i in 0..<pts.count {
            let j = (i + 1) % pts.count
            area += pts[i].x * pts[j].y - pts[j].x * pts[i].y
        }
        return abs(area) * 0.5
    }

    func computeEyeOpenness(landmark: VNFaceLandmarkRegion2D?) -> CGFloat {
        guard let landmark = landmark else { return 1.0 }

        func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
        let pts = (0..<landmark.pointCount).map { landmark.normalizedPoints[$0] }
        let area = polygonArea(pts)

        // Normalize by eye width squared (removes scale dependence)
        let width = pts.map(\.x).max()! - pts.map(\.x).min()!
        let normArea = area / (width * width)

        return clamp01(normArea)
    }

    private func handleFaceLandmarks(request: VNRequest, error: Error?) {
        guard error == nil else { return }
        guard let results = request.results as? [VNFaceObservation] else {
            Task { @MainActor in self.detectedFaces = [] }
            return
        }

        // Convert Vision normalized coordinates to image pixel coordinates
        // We assume the pixel buffer orientation used above (.leftMirrored) and size from the latest frame.
        Task { @MainActor in
            guard let pixelBuffer = self.currentCroppedPixelbuffer else {
                self.detectedFaces = []
                return
            }
            let imgW = CGFloat(self.currentCroppedExtent.width)
            let imgH = CGFloat(self.currentCroppedExtent.height)

            let mapped: [DetectedFace] = results.map { obs in
                // VNFaceObservation.boundingBox is normalized with origin at bottom-left in Vision coordinate space.
                let bb = obs.boundingBox
                let rect = CGRect(x: bb.minX * imgW, y: (1 - bb.maxY) * imgH, width: bb.width * imgW, height: bb.height * imgH)

                var points: [CGPoint] = []
                if let all = obs.landmarks {
                    let collect: [[CGPoint]?] = [
                        all.faceContour?.normalizedPoints,
                        all.leftEye?.normalizedPoints,
                        all.rightEye?.normalizedPoints,
                        all.nose?.normalizedPoints,
                        all.noseCrest?.normalizedPoints,
                        all.innerLips?.normalizedPoints,
                        all.outerLips?.normalizedPoints,
                        all.leftPupil?.normalizedPoints,
                        all.rightPupil?.normalizedPoints,
                        all.leftEyebrow?.normalizedPoints,
                        all.rightEyebrow?.normalizedPoints
                    ]
                    for arr in collect {
                        guard let arr else { continue }
                        for p in arr {
                            // Landmark points are in face-local coords [0,1] with origin bottom-left of the face bounding box in Vision space.
                            let x = (bb.minX + p.x * bb.width) * imgW
                            let y = (1 - (bb.minY + p.y * bb.height)) * imgH
                            points.append(CGPoint(x: x, y: y))
                        }
                    }
                }

                return DetectedFace(boundingBox: rect, landmarkPoints: points)
            }
            self.detectedFaces = mapped

            // Compute blendshapes from the first face if available (heuristic approximations)
            var newBlendShapes: [String: Float] = [:]
            if let first = results.first, let lm = first.landmarks {
                func clamp01(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
                func norm(_ v: CGFloat) -> Float { return Float(clamp01(v)) }
                // Helper to convert a landmark point from face-local to image space
                func faceToImage(_ p: CGPoint, bb: CGRect) -> CGPoint {
                    let x = (bb.minX + p.x * bb.width) * imgW
                    let y = (1 - (bb.minY + p.y * bb.height)) * imgH
                    return CGPoint(x: x, y: y)
                }
                func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
                func avg(_ pts: [CGPoint]) -> CGPoint {
                    guard !pts.isEmpty else { return .zero }
                    let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                    return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
                }
                let bb = first.boundingBox
                let faceW = bb.width * imgW
                let faceH = bb.height * imgH
                //let faceW = imgW
                //let faceH = imgH

                // Collect key groups in image space
                let inner = lm.innerLips?.normalizedPoints ?? []
                let outer = lm.outerLips?.normalizedPoints ?? []
                let leftEye = lm.leftEye?.normalizedPoints ?? []
                let rightEye = lm.rightEye?.normalizedPoints ?? []
                let leftPupil = lm.leftPupil?.normalizedPoints ?? []
                let rightPupil = lm.rightPupil?.normalizedPoints ?? []
                let leftBrow = lm.leftEyebrow?.normalizedPoints ?? []
                let rightBrow = lm.rightEyebrow?.normalizedPoints ?? []
                let nose = lm.nose?.normalizedPoints ?? []
                let noseCrest = lm.noseCrest?.normalizedPoints ?? []
                let faceContour = lm.faceContour?.normalizedPoints ?? []

                let innerImg = inner.map { faceToImage($0, bb: bb) }
                let outerImg = outer.map { faceToImage($0, bb: bb) }
                let lEyeImg = leftEye.map { faceToImage($0, bb: bb) }
                let rEyeImg = rightEye.map { faceToImage($0, bb: bb) }
                let lPupilImg = leftPupil.map { faceToImage($0, bb: bb) }
                let rPupilImg = rightPupil.map { faceToImage($0, bb: bb) }
                let lBrowImg = leftBrow.map { faceToImage($0, bb: bb) }
                let rBrowImg = rightBrow.map { faceToImage($0, bb: bb) }
                let noseImg = nose.map { faceToImage($0, bb: bb) }
                let noseCrestImg = noseCrest.map { faceToImage($0, bb: bb) }
                let contourImg = faceContour.map { faceToImage($0, bb: bb) }

                // Reference distances
                let eyeCenterDist = dist(avg(lEyeImg), avg(rEyeImg))
                let eyeEdgeLx = (lEyeImg.isEmpty ? 0 : (lEyeImg.min(by: { $0.x < $1.x })!.x))
                let eyeEdgeRx = (lEyeImg.isEmpty ? 0 : (lEyeImg.max(by: { $0.x < $1.x })!.x))
                let eyeEdgeDist = eyeEdgeRx - eyeEdgeLx
                let mouthWidth = (outerImg.isEmpty ? 0 : (outerImg.max(by: { $0.x < $1.x })!.x - outerImg.min(by: { $0.x < $1.x })!.x))
                let mouthHeight = (innerImg.isEmpty ? 0 : (innerImg.max(by: { $0.y < $1.y })!.y - innerImg.min(by: { $0.y < $1.y })!.y))
                let mouthCenter = avg(outerImg)
                
                let faceCenterX = (bb.minX * imgW) + faceW * 0.5
                
                let noseHeight = (noseCrestImg.isEmpty ? 0 : (noseCrestImg.max(by: { $0.y < $1.y })!.y - noseCrestImg.min(by: { $0.y < $1.y })!.y))

                if frameIdx > 30 && !self.sampledInitialFace {
                    self.firstSampleMouthWidth = mouthWidth / faceW
                    self.sampledInitialFace = true
                }

                // jawOpen
                var jawDropCurrent: Float = 0.0
                if !innerImg.isEmpty {
                    let v = clamp01((mouthHeight / faceH) * 4.0)
                    jawDropCurrent = norm(v)
                    newBlendShapes["jawDrop"] = jawDropCurrent
                }
                // jawLeft / jawRight (horizontal offset of mouth center vs face center)
                if !outerImg.isEmpty {
                    let dx = (mouthCenter.x - faceCenterX) / faceW
                    newBlendShapes["jawSidewaysRight"] = 0.0//norm(max(0, dx * 3.0))
                    newBlendShapes["jawSidewaysLeft"] = 0.0//norm(max(0, -dx * 3.0))
                }
                // jawForward (mouth protrusion approximated by increased inner lip height vs width)
                if mouthWidth > 0 {
                    let ratio = (mouthHeight / mouthWidth)
                    newBlendShapes["jawThrust"] = 0.0//norm((ratio - 0.25) * 3.0)
                }
                
                let baseMouthWidth = self.firstSampleMouthWidth
                
                // mouthSmile (width increase)
                if mouthWidth > 0 {
                    let base = mouthWidth / faceW
                    let smile = max(0, base - baseMouthWidth) / (baseMouthWidth * 0.125)
                    print(baseMouthWidth)
                    newBlendShapes["lipCornerPullerL"] = norm(CGFloat(smile))
                    newBlendShapes["lipCornerPullerR"] = norm(CGFloat(smile))
                }
                // mouthFrown (corners lower than center)
                if !outerImg.isEmpty {
                    let leftCorner = outerImg.min(by: { $0.x < $1.x })!
                    let rightCorner = outerImg.max(by: { $0.x < $1.x })!
                    let centerY = avg(outerImg).y
                    let down = max(0, (leftCorner.y - centerY) / faceH) + max(0, (rightCorner.y - centerY) / faceH)
                    var val = norm((down * 6.0 * 4.0) - 0.7)
                    
                    if jawDropCurrent > 0.5 {
                        val = 0.0
                    }
                    newBlendShapes["lipCornerDepressorL"] = val
                    newBlendShapes["lipCornerDepressorR"] = val
                }
                
                let funnelBaseline = 0.3
                // mouthFunnel (height increases strongly relative to width)
                if mouthWidth > 0 {
                    let ratio = (mouthHeight / faceH) / max(0.001, (mouthWidth / faceW))
                    let val = norm(ratio - funnelBaseline) * 0.5
                    newBlendShapes["lipFunnelerLB"] = val
                    newBlendShapes["lipFunnelerRB"] = val
                    newBlendShapes["lipFunnelerLT"] = val
                    newBlendShapes["lipFunnelerRT"] = val
                }
                
                // mouthPucker (width decreases while height increases)
                if mouthWidth > 0 {
                    let w = mouthWidth / faceW
                    let h = mouthHeight / faceH
                    let pucker = clamp01((baseMouthWidth - w) * 3.0 + h * 1.0)
                    var val = norm((pucker * 3.0) - CGFloat(jawDropCurrent))
                    newBlendShapes["lipPuckerL"] = val
                    newBlendShapes["lipPuckerR"] = val
                }
                
                // mouthDimpleL/R (corners pull inward horizontally)
                if !outerImg.isEmpty {
                    let leftCorner = outerImg.min(by: { $0.x < $1.x })!
                    let rightCorner = outerImg.max(by: { $0.x < $1.x })!
                    let centerX = avg(outerImg).x
                    let leftIn = max(0, (centerX - leftCorner.x) / faceW)
                    let rightIn = max(0, (rightCorner.x - centerX) / faceW)
                    newBlendShapes["dimplerL"] = 0.0//norm(leftIn * 6.0)
                    newBlendShapes["dimplerR"] = 0.0//norm(rightIn * 6.0)
                }
                // mouthStretch L/R (corners move outward)
                if !outerImg.isEmpty {
                    let leftCorner = outerImg.min(by: { $0.x < $1.x })!
                    let rightCorner = outerImg.max(by: { $0.x < $1.x })!
                    let centerX = avg(outerImg).x
                    let leftOut = max(0, (leftCorner.x - centerX) / faceW)
                    let rightOut = max(0, (centerX - rightCorner.x) / faceW)
                    newBlendShapes["lipStretcherL"] = norm(leftOut * 6.0)
                    newBlendShapes["lipStretcherR"] = norm(rightOut * 6.0)
                }
                // mouthShrug (upper and lower lips move toward center vertically)
                if !innerImg.isEmpty {
                    let top = innerImg.max(by: { $0.y < $1.y })!.y
                    let bottom = innerImg.min(by: { $0.y < $1.y })!.y
                    let centerY = avg(outerImg.isEmpty ? innerImg : outerImg).y
                    let towardCenter = max(0, (centerY - bottom) / faceH) + max(0, (top - centerY) / faceH)
                    newBlendShapes["chinRaiserT"] = norm(towardCenter * 3.0)
                    newBlendShapes["chinRaiserB"] = norm(towardCenter * 3.0)
                }
                // cheekPuff (cheek outward vs face contour)
                if !contourImg.isEmpty && !outerImg.isEmpty {
                    let midY = avg(outerImg).y
                    let leftCheek = contourImg.dropFirst().prefix(contourImg.count/4) // rough left cheek region
                    let rightCheek = contourImg.suffix(contourImg.count/4) // rough right cheek region
                    let leftAvg = avg(leftCheek.filter { abs($0.y - midY) < faceH * 0.15 })
                    let rightAvg = avg(rightCheek.filter { abs($0.y - midY) < faceH * 0.15 })
                    // Compare cheek outwardness relative to face center
                    let centerX = (bb.minX * imgW) + faceW * 0.5
                    let puff = (abs(leftAvg.x - centerX) + abs(rightAvg.x - centerX)) / faceW
                    let val = norm((puff - 0.45) * 3.0)
                    newBlendShapes["cheekPuffL"] = 0.0//val
                    newBlendShapes["cheekPuffR"] = 0.0//val
                }
                // cheekSquint L/R (eye squint contribution + cheek raise)
                func eyeOpenMetric(_ pts: [CGPoint]) -> CGFloat {
                    guard pts.count >= 6 else { return 0 }
                    let top = pts.max(by: { $0.y < $1.y })!.y
                    let bottom = pts.min(by: { $0.y < $1.y })!.y
                    return (top - bottom) / ((eyeEdgeDist + eyeCenterDist) * 0.5)
                }
                let lEyeOpen = eyeOpenMetric(lEyeImg)
                let rEyeOpen = eyeOpenMetric(rEyeImg)
                newBlendShapes["cheekRaiserL"] = norm((0.06 - lEyeOpen) * 8.0 * 3.33)
                newBlendShapes["cheekRaiserR"] = norm((0.06 - rEyeOpen) * 8.0 * 3.33)
                // eyeBlink L/R
                let eyeOpenMin = 0.07
                let eyeOpenMax = 0.12
                let eyeOpenRange = eyeOpenMax - eyeOpenMin
                //let lEyeClosed = (lEyeOpen - eyeOpenMin) / eyeOpenRange
                //let rEyeClosed = (rEyeOpen - eyeOpenMin) / eyeOpenRange
                let lEyeOpened = norm(computeEyeOpenness(landmark: lm.leftEye) * 4.5)
                let rEyeOpened = norm(computeEyeOpenness(landmark: lm.rightEye) * 4.5)
                let lEyeClosed = CGFloat(1.0 - lEyeOpened)
                let rEyeClosed = CGFloat(1.0 - rEyeOpened)
                newBlendShapes["eyesClosedL"] = norm((lEyeClosed - 0.5) * 2.0)//norm(lEyeClosed)
                newBlendShapes["eyesClosedR"] = norm((rEyeClosed - 0.5) * 2.0)//norm(rEyeClosed)
                print(newBlendShapes["eyesClosedL"], newBlendShapes["eyesClosedR"], "lr", lEyeOpened, rEyeOpened)
                // eyeSquint L/R (milder than blink)
                newBlendShapes["lidTightenerL"] = norm(lEyeClosed)//norm((lEyeClosed - 0.9) * 10.0)
                newBlendShapes["lidTightenerR"] = norm(rEyeClosed)//norm((rEyeClosed - 0.9) * 10.0)
                // eyeLook Up/Down/Left/Right (pupil/eye centroid relative to socket)
                func eyeLook(_ eye: [CGPoint], _ pupil: [CGPoint]) -> (up: Float, down: Float, left: Float, right: Float) {
                    guard !eye.isEmpty else { return (0,0,0,0) }
                    /*let avgEye = avg(eye)
                    var smallestDistSq = 999999.0
                    var c = avgEye
                    
                    // Find the pupil point
                    for pt in eye {
                        let xDist = avgEye.x-pt.x
                        let yDist = avgEye.y-pt.y
                        let distSq = (xDist*xDist)+(yDist*yDist)
                        if distSq < smallestDistSq {
                            smallestDistSq = distSq
                            c = pt
                        }
                    }*/
                    let c = avg(pupil)

                    let minX = eye.min(by: { $0.x < $1.x })!.x
                    let maxX = eye.max(by: { $0.x < $1.x })!.x
                    let minY = eye.min(by: { $0.y < $1.y })!.y
                    let maxY = eye.max(by: { $0.y < $1.y })!.y
                    
                    let relX = (c.x - (minX))
                    let dx = (relX / max(0.001, (maxX - minX))) // 0.0 to 1.0
                    let centeredDx = (dx - 0.5) // change to -0.5 to 0.5
                    
                    //let relY = (c.y - (minY))
                    //let dy = (relY / max(0.001, (maxY - minY)))
                    //let centeredDy = (dy - 0.5)
                    
                    // TODO, eyelids don't really close evenly
                    //let eyesWideOpenEstimate = (maxX - minX) * 0.3
                    let eyesWideOpenEstimate = (maxY - minY)
                    let relY = (c.y - (minY) - (eyesWideOpenEstimate * 0.5))
                    let dy = (relY / max(0.001, eyesWideOpenEstimate))
                    let centeredDy = (-dy)
                    
                    //print(relY, dx, dy, centeredDx, centeredDy)

                    //print(maxX, minX, maxY, minY, "c", c.x, c.y, "rel", relX, relY, "dxdy", dx, dy, centeredDx, centeredDy)
                    //print(centeredDx, centeredDy)
                    let up = norm(-(centeredDy) * 2.0)
                    let down = norm((centeredDy) * 2.0)
                    let left = norm(-(centeredDx) * 2.0)
                    let right = norm((centeredDx) * 2.0)
                    return (up, down, left, right)
                }
                let lLook = eyeLook(lEyeImg, lPupilImg)
                let rLook = eyeLook(rEyeImg, rPupilImg)
                //print(lLook)
                
                newBlendShapes["eyesLookUpL"] = lLook.up
                newBlendShapes["eyesLookDownL"] = lLook.down
                newBlendShapes["eyesLookLeftL"] = lLook.right // TODO double check
                newBlendShapes["eyesLookRightL"] = lLook.left
                newBlendShapes["eyesLookUpR"] = rLook.up
                newBlendShapes["eyesLookDownR"] = rLook.down
                newBlendShapes["eyesLookLeftR"] = rLook.right
                newBlendShapes["eyesLookRightR"] = rLook.left
                // browUp / browDown L/R and browOuterUp
                if !lBrowImg.isEmpty && !rBrowImg.isEmpty && !lEyeImg.isEmpty && !rEyeImg.isEmpty {
                    let lb = lBrowImg.max(by: { $0.y < $1.y })!.y
                    let le = lEyeImg.min(by: { $0.y < $1.y })!.y
                    let rb = rBrowImg.max(by: { $0.y < $1.y })!.y
                    let re = rEyeImg.min(by: { $0.y < $1.y })!.y
                    let leftLift = (lb - le) / faceH
                    let rightLift = (rb - re) / faceH
                    newBlendShapes["innerBrowRaiserL"] = norm(leftLift * 8.0)
                    newBlendShapes["innerBrowRaiserR"] = norm(rightLift * 8.0)
                    newBlendShapes["browLowererL"] = norm(CGFloat((1.0 - norm((0.08 - leftLift) * 8.0)) * 5.0))
                    newBlendShapes["browLowererR"] = norm(CGFloat((1.0 - norm((0.08 - rightLift) * 8.0)) * 5.0))
                    // Outer up: compare outer-most brow points vs inner-most
                    let lOuter = lBrowImg.max(by: { $0.x < $1.x })!
                    let lInner = lBrowImg.min(by: { $0.x < $1.x })!
                    let rOuter = rBrowImg.min(by: { $0.x < $1.x })!
                    let rInner = rBrowImg.max(by: { $0.x < $1.x })!
                    let lOuterUp = (lOuter.y - lInner.y) / faceH
                    let rOuterUp = (rOuter.y - rInner.y) / faceH
                    newBlendShapes["outerBrowRaiserL"] = norm(lOuterUp * 4.0)
                    newBlendShapes["outerBrowRaiserR"] = norm(rOuterUp * 4.0)
                }
                // noseSneer L/R (nostril flare approximated by nose width)
                if !noseImg.isEmpty {
                    let minX = noseImg.min(by: { $0.x < $1.x })!.x
                    let maxX = noseImg.max(by: { $0.x < $1.x })!.x
                    let width = (maxX - minX) / faceW
                    let sneer = max(0, width - 0.12) * 6.0
                    newBlendShapes["noseWrinklerL"] = 0.0//norm(CGFloat(sneer))
                    newBlendShapes["noseWrinklerR"] = 0.0//norm(CGFloat(sneer))
                }
                // tongueOut (use inner mouth height beyond jawOpen as proxy)
                if mouthHeight > 0 {
                    let t = max(0, (mouthHeight / faceH) - 0.12) * 4.0
                    newBlendShapes["tongueOut"] = 0.0//norm(t)
                }
            }
            self.blendShapes = newBlendShapes
            
            for shape in self.blendShapes {
                let idx = XrFaceExpression2FB.fromString[shape.key, default: XrFaceExpression2FB.count].rawValue
                if idx < XrFaceExpression2FB.count.rawValue {
                    WorldTracker.shared.fbFaceTracking[idx] = shape.value
                }
                else {
                    print("Failed to map:", shape.key)
                }
            }
            WorldTracker.shared.fbFaceTrackingValid = true
        }
    }
    
    /*func cropAndScalePixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        cropRect: CGRect,
        scale: CGFloat,
        ciContext: CIContext = CIContext(options: nil)
    ) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Crop and scale
        let cropped = ciImage.cropped(to: cropRect)
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Create output buffer
        var outputBuffer: CVPixelBuffer?
        let outputWidth = Int(cropRect.width * scale)
        let outputHeight = Int(cropRect.height * scale)
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        
        CVPixelBufferCreate(
            nil,
            outputWidth,
            outputHeight,
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            attrs,
            &outputBuffer
        )
        
        guard let outputBuffer else { return nil }

        ciContext.render(scaled, to: outputBuffer)
        return outputBuffer
    }*/
    
    func cropAndScaleWithVImage(
        _ pixelBuffer: CVPixelBuffer,
        cropRect: CGRect,
        scale: CGFloat
    ) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        var srcBuffer = vImage_Buffer(
            data: baseAddr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )

        // Create destination buffer
        let dstWidth = Int(cropRect.width * scale)
        let dstHeight = Int(cropRect.height * scale)
        
        var dstBuffer = vImage_Buffer()
        vImageBuffer_Init(
            &dstBuffer,
            vImagePixelCount(dstHeight),
            vImagePixelCount(dstWidth),
            32, // bits per pixel (ARGB8888 for example)
            vImage_Flags(kvImageNoFlags)
        )

        // Crop
        var cropped = vImage_Buffer(
            data: srcBuffer.data.advanced(by: Int(cropRect.origin.y) * bytesPerRow + Int(cropRect.origin.x) * 4),
            height: vImagePixelCount(cropRect.height),
            width: vImagePixelCount(cropRect.width),
            rowBytes: bytesPerRow
        )
        
        // Scale
        vImageScale_ARGB8888(&cropped, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        
        // Wrap into a new CVPixelBuffer
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreateWithBytes(
            nil,
            dstWidth,
            dstHeight,
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            dstBuffer.data,
            dstBuffer.rowBytes,
            //{ _, ptr in free(ptr) },
            nil,
            nil,
            nil,
            &newPixelBuffer
        )
        
        return newPixelBuffer
    }
    
    private func handleFaceRects(request: VNRequest, error: Error?) {
        guard error == nil else { return }
        guard let results = request.results as? [VNFaceObservation] else {
            Task { @MainActor in self.detectedFaces = [] }
            return
        }

        // Convert Vision normalized coordinates to image pixel coordinates
        // We assume the pixel buffer orientation used above (.leftMirrored) and size from the latest frame.
        Task { @MainActor in
            guard let pixelBuffer = self.currentFramePixelbuffer else {
                self.detectedFaces = []
                return
            }
            let imgW = CGFloat(self.currentFrameExtent.width)
            let imgH = CGFloat(self.currentFrameExtent.height)

            let mapped: [DetectedFaceRect] = results.map { obs in
                // VNFaceObservation.boundingBox is normalized with origin at bottom-left in Vision coordinate space.
                let bb = obs.boundingBox
                let rect = CGRect(x: bb.minX * imgW, y: (1 - bb.maxY) * imgH, width: bb.width * imgW, height: bb.height * imgH)

                return DetectedFaceRect(boundingBox: rect)
            }
            self.detectedFaceRect = mapped.first
            
            
            EventHandler.shared.trackingWorker.enqueue {
                let cropRectBase = self.detectedFaceRect?.boundingBox ?? CGRect()
                let cropRect = CGRect(
                    x: floor(max(cropRectBase.minX - (cropRectBase.width * 0.25), 0.0)),
                    y: floor(max(cropRectBase.minY - (cropRectBase.height * 0.25), 0.0)),
                    width: floor(max(cropRectBase.width + (cropRectBase.width * 0.25), 0.0)),
                    height: floor(max(cropRectBase.height + (cropRectBase.height * 0.4), 0.0))
                )
                let cropped: CVImageBuffer? = self.cropAndScaleWithVImage(pixelBuffer, cropRect: cropRect, scale: 0.125)
                
                if let cropped = cropped {
                    let ciImage = CIImage(cvPixelBuffer: cropped)
                    self.currentCroppedPixelbuffer = cropped
                    self.currentCroppedExtent = ciImage.extent
                    
                    if ALVRClientApp.gStore.settings.showFaceTrackingDebug {
                        if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                            Task { @MainActor in
                                self.currentCroppedImage = cgImage
                            }
                        }
                    }
                    do {
                        try self.sequenceRequestHandler.perform([self.faceLandmarksRequest], on: cropped, orientation: .up)
                        //try self.sequenceRequestHandler.perform([self.faceLandmarksRequest], on: pixelBuffer, orientation: .up)
                    } catch {
                        // If Vision fails, we still continue to produce frames
                    }
                }
            }
        }
    }
}

nonisolated extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        self.frameIdx += 1
        if (self.frameIdx & 1) != 1 {
            return
        }

        // Run Vision face landmarks request on the same output queue
        EventHandler.shared.trackingWorker.enqueue {
            do {
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                self.currentFramePixelbuffer = pixelBuffer
                self.currentFrameExtent = ciImage.extent
        
                // Extract the rect and scale down
                //try self.sequenceRequestHandler.perform([self.faceRectRequest], on: pixelBuffer, orientation: .up)
                
                // Run it directly
                self.currentCroppedPixelbuffer = pixelBuffer
                self.currentCroppedExtent = ciImage.extent
                Task { @MainActor in
                    if ALVRClientApp.gStore.settings.showFaceTrackingDebug {
                        if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                            self.currentCroppedImage = cgImage
                        }
                    }
                }
                
                try self.sequenceRequestHandler.perform([self.faceLandmarksRequest], on: pixelBuffer, orientation: .up)
            } catch {
                // If Vision fails, we still continue to produce frames
            }
        }
    }
}
