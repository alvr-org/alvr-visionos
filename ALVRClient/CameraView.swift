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
import simd
import AudioToolbox

extension VNFaceLandmarkRegion2D {
    func rotatedTranslated(by angle: Float, center: CGPoint, translate: CGPoint, scale: CGFloat = 1.0) -> [CGPoint] {
        let sinA = sin(angle)   // negative = undo roll
        let cosA = cos(angle)

        let R = float2x2(
            SIMD2(cosA, -sinA),
            SIMD2(sinA,  cosA)
        )

        return normalizedPoints.map { p in
            let v = SIMD2(Float(p.x - center.x), Float(p.y - center.y))
            let r = R * v
            return CGPoint(x: (CGFloat(r.x) + center.x + translate.x) * scale,
                           y: (CGFloat(r.y) + center.y + translate.y) * scale)
        }
    }
}

// Incremental running mean: fold the n-th sample x into mean m in place. Used to average the neutral
// pose across the calibration window so per-frame landmark noise doesn't bake into the baseline.
private func accMean(_ m: inout Double, _ x: Double, _ n: Double) { m += (x - m) / n }
private func accMean(_ m: inout CGFloat, _ x: CGFloat, _ n: CGFloat) { m += (x - m) / n }
private func accMean(_ m: inout Float, _ x: Float, _ n: Float) { m += (x - m) / n }

// Initial calibration sequence: average a still neutral pose, then prompt to close eyes and capture that
// reference. After `.done`, neutral re-averages periodically (cooldown); the closed reference stays.
enum CalibPhase { case neutral, closing, done }

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
                    VStack(spacing: 8) {
                        if model.needsCalibrationButton {
                            Button("Calibrate Face Tracking") { model.beginCalibration() }
                                .buttonStyle(.borderedProminent)
                        } else if model.isCalibrating || !model.hasCalibratedOnce {
                            Label(model.calibPhase == .closing ? "Calibrating — close your eyes" : "Calibrating — hold a neutral pose", systemImage: "circle.fill")
                                .foregroundStyle(.orange)
                                .font(.headline)
                                .symbolEffect(.pulse)
                        } else {
                            Text("Tracking...")
                                .foregroundStyle(.secondary)
#if ENABLE_FACE_RECALIBRATION
                            Text(String(format: "Next recalibration in %.0fs", model.secondsUntilRecalib))
                                .font(.caption)
                                .foregroundStyle(.secondary)
#endif
                        }
                    }
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

            // Non-debug: the only face-tracking UI the user ever sees — a transient prompt shown right
            // after the camera initializes, until the neutral-pose baselines finish capturing. (Debug has
            // its own inline recalibration indicator.)
            if !model.hasCalibratedOnce && !enableDebug {
                VStack(spacing: 24) {
                    if model.needsCalibrationButton {
                        Text("Calibrate Face Tracking")
                            .font(.system(size: 56, weight: .bold))
                        Text("Look forward with a relaxed, neutral expression, then press Calibrate.")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Calibrate") { model.beginCalibration() }
                            .font(.system(size: 32, weight: .semibold))
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(2.0)
                            .padding(.bottom, 12)
                        Text(model.calibPhase == .closing ? "Close your eyes" : "Hold a neutral pose")
                            .font(.system(size: 56, weight: .bold))
                        Text(model.calibPhase == .closing ? "Capturing closed-eye reference…" : "Calibrating face tracking…")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(56)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 32))
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
            VStack(alignment: .trailing) {
                ForEach(blendShapes.keys.filter { blendShapes[$0] != nil }.sorted(), id: \.self) { key in
                    let v = blendShapes[key] ?? 0
                    HStack(spacing: 12) {
                        Text(key)
                            .font(.title)
                            .dynamicTypeSize(DynamicTypeSize.large)
                            .frame(width: 240,  height: 20, alignment: .leading)
                            .foregroundStyle(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.gray)
                                Capsule().fill(v > 0 ? Color.green : Color.red)
                                    .frame(width: geo.size.width * CGFloat(max(0, min(1, abs(v)))))
                            }
                        }
                        .frame(height: 20)
                        Text(String(format: "%.2f", v))
                            .font(.subheadline)
                            .dynamicTypeSize(DynamicTypeSize.large)
                            .monospacedDigit()
                            .frame(width: 64, height: 20, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: 720)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 1)
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
    // isCalibrating: true only while actively averaging a still-pose burst (drives the debug indicator).
    // hasCalibratedOnce: false until the first calibration completes (drives the one-time entry prompt).
    @Published var isCalibrating = false
    @Published var hasCalibratedOnce = false
    @Published var calibPhase: CalibPhase = .neutral
    @Published var secondsUntilRecalib: Double = 0   // debug countdown to next neutral refresh
    @Published var needsCalibrationButton = false    // face tracking on but no saved calibration -> show button
    private var calibrationRequested = false         // user pressed Calibrate; gates the neutral capture
    private var calibrationRequestedTime: Double = 0 // systemUptime when Calibrate was pressed
    private let calibStartDelaySeconds: Double = 1.0 // settle time after pressing before capture begins
    private var closingStart: Double = 0             // systemUptime when the close-eyes phase began
    private var closingMinRawL: Float = 1.0          // min raw openness seen while closing (L)
    private var closingMinRawR: Float = 1.0
    private let calibClosingSeconds: Double = 3.5    // how long the close-eyes capture window lasts

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
    private var firstSampleMouthWidthL = 0.35*0.5
    private var firstSampleMouthWidthR = 0.35*0.5
    private var firstSampleMouthCenterX = 0.5
    private var firstSampleMouthCenterY = 0.0
    private var firstSampleMouthMinX = 0.1
    private var firstSampleMouthMaxX = 0.4
    private var firstSampleEyeWidthL: CGFloat = CGFloat(0.35) // todo defaults
    private var firstSampleEyeHeightL: CGFloat = CGFloat(0.25)
    private var firstSampleEyeMinYL: CGFloat = CGFloat(0.25)
    private var firstSampleEyeMaxYL: CGFloat = CGFloat(0.25)
    private var firstSampleEyeWidthR: CGFloat = CGFloat(0.35) // todo defaults
    private var firstSampleEyeHeightR: CGFloat = CGFloat(0.25)
    private var firstSampleEyeMinYR: CGFloat = CGFloat(0.25)
    private var firstSampleEyeMaxYR: CGFloat = CGFloat(0.25)
    private var firstSampleEyeGazeYL: CGFloat = 0.0 // neutral vertical-gaze ratio (pupil vs eye centroid)
    private var firstSampleEyeGazeYR: CGFloat = 0.0
    // Baselines for the "easy tier" blendshapes added below (mouth/jaw lateral, lip raise/depress, lid raise).
    // Captured during the initial sampling window; non-zero defaults avoid spikes on the first frames.
    private var firstSampleJawOffsetX: CGFloat = 0.0       // chin x relative to nose midline, faceW-normalized
    private var firstSampleUpperLipGapL: CGFloat = 0.12    // nose-base -> upper-lip-top gap, faceH-normalized
    private var firstSampleUpperLipGapR: CGFloat = 0.12
    private var firstSampleLowerLipDropL: CGFloat = 0.06   // lower-lip-bottom drop below mouth center, faceH-normalized
    private var firstSampleLowerLipDropR: CGFloat = 0.06
    // Raw eye-openness references (computeEyeOpenness units) — the offset model for eyesClosed/widen.
    private var firstSampleEyeOpenRawNeutralL: Float = 0.25  // raw openness at neutral (captured)
    private var firstSampleEyeOpenRawNeutralR: Float = 0.25
    private var firstSampleEyeClosedRawL: Float = 0.06       // raw openness with eyes closed (captured)
    private var firstSampleEyeClosedRawR: Float = 0.06
    private var firstSampleCheekWidthL: CGFloat = 0.45     // neutral cheek extent from nose midline, faceW-normalized
    private var firstSampleCheekWidthR: CGFloat = 0.45
    private var sampledInitialFace = false   // has at least one neutral calibration completed
    // Automatic neutral calibration (no UI/button): when the face holds still (~neutral) the baselines are
    // averaged over a few frames, then we wait a cooldown before allowing the next recalibration.
    private var calibSampleCount = 0              // frames folded into the current neutral average
    private var lastCalibrationTime: Double = 0   // systemUptime when the last calibration completed
    private var prevStabilityFeat: [CGFloat] = [] // previous frame's stability feature vector
    private let calibStableFrames = 15            // still frames to average per calibration (user-error margin)
    private let calibCooldownSeconds: Double = 120 // calm time since last significant movement before re-calibrating
    private var lastSignificantMovementTime: Double = 0
    private var armedForRecalib = false               // a significant movement must occur before re-calibrating
    private let calibSignificantMotion: CGFloat = 0.15 // frame-to-frame delta that counts as real movement

    // One Euro filter state (per expression channel) — visionOS face landmarks are inherently jittery,
    // so we low-pass each blendshape. The filter smooths hard when values are stable and eases off during
    // fast motion, so it kills rest jitter without lagging real expressions.
    private var oeValue = [Float](repeating: 0, count: 70)   // filtered value
    private var oeDeriv = [Float](repeating: 0, count: 70)   // filtered derivative
    private var oePrev  = [Float](repeating: 0, count: 70)   // previous raw target
    private var oeInitialized = false
    private var oeLastTime: Double = 0
    // Light defaults: the jitter is subtle, so filter just enough to take the edge off without lag.
    private let oeMinCutoff: Float = 4.0  // Hz; lower = smoother at rest (more lag). Tune.
    private let oeBeta: Float = 0.05      // speed coefficient; higher = less lag on fast motion. Tune.
    private let oeDCutoff: Float = 1.0

    override init() {
        super.init()
        // Load a saved calibration if present -> skip straight to tracking. Otherwise prompt to calibrate.
        if let c = ALVRClientApp.gStore.settings.faceCalibration {
            importCalibration(c)
            calibPhase = .done
            hasCalibratedOnce = true
        } else {
            // No saved calibration: seed the baselines from FaceCalibration's defaults (single source of
            // truth) and prompt the user to calibrate.
            importCalibration(FaceCalibration())
            needsCalibrationButton = true
        }
    }

    /// Begin the first-time calibration sequence (user pressed the Calibrate button).
    func beginCalibration() {
        calibrationRequested = true
        calibrationRequestedTime = ProcessInfo.processInfo.systemUptime
        needsCalibrationButton = false
        isCalibrating = true
        calibPhase = .neutral
        hasCalibratedOnce = false
        calibSampleCount = 0
    }

    func exportCalibration() -> FaceCalibration {
        FaceCalibration(
            mouthWidth: firstSampleMouthWidth, mouthWidthL: firstSampleMouthWidthL, mouthWidthR: firstSampleMouthWidthR,
            mouthCenterX: firstSampleMouthCenterX, mouthCenterY: firstSampleMouthCenterY,
            mouthMinX: firstSampleMouthMinX, mouthMaxX: firstSampleMouthMaxX,
            eyeWidthL: Double(firstSampleEyeWidthL), eyeWidthR: Double(firstSampleEyeWidthR),
            eyeHeightL: Double(firstSampleEyeHeightL), eyeHeightR: Double(firstSampleEyeHeightR),
            eyeMinYL: Double(firstSampleEyeMinYL), eyeMinYR: Double(firstSampleEyeMinYR),
            eyeMaxYL: Double(firstSampleEyeMaxYL), eyeMaxYR: Double(firstSampleEyeMaxYR),
            eyeGazeYL: Double(firstSampleEyeGazeYL), eyeGazeYR: Double(firstSampleEyeGazeYR),
            jawOffsetX: Double(firstSampleJawOffsetX),
            upperLipGapL: Double(firstSampleUpperLipGapL), upperLipGapR: Double(firstSampleUpperLipGapR),
            lowerLipDropL: Double(firstSampleLowerLipDropL), lowerLipDropR: Double(firstSampleLowerLipDropR),
            cheekWidthL: Double(firstSampleCheekWidthL), cheekWidthR: Double(firstSampleCheekWidthR),
            eyeOpenRawNeutralL: Double(firstSampleEyeOpenRawNeutralL), eyeOpenRawNeutralR: Double(firstSampleEyeOpenRawNeutralR),
            eyeClosedRawL: Double(firstSampleEyeClosedRawL), eyeClosedRawR: Double(firstSampleEyeClosedRawR)
        )
    }

    func importCalibration(_ c: FaceCalibration) {
        firstSampleMouthWidth = c.mouthWidth; firstSampleMouthWidthL = c.mouthWidthL; firstSampleMouthWidthR = c.mouthWidthR
        firstSampleMouthCenterX = c.mouthCenterX; firstSampleMouthCenterY = c.mouthCenterY
        firstSampleMouthMinX = c.mouthMinX; firstSampleMouthMaxX = c.mouthMaxX
        firstSampleEyeWidthL = CGFloat(c.eyeWidthL); firstSampleEyeWidthR = CGFloat(c.eyeWidthR)
        firstSampleEyeHeightL = CGFloat(c.eyeHeightL); firstSampleEyeHeightR = CGFloat(c.eyeHeightR)
        firstSampleEyeMinYL = CGFloat(c.eyeMinYL); firstSampleEyeMinYR = CGFloat(c.eyeMinYR)
        firstSampleEyeMaxYL = CGFloat(c.eyeMaxYL); firstSampleEyeMaxYR = CGFloat(c.eyeMaxYR)
        firstSampleEyeGazeYL = CGFloat(c.eyeGazeYL); firstSampleEyeGazeYR = CGFloat(c.eyeGazeYR)
        firstSampleJawOffsetX = CGFloat(c.jawOffsetX)
        firstSampleUpperLipGapL = CGFloat(c.upperLipGapL); firstSampleUpperLipGapR = CGFloat(c.upperLipGapR)
        firstSampleLowerLipDropL = CGFloat(c.lowerLipDropL); firstSampleLowerLipDropR = CGFloat(c.lowerLipDropR)
        firstSampleCheekWidthL = CGFloat(c.cheekWidthL); firstSampleCheekWidthR = CGFloat(c.cheekWidthR)
        firstSampleEyeOpenRawNeutralL = Float(c.eyeOpenRawNeutralL); firstSampleEyeOpenRawNeutralR = Float(c.eyeOpenRawNeutralR)
        firstSampleEyeClosedRawL = Float(c.eyeClosedRawL); firstSampleEyeClosedRawR = Float(c.eyeClosedRawR)
    }

    /// One Euro smoothing factor for a given cutoff (Hz) and timestep (s).
    private func oneEuroAlpha(_ cutoff: Float, _ dt: Float) -> Float {
        let tau = 1.0 / (2.0 * Float.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
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
        //let width = (self.firstSampleEyeWidthL+self.firstSampleEyeWidthR)*0.5
        let width = pts.map(\.x).max()! - pts.map(\.x).min()!
        let normArea = area / (width * width)

        return clamp01(normArea)
    }
    
    func computeRoll(
        leftEye: VNFaceLandmarkRegion2D?,
        rightEye: VNFaceLandmarkRegion2D?
    ) -> Float? {
        guard let left = leftEye, let right = rightEye else { return nil }

        // Average eye landmark points to get eye centers
        let lc = left.normalizedPoints.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let rc = right.normalizedPoints.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }

        let lf = CGPoint(x: lc.x / CGFloat(left.pointCount),
                         y: lc.y / CGFloat(left.pointCount))

        let rf = CGPoint(x: rc.x / CGFloat(right.pointCount),
                         y: rc.y / CGFloat(right.pointCount))

        // Vector from left eye to right eye (in face-box space)
        let dx = Float(rf.x - lf.x)
        let dy = Float(rf.y - lf.y)

        // Roll angle: when dy = 0 → perfectly horizontal
        return atan2(dy, dx)
    }

    private func handleFaceLandmarks(request: VNRequest, error: Error?) {
        guard error == nil else { return }
        guard let results = request.results as? [VNFaceObservation] else {
            Task { @MainActor in self.detectedFaces = [] }
            return
        }
        
        func avg(_ pts: [CGPoint]) -> CGPoint {
            guard !pts.isEmpty else { return .zero }
            let s = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: s.x / CGFloat(pts.count), y: s.y / CGFloat(pts.count))
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
                    // Test rotation transforms
                    /*let faceRoll = computeRoll(leftEye: all.leftEye, rightEye: all.rightEye) ?? 0.0
                    
                    let eyeCenterL = avg(all.leftEye?.normalizedPoints ?? [])
                    let eyeCenterR = avg(all.rightEye?.normalizedPoints ?? [])
                    var eyeCenter = avg([eyeCenterL, eyeCenterR])
                    let noseCenter = eyeCenter
                    eyeCenter.x *= -1.0
                    eyeCenter.y *= -1.0*/
                    let noseCenter = CGPoint()
                    let eyeCenter = CGPoint()
                    let faceRoll: Float = 0.0
                    
                    let ipdScale = 1.0
                    //let faceRoll = Float(sin(CACurrentMediaTime()))
                
                    let collect: [[CGPoint]?] = [
                        all.faceContour?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.leftEye?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.rightEye?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.nose?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.noseCrest?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.outerLips?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.innerLips?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.leftPupil?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.rightPupil?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.leftEyebrow?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter),
                        all.rightEyebrow?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter)
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
                func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }
                func norm(_ v: CGFloat) -> Float { return Float(clamp01(v)) }
                func norm(_ v: Float) -> Float { return Float(clamp01(v)) }
                // Helper to convert a landmark point from face-local to image space
                func faceToImage(_ p: CGPoint, bb: CGRect, scale: CGFloat = 1.0) -> CGPoint {
                    let x = (p.x * bb.width) * scale
                    let y = (1 - (p.y * bb.height)) * scale
                    return CGPoint(x: x, y: y)
                    //return p
                }
                func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
                let bb = first.boundingBox
                
                //let faceW = imgW
                //let faceH = imgH

                //let noseCenter = avg(lm.noseCrest?.normalizedPoints ?? [])
                let faceRoll = computeRoll(leftEye: lm.leftEye, rightEye: lm.rightEye) ?? 0.0
                let preLEyePts = lm.leftEye?.normalizedPoints ?? []
                let preREyePts = lm.rightEye?.normalizedPoints ?? []
                let preEyeCenterL = avg(preLEyePts)
                let preEyeCenterR = avg(preREyePts)
                
                let pre_eyeLEdgeYLeft = preLEyePts.min(by: { $0.x < $1.x })!.y
                let pre_eyeLEdgeYRight = preLEyePts.max(by: { $0.x < $1.x })!.y
                let pre_eyeREdgeYLeft = preREyePts.min(by: { $0.x < $1.x })!.y
                let pre_eyeREdgeYRight = preREyePts.max(by: { $0.x < $1.x })!.y
                
                //eyeCenterL.y = lm.leftEye?.normalizedPoints.max(by: { $0.y < $1.y })?.y ?? 0.0 // the bottom eyelid is more stable
                //eyeCenterR.y = lm.rightEye?.normalizedPoints.max(by: { $0.y < $1.y })?.y ?? 0.0
                
                // Replace with requested snippet:
                // Use the median line from landmarks as eyeCenter if available
                var eyeCenter: CGPoint
                if let median = lm.medianLine {
                    let medianAvg = avg(median.normalizedPoints)
                    eyeCenter = medianAvg
                } else {
                    eyeCenter = avg([preEyeCenterL, preEyeCenterR])
                    eyeCenter.y = max(pre_eyeLEdgeYLeft, pre_eyeLEdgeYRight, pre_eyeREdgeYLeft, pre_eyeREdgeYRight)
                }
                let noseCenter: CGPoint = {
                    if let crest = lm.noseCrest {
                        return avg(crest.normalizedPoints)
                    } else {
                        return eyeCenter
                    }
                }()
//                eyeCenter.x *= -1.0
//                eyeCenter.y *= -1.0
                
                

                // Collect key groups in image space
                let inner = lm.innerLips?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let outer = lm.outerLips?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let leftEye = lm.leftEye?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let rightEye = lm.rightEye?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let leftPupil = lm.leftPupil?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let rightPupil = lm.rightPupil?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let leftBrow = lm.leftEyebrow?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let rightBrow = lm.rightEyebrow?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let nose = lm.nose?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let noseCrest = lm.noseCrest?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                let faceContour = lm.faceContour?.rotatedTranslated(by: faceRoll, center: noseCenter, translate: eyeCenter) ?? []
                
                // TODO maybe a better splitting heuristic, though it seems like VN's APIs allow index counting
                // by design
                let outerLipsL = lm.outerLips?.normalizedPoints.dropFirst(3).dropLast(3) ?? []
                let outerLipsR = (lm.outerLips?.normalizedPoints[0..<4] ?? []) + (lm.outerLips?.normalizedPoints.suffix(4) ?? [])
                
                let leftEyeIntermediate = leftEye.map { faceToImage($0, bb: bb, scale: 1.0) }
                let rightEyeIntermediate = rightEye.map { faceToImage($0, bb: bb, scale: 1.0) }
                
                // lastIpd is only set once streaming is active; during the pre-stream calibration it's still
                // -1, which would make ipdScale negative and collapse faceW/faceH (breaking calibration).
                // Fall back to a typical IPD — it mostly cancels out of the normalized features anyway.
                let ipdMeters = EventHandler.shared.lastIpd > 0 ? EventHandler.shared.lastIpd : 0.063
                let ipdScale = CGFloat(ipdMeters) / dist(avg(leftEyeIntermediate), avg(rightEyeIntermediate))
                let faceW = max(0.00001, bb.width * ipdScale)
                let faceH = max(0.00001, bb.height * ipdScale)

                let innerImg = inner.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let outerImg = outer.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let lEyeImg = leftEye.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let rEyeImg = rightEye.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let lPupilImg = leftPupil.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let rPupilImg = rightPupil.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let lBrowImg = leftBrow.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let rBrowImg = rightBrow.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let noseImg = nose.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let noseCrestImg = noseCrest.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let contourImg = faceContour.map { faceToImage($0, bb: bb, scale: ipdScale) }
                
                let outerImgL = outerLipsL.map { faceToImage($0, bb: bb, scale: ipdScale) }
                let outerImgR = outerLipsR.map { faceToImage($0, bb: bb, scale: ipdScale) }

                // Reference distances
                let eyeCenterDist = dist(avg(lEyeImg), avg(rEyeImg))
                let eyeEdgeLx = (lEyeImg.isEmpty ? 0 : (lEyeImg.min(by: { $0.x < $1.x })!.x))
                let eyeEdgeRx = (lEyeImg.isEmpty ? 0 : (lEyeImg.max(by: { $0.x < $1.x })!.x))
                let eyeEdgeDist = eyeEdgeRx - eyeEdgeLx
                
                let eyeMinYL = lEyeImg.min(by: { $0.y < $1.y })!.y
                let eyeMaxYL = lEyeImg.max(by: { $0.y < $1.y })!.y
                let eyeWidthL = lEyeImg.max(by: { $0.x < $1.x })!.x - lEyeImg.min(by: { $0.x < $1.x })!.x
                let eyeHeightL = eyeMaxYL - eyeMinYL
                
                let eyeMinYR = rEyeImg.min(by: { $0.y < $1.y })!.y
                let eyeMaxYR = rEyeImg.max(by: { $0.y < $1.y })!.y
                let eyeWidthR = rEyeImg.max(by: { $0.x < $1.x })!.x - rEyeImg.min(by: { $0.x < $1.x })!.x
                let eyeHeightR = eyeMaxYR - eyeMinYR
                
                let mouthMinX = (outerImg.isEmpty ? 0 : outerImg.min(by: { $0.x < $1.x })!.x)
                let mouthMaxX = (outerImg.isEmpty ? 0 : outerImg.max(by: { $0.x < $1.x })!.x)
                let mouthWidth = (outerImg.isEmpty ? 0 : (outerImg.max(by: { $0.x < $1.x })!.x - outerImg.min(by: { $0.x < $1.x })!.x))
                let mouthHeight = (innerImg.isEmpty ? 0 : (innerImg.max(by: { $0.y < $1.y })!.y - innerImg.min(by: { $0.y < $1.y })!.y))
                let mouthCenter = avg(outerImg)
                let mouthWidthL = (outerImgL.isEmpty ? 0 : (outerImgL.max(by: { $0.x < $1.x })!.x - outerImgL.min(by: { $0.x < $1.x })!.x))
                let mouthWidthR = (outerImgR.isEmpty ? 0 : (outerImgR.max(by: { $0.x < $1.x })!.x - outerImgR.min(by: { $0.x < $1.x })!.x))
                
                let faceCenterX = avg(outerImg).x
                let noseHeight = (noseCrestImg.isEmpty ? 0 : (noseCrestImg.max(by: { $0.y < $1.y })!.y - noseCrestImg.min(by: { $0.y < $1.y })!.y))
                
                //print(eyeWidthL, eyeCenterDist, eyeWidthL/faceW)

                // jawOpen
                var jawDropCurrent: Float = 0.0
                if !innerImg.isEmpty {
                    let v = clamp01((mouthHeight / faceH) * 4.0)
                    jawDropCurrent = norm(v)
                    newBlendShapes["jawDrop"] = jawDropCurrent
                }

                // jawLeft / jawRight (horizontal offset of mouth center vs face center)
//                if !outerImg.isEmpty {
//                    let dx = (mouthCenter.x - faceCenterX) / faceW
//                    newBlendShapes["jawSidewaysRight"] = 0.0//norm(max(0, dx * 3.0))
//                    newBlendShapes["jawSidewaysLeft"] = 0.0//norm(max(0, -dx * 3.0))
//                }
                
                // TODO: This needs ML probably
                // jawForward (mouth protrusion approximated by increased inner lip height vs width)
//                if mouthWidth > 0 {
//                    let ratio = (mouthHeight / mouthWidth)
//                    newBlendShapes["jawThrust"] = 0.0//norm((ratio - 0.25) * 3.0)
//                }
                
                let baseMouthWidth = self.firstSampleMouthWidth
                let baseMouthWidthL = self.firstSampleMouthWidthL
                let baseMouthWidthR = self.firstSampleMouthWidthR
                let baseMouthWidthLR = min(baseMouthWidthL, baseMouthWidthR)
                let cornerPullThreshold = 0.01
                var depressorL: Float = 0.0
                var depressorR: Float = 0.0
                
                // TODO: Maybe another min/max autonormalizer here
                // mouthFrown (corners lower than center)
                if !outerImg.isEmpty {
                    let leftCorner = outerImg.min(by: { $0.x < $1.x })!
                    let rightCorner = outerImg.max(by: { $0.x < $1.x })!
                    let centerY = avg(outerImg).y //self.firstSampleMouthCenterY * faceH
                    let down = max(0, (leftCorner.y - centerY) / faceH) + max(0, (rightCorner.y - centerY) / faceH)
                    let downL = max(0, (leftCorner.y - centerY) / faceH) * 2.0
                    let downR = max(0, (rightCorner.y - centerY) / faceH) * 2.0
                    var valL = norm((downL * 24.0) - 0.7)
                    var valR = norm((downR * 24.0) - 0.7)
                    
                    if jawDropCurrent > 0.5 {
                        valL = 0.0
                        valR = 0.0
                    }
                    depressorL = valL
                    depressorR = valR
                    newBlendShapes["lipCornerDepressorL"] = valL
                    newBlendShapes["lipCornerDepressorR"] = valR
                }
                
                // TODO: Maybe another min/max autonormalizer here
                // mouthSmile (width increase)
                if mouthWidth > 0 {
                    let base = mouthWidth / faceW
                    let smile: Float = Float(max(0, base - baseMouthWidth) / max(0.00001, baseMouthWidth * 0.125))
                    
                    //let smileL = (((mouthCenter.x - mouthMinX) / faceW) / (baseMouthWidth * 0.5)) - 1.0
                    //let smileR = (((mouthMaxX - mouthCenter.x) / faceW) / (baseMouthWidth * 0.5)) - 1.0
                    //let smileL = (self.firstSampleMouthMinX - (mouthMinX / faceW)) * -4.0
                    //let smileR = ((mouthMaxX / faceW) - self.firstSampleMouthMaxX) * 4.0
                    
                    // TODO: a low-pass filter might help filter out the other side's false positives
                    let baseL = mouthWidthL / faceW
                    let baseR = mouthWidthR / faceW
                    let smileL = norm(max(0, baseL - baseMouthWidthL - cornerPullThreshold) * 70.0)
                    let smileR = norm(max(0, baseR - baseMouthWidthR - cornerPullThreshold) * 70.0)
                    
                    //print(baseL, baseR, baseMouthWidthL, baseMouthWidthR, smileL, smileR)
                    
                    //let lrBias = ((mouthCenter.x / faceW) - self.firstSampleMouthCenterX) * 8.0
                    //print(lrBias)
                    newBlendShapes["lipCornerPullerL"] = norm((smileL * smile) - depressorL)
                    newBlendShapes["lipCornerPullerR"] = norm((smileR * smile) - depressorR)
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
                
                // mouthPucker: lips narrow horizontally vs. the neutral mouth width (jawDrop subtracted so
                // an open mouth doesn't read as pucker). puckerGain tunable.
                if mouthWidth > 0 {
                    let puckerGain: Float = 8.0
                    let w = mouthWidth / faceW
                    let narrowing = max(0, Float(baseMouthWidth) - Float(w)) // 0 at rest, grows as lips purse
                    let val = norm(narrowing * puckerGain - jawDropCurrent)
                    newBlendShapes["lipPuckerL"] = val
                    newBlendShapes["lipPuckerR"] = val
                }
                
                // mouthDimpleL/R (corners pull inward horizontally)
                if !outerImg.isEmpty {
                    let leftCorner = outerImg.min(by: { $0.x < $1.x })!
                    let rightCorner = outerImg.max(by: { $0.x < $1.x })!
                    let leftIn = max(0, (faceCenterX - leftCorner.x) / faceW)
                    let rightIn = max(0, (rightCorner.x - faceCenterX) / faceW)
                    newBlendShapes["dimplerL"] = 0.0//norm(leftIn * 6.0)
                    newBlendShapes["dimplerR"] = 0.0//norm(rightIn * 6.0)
                }
                
                // mouthStretch L/R (corners move outward)
                if !outerImg.isEmpty {
                    let leftCorner = outerImg.min(by: { $0.x < $1.x })!
                    let rightCorner = outerImg.max(by: { $0.x < $1.x })!
                    let leftOut = max(0, (leftCorner.x - faceCenterX) / faceW)
                    let rightOut = max(0, (faceCenterX - rightCorner.x) / faceW)
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
                
                // cheekPuff: each cheek's silhouette bulges outward from the facial midline vs. its neutral
                // baseline. A 2D-only approximation (no depth), autocalibrated per side and tunable.
                var curCheekWidthL: CGFloat = self.firstSampleCheekWidthL
                var curCheekWidthR: CGFloat = self.firstSampleCheekWidthR
                if !contourImg.isEmpty && !noseCrestImg.isEmpty {
                    let cheekPuffGain: Float = 12.0
                    let midX = avg(noseCrestImg).x            // stable facial midline
                    let cheekY = mouthCenter.y                // cheek band sits around mouth/nose level
                    let bandHalf = faceH * 0.2
                    // Max outward distance from the midline among contour points near cheek level, per side.
                    func cheekExtent(_ pts: [CGPoint], _ sign: CGFloat) -> CGFloat {
                        let near = pts.filter { abs($0.y - cheekY) < bandHalf }
                        let outward = near.map { ($0.x - midX) * sign }.max() ?? 0
                        return max(0, outward) / faceW
                    }
                    curCheekWidthL = cheekExtent(contourImg.filter { $0.x <= midX }, -1) // L = min-x side
                    curCheekWidthR = cheekExtent(contourImg.filter { $0.x >= midX },  1)
                    newBlendShapes["cheekPuffL"] = norm((Float(curCheekWidthL) - Float(self.firstSampleCheekWidthL)) * cheekPuffGain)
                    newBlendShapes["cheekPuffR"] = norm((Float(curCheekWidthR) - Float(self.firstSampleCheekWidthR)) * cheekPuffGain)
                }
                
                // Derived this from my eye look bc it actually seemed accidentally good at eyelids
                func eyeLidClosed(_ eye: [CGPoint], _ pupil: [CGPoint]) -> Float {
                    guard !eye.isEmpty else { return 0.0 }
                    
                    var c = avg(pupil)
                    c.x /= faceW
                    c.y /= faceH
                    
                    var eyeCent = avg(eye)
                    eyeCent.x /= faceW
                    eyeCent.y /= faceH

                    let eyeEdgeYLeft = eye.min(by: { $0.x < $1.x })!.y / faceH
                    let eyeEdgeYRight = eye.max(by: { $0.x < $1.x })!.y / faceH
                    let eyeEdgeY = (eyeEdgeYLeft + eyeEdgeYRight) * 0.5

                    let minX = eye.min(by: { $0.x < $1.x })!.x / faceW
                    let maxX = eye.max(by: { $0.x < $1.x })!.x / faceW
                    let eyeWidth = (maxX - minX)
                    
                    let relY = (c.y - eyeEdgeY) // tbe bottom of the eye is more stable
                    let dy = ((relY / max(0.001, eyeWidth * 0.5)) + 0.125 + 0.06) * 4.0 // tbh idk why this works, something something approximating the radius with the eye width
                    let centeredDy = (dy)
                    
                    return norm((centeredDy) * 2.0)
                }

                // eyeBlink L/R
                let lEyeOpenedRaw: Float = Float(computeEyeOpenness(landmark: lm.leftEye))
                let rEyeOpenedRaw: Float = Float(computeEyeOpenness(landmark: lm.rightEye))
                // Offset model: 0 at the calibrated closed reference, 1 at the calibrated neutral-open reference.
                let lEyeOpened = norm((lEyeOpenedRaw - self.firstSampleEyeClosedRawL) / max(0.0001, self.firstSampleEyeOpenRawNeutralL - self.firstSampleEyeClosedRawL))
                let rEyeOpened = norm((rEyeOpenedRaw - self.firstSampleEyeClosedRawR) / max(0.0001, self.firstSampleEyeOpenRawNeutralR - self.firstSampleEyeClosedRawR))
                let lEyeClosedOrLookingDown = CGFloat(eyeLidClosed(lEyeImg, lPupilImg))
                let rEyeClosedOrLookingDown = CGFloat(eyeLidClosed(rEyeImg, rPupilImg))
                
                let lEyeUnopened: Float = 1.0 - lEyeOpened
                let rEyeUnopened: Float = 1.0 - rEyeOpened
                
                // The Vision/Persona models co-activate both eyes, so closure is computed in two parts.
                // 1) A saturating curve per eye: anything past `closeKnee` ramps to a full 1.0, while the
                //    knee rejects the low-level co-activation the other eye picks up. (Tune on device.)
                // 2) A *thresholded* wink separation: only a clear wink suppresses the more-open eye, so a
                //    normal (slightly asymmetric) blink still drives BOTH eyes to 1.0.
                // Linear position between neutral-open and the closed reference (lEyeUnopened == 1 - openness),
                // then an S-curve: the flat low end rejects the other eye's co-activation bleed, and it
                // saturates a full close to 1.0. lo/hi tunable. Each eye uses its own references.
                let closeCurveLo: Float = 0.15  // co-activation is removed below, so the knee can stay low
                let closeCurveHi: Float = 0.8   // lower if full closes don't reach 1.0
                func closeCurve(_ x: Float) -> Float {
                    let t = clamp01((x - closeCurveLo) / max(0.0001, closeCurveHi - closeCurveLo))
                    return t * t * (3 - 2 * t)
                }
                // Common-mode rejection: Vision drops BOTH eyes' openness when one closes. Invert the
                // symmetric mixing so a real both-blink survives (both high -> both stay ~1) but a wink's
                // bleed into the open eye is subtracted out. coact = co-activation strength (0..1).
                let coact: Float = 0.6
                let dL = norm((lEyeUnopened - coact * rEyeUnopened) / (1 - coact))
                let dR = norm((rEyeUnopened - coact * lEyeUnopened) / (1 - coact))
                let lEyeClosed = CGFloat(closeCurve(dL))
                let rEyeClosed = CGFloat(closeCurve(dR))
                newBlendShapes["eyesClosedL"] = Float(lEyeClosed)
                newBlendShapes["eyesClosedR"] = Float(rEyeClosed)

                // eyeSquint L/R (milder than blink)
                let lidTightenerL = (lEyeClosedOrLookingDown * 0.2) + (lEyeClosed * 0.2)
                let lidTightenerR = (rEyeClosedOrLookingDown * 0.2) + (rEyeClosed * 0.2)
                
                newBlendShapes["lidTightenerL"] = Float(norm(lidTightenerL))
                newBlendShapes["lidTightenerR"] = Float(norm(lidTightenerR))
                
                newBlendShapes["cheekRaiserL"] = norm(lidTightenerL * 0.7)
                newBlendShapes["cheekRaiserR"] = norm(lidTightenerR * 0.7)
                
                // eyeLook Up/Down/Left/Right (pupil/eye centroid relative to socket)
                // Vertical gaze ratio: pupil offset from eye centroid, normalized by eye half-width.
                // Shared by eyeLook and the neutral-baseline capture so the two can't drift apart.
                func eyeVerticalRatio(_ eye: [CGPoint], _ pupil: [CGPoint], _ widthEstimate: CGFloat) -> CGFloat {
                    // No pupil => avg([]) is (0,0), which would peg the ratio. Bail to neutral instead.
                    guard !eye.isEmpty, !pupil.isEmpty else { return 0 }
                    let c = avg(pupil)
                    var eyeCent = avg(eye)
                    eyeCent.y += 0.0005
                    return (c.y - eyeCent.y) / max(0.001, widthEstimate * 0.5)
                }
                let eyeLookVerticalGain: CGFloat = 6.0 // up/down sensitivity; tune on device
                func eyeLook(_ which: Int, _ eyes: [[CGPoint]], _ pupil: [CGPoint], _ eyesWideOpenEstimateX: CGFloat, _ eyesWideOpenEstimateY: CGFloat, _ verticalNeutral: CGFloat) -> (up: Float, down: Float, left: Float, right: Float) {
                    let eye = eyes[which]
                    // When the pupil isn't detected (common when looking up — the lid occludes it),
                    // avg([]) returns (0,0) and the gaze would stick at max. Treat as centered instead.
                    guard !eye.isEmpty, !pupil.isEmpty else { return (0,0,0,0) }

                    var c = avg(pupil)
                    //c.x /= faceW
                    //c.y /= faceH

                    let eyeLEdgeYLeft = eyes[0].min(by: { $0.x < $1.x })!.y
                    let eyeLEdgeYRight = eyes[0].max(by: { $0.x < $1.x })!.y
                    let eyeREdgeYLeft = eyes[1].min(by: { $0.x < $1.x })!.y
                    let eyeREdgeYRight = eyes[1].max(by: { $0.x < $1.x })!.y
                    //let eyeEdgeY = which == 0 ? eyeLEdgeYRight : eyeREdgeYLeft // Use the tear ducts as a grounding point
                    let eyeEdgeY = max(eyeLEdgeYLeft, eyeLEdgeYRight, eyeREdgeYLeft, eyeREdgeYRight) // This seems more stable when closing eyes slightly
                    
                    
                    let minX = eye.min(by: { $0.x < $1.x })!.x
                    let maxX = eye.max(by: { $0.x < $1.x })!.x
                    let minY = eye.min(by: { $0.y < $1.y })!.y
                    let maxY = eye.max(by: { $0.y < $1.y })!.y
                    let eyeWidth = (maxX - minX)
                    
                    let relX = (c.x - (minX))
                    let dx = (relX / max(0.001, eyeWidth)) // 0.0 to 1.0
                    let centeredDx = (dx - 0.5) * 2.0 // change to -0.5 to 0.5 and scale up
                    
                    // TODO, eyelids don't really close evenly
                    //let eyesWideOpenEstimateYCurrent = (maxY - minY)
                    //let estimatedEyeCenterY = (maxY) - (eyesWideOpenEstimateY * 0.5)
                    
                    // Subtract the captured neutral so a resting gaze reads ~0.
                    let vertRatio = eyeVerticalRatio(eye, pupil, eyesWideOpenEstimateX)
                    let centeredDy = (vertRatio - verticalNeutral) * eyeLookVerticalGain

                    let up: Float = norm(-(centeredDy))
                    let down: Float = norm((centeredDy))
                    let left: Float = norm(-(centeredDx))
                    let right: Float = norm((centeredDx))
                    return (up, down, left, right)
                }
                let lLook = eyeLook(0, [lEyeImg, rEyeImg], lPupilImg, self.firstSampleEyeWidthL, self.firstSampleEyeHeightL, self.firstSampleEyeGazeYL)
                let rLook = eyeLook(1, [lEyeImg, rEyeImg], rPupilImg, self.firstSampleEyeWidthR, self.firstSampleEyeHeightR, self.firstSampleEyeGazeYR)

                // Adaptive neutral: slowly recenter the gaze baseline toward the resting gaze, but ONLY while
                // the eye is already near neutral. This corrects baseline drift (the cause of look-up/down
                // latching at the rail) without fading a deliberately-held gaze, which sits outside the band.
                let gazeAdaptBand: CGFloat = 0.04 // ratio units around neutral where we recalibrate
                let gazeAdaptRate: CGFloat = 0.02 // how fast the neutral follows (per frame)
                if self.sampledInitialFace {
                    if !lPupilImg.isEmpty {
                        let r = eyeVerticalRatio(lEyeImg, lPupilImg, self.firstSampleEyeWidthL)
                        if abs(r - self.firstSampleEyeGazeYL) < gazeAdaptBand {
                            self.firstSampleEyeGazeYL += (r - self.firstSampleEyeGazeYL) * gazeAdaptRate
                        }
                    }
                    if !rPupilImg.isEmpty {
                        let r = eyeVerticalRatio(rEyeImg, rPupilImg, self.firstSampleEyeWidthR)
                        if abs(r - self.firstSampleEyeGazeYR) < gazeAdaptBand {
                            self.firstSampleEyeGazeYR += (r - self.firstSampleEyeGazeYR) * gazeAdaptRate
                        }
                    }
                }

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
                    newBlendShapes["browLowererL"] = norm(CGFloat((1.0 - norm((0.08 - leftLift) * 8.0)) * 5.0)  + CGFloat(0.6*lEyeClosedOrLookingDown))
                    newBlendShapes["browLowererR"] = norm(CGFloat((1.0 - norm((0.08 - rightLift) * 8.0)) * 5.0) + CGFloat(0.6*rEyeClosedOrLookingDown))
                    
                    // Outer up: compare outer-most brow points vs inner-most
                    let lOuter = lBrowImg.max(by: { $0.x < $1.x })!
                    let lInner = lBrowImg.min(by: { $0.x < $1.x })!
                    let rOuter = rBrowImg.min(by: { $0.x < $1.x })!
                    let rInner = rBrowImg.max(by: { $0.x < $1.x })!
                    let lOuterUp = (lOuter.y - lInner.y) / faceH
                    let rOuterUp = (rOuter.y - rInner.y) / faceH
                    newBlendShapes["outerBrowRaiserL"] = norm((lOuterUp * 4.0) - CGFloat(0.5*lEyeClosed))
                    newBlendShapes["outerBrowRaiserR"] = norm((rOuterUp * 4.0) - CGFloat(0.5*rEyeClosed))
                }

                // MARK: - Easy-tier blendshapes (heuristic, NEEDS ON-DEVICE TUNING)
                // All gains/signs below are first guesses. Watch BlendShapesDebugView and tune:
                // verify directions FIRST (these can be mirrored), then scale the gains.
                let mouthLateralGain: Float = 8.0       // mouthLeft/Right sensitivity
                let jawLateralGain: Float = 6.0         // jawSideways sensitivity
                let lowerLipDropGain: Float = 12.0      // lowerLipDepressor sensitivity
                let lowerLipJawCompensation: Float = 1.0 // how much jawDrop is subtracted from lowerLipDepressor
                let upperLipRaiseGain: Float = 12.0     // upperLipRaiser sensitivity

                // Per-frame baseline samples (read by the initial-sampling block further below).
                var curJawOffsetX: CGFloat = self.firstSampleJawOffsetX
                var curUpperLipGapL: CGFloat = self.firstSampleUpperLipGapL
                var curUpperLipGapR: CGFloat = self.firstSampleUpperLipGapR
                var curLowerLipDropL: CGFloat = self.firstSampleLowerLipDropL
                var curLowerLipDropR: CGFloat = self.firstSampleLowerLipDropR

                // mouthLeft / mouthRight: lateral shift of the mouth center vs. the neutral baseline.
                // SIGN: +x == Right (min-x == L), matching the existing lip L/R convention. Flip if mirrored.
                if !outerImg.isEmpty {
                    let dx = Float(mouthCenter.x / faceW) - Float(firstSampleMouthCenterX)
                    newBlendShapes["mouthRight"] = norm(dx * mouthLateralGain)
                    newBlendShapes["mouthLeft"]  = norm(-dx * mouthLateralGain)
                }

                // jawSidewaysLeft / jawSidewaysRight: chin x vs. nose midline, baselined to cancel head yaw.
                // SIGN: +x == Right, same convention as above. Flip if mirrored.
                let noseMid: CGPoint?
                if !noseCrestImg.isEmpty { noseMid = avg(noseCrestImg) }
                else if !noseImg.isEmpty { noseMid = avg(noseImg) }
                else { noseMid = nil }
                if !contourImg.isEmpty, let mid = noseMid {
                    let chinX = contourImg.max(by: { $0.y < $1.y })!.x // lowest contour point ≈ chin
                    curJawOffsetX = (chinX - mid.x) / faceW
                    let dxJaw = Float(curJawOffsetX) - Float(self.firstSampleJawOffsetX)
                    newBlendShapes["jawSidewaysRight"] = norm(dxJaw * jawLateralGain)
                    newBlendShapes["jawSidewaysLeft"]  = norm(-dxJaw * jawLateralGain)
                }

                // Per-side lip vertical motion: split the roll-corrected outer lip by mouth-center x.
                if !outerImg.isEmpty {
                    let mcx = mouthCenter.x
                    let outerLeft  = outerImg.filter { $0.x <= mcx } // min-x side == L
                    let outerRight = outerImg.filter { $0.x >= mcx }
                    let centerY = mouthCenter.y / faceH

                    if !outerLeft.isEmpty && !outerRight.isEmpty {
                        // lowerLipDepressor: lower-lip bottom drops below mouth center, beyond jaw-driven opening.
                        curLowerLipDropL = (outerLeft.max(by: { $0.y < $1.y })!.y  / faceH) - centerY
                        curLowerLipDropR = (outerRight.max(by: { $0.y < $1.y })!.y / faceH) - centerY
                        let depL = (Float(curLowerLipDropL) - Float(self.firstSampleLowerLipDropL)) * lowerLipDropGain
                        let depR = (Float(curLowerLipDropR) - Float(self.firstSampleLowerLipDropR)) * lowerLipDropGain
                        newBlendShapes["lowerLipDepressorL"] = norm(depL - jawDropCurrent * lowerLipJawCompensation)
                        newBlendShapes["lowerLipDepressorR"] = norm(depR - jawDropCurrent * lowerLipJawCompensation)

                        // upperLipRaiser: upper-lip top rises toward the nose base (gap shrinks).
                        if !noseImg.isEmpty {
                            let noseBottomY = noseImg.max(by: { $0.y < $1.y })!.y / faceH // lowest nose point ≈ nostril base
                            curUpperLipGapL = (outerLeft.min(by: { $0.y < $1.y })!.y  / faceH) - noseBottomY
                            curUpperLipGapR = (outerRight.min(by: { $0.y < $1.y })!.y / faceH) - noseBottomY
                            newBlendShapes["upperLipRaiserL"] = norm((Float(self.firstSampleUpperLipGapL) - Float(curUpperLipGapL)) * upperLipRaiseGain)
                            newBlendShapes["upperLipRaiserR"] = norm((Float(self.firstSampleUpperLipGapR) - Float(curUpperLipGapR)) * upperLipRaiseGain)
                        }
                    }
                }

                // upperLidRaiser = eye WIDEN: raw openness beyond the calibrated neutral, per eye.
                let widenFrac: Float = 0.25  // ~25% wider than neutral reads as full widen; tune
                newBlendShapes["upperLidRaiserL"] = norm((lEyeOpenedRaw - self.firstSampleEyeOpenRawNeutralL) / max(0.0001, self.firstSampleEyeOpenRawNeutralL * widenFrac))
                newBlendShapes["upperLidRaiserR"] = norm((rEyeOpenedRaw - self.firstSampleEyeOpenRawNeutralR) / max(0.0001, self.firstSampleEyeOpenRawNeutralR * widenFrac))

                // Not possible with Persona avatars?
//                newBlendShapes["noseWrinklerL"] = 0.0
//                newBlendShapes["noseWrinklerR"] = 0.0

                // tongueOut (use inner mouth height beyond jawOpen as proxy)
//                if mouthHeight > 0 {
//                    let t = max(0, (mouthHeight / faceH) - 0.12) * 4.0
//                    newBlendShapes["tongueOut"] = 0.0//norm(t)
//                }
                
                // Automatic calibration. .neutral/.done: detect a held-still (≈neutral) pose and average the
                // baselines, then cooldown. .closing: capture the eyes-closed reference. No button.
                let calibNow = ProcessInfo.processInfo.systemUptime
#if ENABLE_FACE_RECALIBRATION
                self.secondsUntilRecalib = (self.calibPhase == .done && self.armedForRecalib)
                    ? max(0, self.calibCooldownSeconds - (calibNow - self.lastSignificantMovementTime)) : 0
#else
                self.secondsUntilRecalib = 0
#endif

                if self.calibPhase == .closing {
                    // "Close your eyes" window: track the most-closed openness per eye.
                    self.isCalibrating = true
                    self.closingMinRawL = min(self.closingMinRawL, lEyeOpenedRaw)
                    self.closingMinRawR = min(self.closingMinRawR, rEyeOpenedRaw)
                    if calibNow - self.closingStart >= self.calibClosingSeconds {
                        // Fall back to a fraction of neutral if the user didn't actually close.
                        // Deepest close seen, nudged 25% back toward neutral so a *normal* close (not a hard
                        // clench) reads as fully closed. Fallback to neutral*0.4 if the user didn't close.
                        let closedBlendL = self.closingMinRawL + (self.firstSampleEyeOpenRawNeutralL - self.closingMinRawL) * 0.25
                        let closedBlendR = self.closingMinRawR + (self.firstSampleEyeOpenRawNeutralR - self.closingMinRawR) * 0.25
                        self.firstSampleEyeClosedRawL = (self.firstSampleEyeOpenRawNeutralL - self.closingMinRawL > 0.02) ? closedBlendL : self.firstSampleEyeOpenRawNeutralL * 0.4
                        self.firstSampleEyeClosedRawR = (self.firstSampleEyeOpenRawNeutralR - self.closingMinRawR > 0.02) ? closedBlendR : self.firstSampleEyeOpenRawNeutralR * 0.4
                        self.calibPhase = .done
                        self.hasCalibratedOnce = true
                        self.isCalibrating = false
                        self.lastCalibrationTime = calibNow
                        self.calibrationRequested = false
                        // Persist the calibration so future sessions skip straight to tracking.
                        ALVRClientApp.gStore.settings.faceCalibration = self.exportCalibration()
                        try? ALVRClientApp.gStore.save(settings: ALVRClientApp.gStore.settings)
                        // Calibration done -> release the stream.
                        EventHandler.shared.faceCalibrationPending = false
                        AudioServicesPlaySystemSound(1114)
                    }
                } else {
                // Head/mouth position only — excludes eye openness so natural blinks don't register as
                // movement and reset the neutral capture.
                let stabilityFeat: [CGFloat] = [mouthCenter.x / faceW, mouthCenter.y / faceH, mouthWidth / faceW]
                var faceMotion: CGFloat = .greatestFiniteMagnitude
                if self.prevStabilityFeat.count == stabilityFeat.count {
                    faceMotion = zip(stabilityFeat, self.prevStabilityFeat).reduce(CGFloat(0)) { $0 + abs($1.0 - $1.1) }
                }
                self.prevStabilityFeat = stabilityFeat
                // "Still enough" tolerates minor landmark jitter; only a real movement (calibSignificantMotion)
                // resets the count, so the capture can actually reach calibStableFrames.
                let faceStill = faceMotion < self.calibSignificantMotion
                if faceMotion > self.calibSignificantMotion {
                    self.lastSignificantMovementTime = calibNow
                    if self.calibPhase == .done { self.armedForRecalib = true }
                }
                // Re-calibrate only after a real movement followed by calibCooldownSeconds of calm (settled).
                // Define ENABLE_FACE_RECALIBRATION in the build's Swift compilation conditions to enable it;
                // otherwise only the one-time initial calibration runs.
                // The first-time neutral capture only runs once the user has pressed Calibrate.
                let initialCalib = self.calibPhase == .neutral && self.calibrationRequested
                    && (calibNow - self.calibrationRequestedTime >= self.calibStartDelaySeconds)
#if ENABLE_FACE_RECALIBRATION
                let calibEligible = initialCalib ||
                    (self.armedForRecalib && (calibNow - self.lastSignificantMovementTime) >= self.calibCooldownSeconds)
#else
                let calibEligible = initialCalib
#endif

                if calibEligible && faceStill {
                    self.isCalibrating = true
                    // Average the neutral across the still window (incremental running mean) so per-frame
                    // landmark noise doesn't bake into the baseline.
                    self.calibSampleCount += 1
                    let nD = Double(self.calibSampleCount)
                    let nC = CGFloat(self.calibSampleCount)
                    let nF = Float(self.calibSampleCount)
                    accMean(&self.firstSampleMouthWidth, Double(mouthWidth / faceW), nD)
                    accMean(&self.firstSampleMouthWidthL, Double(mouthWidthL / faceW), nD)
                    accMean(&self.firstSampleMouthWidthR, Double(mouthWidthR / faceW), nD)
                    accMean(&self.firstSampleMouthCenterY, Double(mouthCenter.y / faceH), nD)
                    accMean(&self.firstSampleMouthCenterX, Double(mouthCenter.x / faceW), nD)
                    accMean(&self.firstSampleMouthMinX, Double(mouthMinX / faceW), nD)
                    accMean(&self.firstSampleMouthMaxX, Double(mouthMaxX / faceW), nD)
                    accMean(&self.firstSampleEyeWidthL, eyeWidthL, nC)
                    accMean(&self.firstSampleEyeHeightL, eyeHeightL, nC)
                    accMean(&self.firstSampleEyeMinYL, eyeMinYL / faceH, nC)
                    accMean(&self.firstSampleEyeMaxYL, eyeMaxYL / faceH, nC)
                    accMean(&self.firstSampleEyeWidthR, eyeWidthR, nC)
                    accMean(&self.firstSampleEyeHeightR, eyeHeightR, nC)
                    accMean(&self.firstSampleEyeMinYR, eyeMinYR / faceH, nC)
                    accMean(&self.firstSampleEyeMaxYR, eyeMaxYR / faceH, nC)

                    // Neutral vertical gaze (so eyesLookDown/Up read ~0 at rest)
                    if !lPupilImg.isEmpty { accMean(&self.firstSampleEyeGazeYL, eyeVerticalRatio(lEyeImg, lPupilImg, eyeWidthL), nC) }
                    if !rPupilImg.isEmpty { accMean(&self.firstSampleEyeGazeYR, eyeVerticalRatio(rEyeImg, rPupilImg, eyeWidthR), nC) }

                    // Easy-tier baselines
                    accMean(&self.firstSampleJawOffsetX, curJawOffsetX, nC)
                    accMean(&self.firstSampleUpperLipGapL, curUpperLipGapL, nC)
                    accMean(&self.firstSampleUpperLipGapR, curUpperLipGapR, nC)
                    accMean(&self.firstSampleLowerLipDropL, curLowerLipDropL, nC)
                    accMean(&self.firstSampleLowerLipDropR, curLowerLipDropR, nC)
                    accMean(&self.firstSampleCheekWidthL, curCheekWidthL, nC)
                    accMean(&self.firstSampleCheekWidthR, curCheekWidthR, nC)
                    accMean(&self.firstSampleEyeOpenRawNeutralL, lEyeOpenedRaw, nF)
                    accMean(&self.firstSampleEyeOpenRawNeutralR, rEyeOpenedRaw, nF)

                    if self.calibSampleCount >= self.calibStableFrames {
                        self.sampledInitialFace = true
                        self.lastCalibrationTime = calibNow
                        self.calibSampleCount = 0
                        if self.calibPhase == .neutral {
                            // Neutral captured -> chime and ask the user to close their eyes.
                            self.calibPhase = .closing
                            self.closingStart = calibNow
                            self.closingMinRawL = lEyeOpenedRaw
                            self.closingMinRawR = rEyeOpenedRaw
                            self.isCalibrating = true
                            AudioServicesPlaySystemSound(1113)
                        } else {
                            self.isCalibrating = false
                            self.armedForRecalib = false
                        }
                    }
                } else {
                    // Not capturing this frame (settle delay, waiting to hold still, or cooldown): drop any
                    // partial average but keep the prompt up while a calibration is requested.
                    self.calibSampleCount = 0
                    self.isCalibrating = self.calibPhase == .neutral && self.calibrationRequested
                }
                }
                WorldTracker.shared.fbFaceTrackingValid = true
            }
            else {
                WorldTracker.shared.fbFaceTrackingValid = false
            }

            self.blendShapes = newBlendShapes

            // Build this frame's target. Every per-shape computation is guarded on a landmark region
            // (lips/brows/contour/pupil); a shape absent from newBlendShapes (region dropped this frame)
            // targets 0, so the filter eases it back to neutral instead of letting it stick.
            let slotCount = XrFaceExpression2FB.count.rawValue
            var target = [Float](repeating: 0.0, count: slotCount)
            for shape in self.blendShapes {
                let idx = XrFaceExpression2FB.fromString[shape.key, default: XrFaceExpression2FB.count].rawValue
                if idx < slotCount { target[idx] = shape.value }
                else { print("Failed to map:", shape.key) }
            }

            // One Euro low-pass per channel to take the edge off visionOS's inherent landmark jitter.
            let now = ProcessInfo.processInfo.systemUptime
            let dt = self.oeInitialized ? Float(max(0.001, now - self.oeLastTime)) : Float(1.0 / 30.0)
            self.oeLastTime = now
            for i in 0..<slotCount {
                let x = target[i]
                if self.oeInitialized {
                    let dx = (x - self.oePrev[i]) / dt
                    self.oeDeriv[i] += self.oneEuroAlpha(self.oeDCutoff, dt) * (dx - self.oeDeriv[i])
                    let cutoff = self.oeMinCutoff + self.oeBeta * abs(self.oeDeriv[i])
                    self.oeValue[i] += self.oneEuroAlpha(cutoff, dt) * (x - self.oeValue[i])
                } else {
                    self.oeValue[i] = x
                    self.oeDeriv[i] = 0
                }
                self.oePrev[i] = x
                WorldTracker.shared.fbFaceTracking[i] = max(0.0, min(1.0, self.oeValue[i]))
            }
            self.oeInitialized = true
        }
    }
    
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

