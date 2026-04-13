import UIKit
import SwiftUI
import AVFoundation
import Vision
import ImageIO
import simd
import Foundation
import CoreBluetooth

final class ViewController: UIViewController,
                            AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureDataOutputSynchronizerDelegate {
    
    // MARK: - Capture
    
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let overlayLayer = CAShapeLayer()
    
    private let cameraQueue = DispatchQueue(label: "camera.session.queue")
    private let visionQueue = DispatchQueue(label: "vision.pose.queue")
    
    private var currentCameraPosition: AVCaptureDevice.Position = .front
    private var videoInput: AVCaptureDeviceInput?
    
    private var videoOutput: AVCaptureVideoDataOutput?
    private var depthOutput: AVCaptureDepthDataOutput?
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    
    private var isDepthModeEnabled = false
    
    // MARK: - UI
    
    private let toggleButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    
    // MARK: - Smoothing
    
    private var smoothedPoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
    private let smoothingFactor: CGFloat = 0.18
    
    // MARK: - Pose validation / tracking
    
    private var validPoseStreak = 0
    private var invalidPoseStreak = 0
    
    private let framesRequiredForLock = 5
    private let framesRequiredToLoseLock = 12
    
    private var hasLockedPose = false
    private let jointDebugMode = false
    
    // MARK: - Lifecycle
    
    private var socket: URLSessionWebSocketTask?
    
    // MARK: - Haptic Feedback
    private let bleManager = BLEManager()
    private var lastSentBadState: Bool?
    private var lastSentMotorLevel: UInt8?
    
    // MARK: - Face Posture Tracking

    private var baselineFaceCenter: CGPoint?
    private var baselineFaceSize: CGSize?
    private var baselineSamples: [(center: CGPoint, size: CGSize)] = []
    private let baselineSampleTarget = 20
    
    private var calibrationStartTime: Date?
    private let calibrationCountdownDuration: TimeInterval = 5.0

    private var badPostureFrameCount = 0
    private var goodPostureFrameCount = 0

    private let verticalDropThreshold: CGFloat = 0.03
    private let faceScaleIncreaseThreshold: CGFloat = 1.10

    private let framesForBadPosture = 12
    private let framesForGoodPosture = 8

    private var lastSentBadFaceState: Bool?

    private let useFacePostureMode = true
    
    private func resetFaceCalibration() {
        baselineFaceCenter = nil
        baselineFaceSize = nil
        baselineSamples.removeAll()
        calibrationStartTime = nil
        badPostureFrameCount = 0
        goodPostureFrameCount = 0
        lastSentBadFaceState = nil
        lastSentMotorLevel = nil
    }
    
    
    func connectSocket() {
#if targetEnvironment(simulator)
        let url = URL(string: "ws://localhost:3000")!
#else
        let url = URL(string: "ws://192.168.1.12:3000")!
#endif
        socket = URLSession.shared.webSocketTask(with: url)
        socket?.resume()
    }
    
    func sendPostureUpdate(score: Int, bad: Bool) {
        
        let payload: [String: Any] = [
            "score": score,
            "bad_posture": bad,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        
        socket?.send(.data(data)) { error in
            if let error = error {
                print("WebSocket error:", error)
            }
        }
    }
    
    private func motorLevel(for score: Int) -> UInt8 {
        switch score {
        case 85...100:
            return 0   // no vibration / weakest
        case 70...84:
            return 1   // mild
        case 50...69:
            return 2   // medium
        default:
            return 3   // strongest
        }
    }

    private func sendMotorLevelIfNeeded(score: Int) {
        let level = motorLevel(for: score)

        guard lastSentMotorLevel != level else {
            return
        }

        lastSentMotorLevel = level
        bleManager.sendMotorLevel(level)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        resetFaceCalibration()
        setupPreviewLayer()
        setupOverlay()
        setupStatusLabel()
        setupToggleButton()
        setupCamera()
        connectSocket()
    }
    
    private struct PoseValidationResult {
        let isValid: Bool
        let message: String
    }
    
    private struct FacePostureResult {
        let isBadPosture: Bool
        let message: String
        let score: Int
        let center: CGPoint
        let size: CGSize
        let verticalDrop: CGFloat
        let scaleRatio: CGFloat
    }
    
    private func detectFace(in pixelBuffer: CVPixelBuffer) -> VNFaceObservation? {
        
        let request = VNDetectFaceRectanglesRequest()
        
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: exifOrientationForCurrentCamera(),
            options: [:]
        )
        
        do {
            try handler.perform([request])
            
            return request.results?.max(by: {
                ($0.boundingBox.width * $0.boundingBox.height) <
                    ($1.boundingBox.width * $1.boundingBox.height)
            })
            
        } catch {
            return nil
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        overlayLayer.frame = view.bounds
        
        statusLabel.frame = CGRect(x: 20, y: 60, width: view.bounds.width - 40, height: 130)
        toggleButton.frame = CGRect(x: 20, y: view.bounds.height - 80, width: 210, height: 50)
    }
    
    // MARK: - Setup UI
    
    private func setupPreviewLayer() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
    }
    
    private func setupOverlay() {
        overlayLayer.frame = view.bounds
        overlayLayer.strokeColor = UIColor.systemGreen.cgColor
        overlayLayer.lineWidth = 4
        overlayLayer.fillColor = UIColor.clear.cgColor
        overlayLayer.lineJoin = .round
        overlayLayer.lineCap = .round
        view.layer.addSublayer(overlayLayer)
    }
    
    private func setupStatusLabel() {
        statusLabel.text = "Sit in your baseline posture"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textColor = .white
        statusLabel.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 12
        statusLabel.clipsToBounds = true
        view.addSubview(statusLabel)
    }
    
    private func setupToggleButton() {
        toggleButton.setTitle("Flip Camera", for: .normal)
        toggleButton.tintColor = .white
        toggleButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toggleButton.layer.cornerRadius = 10
        toggleButton.addTarget(self, action: #selector(toggleCamera), for: .touchUpInside)
        view.addSubview(toggleButton)
    }
    
    // MARK: - Camera configuration
    
    private func setupCamera() {
        cameraQueue.async {
            self.configureSession()
        }
    }
    
    @objc private func toggleCamera() {
        currentCameraPosition = (currentCameraPosition == .back) ? .front : .back
        smoothedPoints.removeAll()
        
        DispatchQueue.main.async {
            self.statusLabel.text = "Switching camera..."
        }
        
        setupCamera()
    }
    
    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high
        
        // Remove old inputs
        for input in session.inputs {
            session.removeInput(input)
        }
        
        // Remove old outputs
        for output in session.outputs {
            session.removeOutput(output)
        }
        
        videoOutput = nil
        depthOutput = nil
        outputSynchronizer = nil
        isDepthModeEnabled = false
        
        guard let device = preferredDevice(for: currentCameraPosition) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.statusLabel.text = "No compatible camera found"
            }
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusLabel.text = "Unable to add camera input"
                }
                return
            }
            session.addInput(input)
            videoInput = input
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.statusLabel.text = "Failed to create camera input"
            }
            return
        }
        
        let newVideoOutput = AVCaptureVideoDataOutput()
        newVideoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        newVideoOutput.alwaysDiscardsLateVideoFrames = true
        
        guard session.canAddOutput(newVideoOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.statusLabel.text = "Unable to add video output"
            }
            return
        }
        
        session.addOutput(newVideoOutput)
        videoOutput = newVideoOutput
        
        if let connection = newVideoOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = (currentCameraPosition == .front)
            }
        }
        
        // Try to enable depth on LiDAR / TrueDepth devices
        let newDepthOutput = AVCaptureDepthDataOutput()
        newDepthOutput.isFilteringEnabled = true

        let depthWasConfigured = false
        if depthWasConfigured {
            guard session.canAddOutput(newDepthOutput) else {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusLabel.text = "Depth camera exists but depth output failed"
                }
                return
            }
            
            session.addOutput(newDepthOutput)
            depthOutput = newDepthOutput
            
            if let depthConnection = newDepthOutput.connection(with: .depthData) {
                if depthConnection.isVideoOrientationSupported {
                    depthConnection.videoOrientation = .portrait
                }
                if depthConnection.isVideoMirroringSupported {
                    depthConnection.isVideoMirrored = (currentCameraPosition == .front)
                }
            }
            
            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [newVideoOutput, newDepthOutput])
            synchronizer.setDelegate(self, queue: visionQueue)
            outputSynchronizer = synchronizer
            isDepthModeEnabled = true
        } else {
            newVideoOutput.setSampleBufferDelegate(self, queue: visionQueue)
            isDepthModeEnabled = false
        }
        
        session.commitConfiguration()
        
        if !session.isRunning {
            session.startRunning()
        }
        
        DispatchQueue.main.async {
            if self.isDepthModeEnabled {
                let mode = self.currentCameraPosition == .back ? "LiDAR / depth 3D mode" : "TrueDepth 3D mode"
                self.statusLabel.text = "Starting posture tracking...\n\(mode)"
            } else {
                self.statusLabel.text = "Starting posture tracking...\n2D fallback mode"
            }
        }
    }
    
    private func preferredDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            // Prefer LiDAR on supported Pro devices / iPad Pro
            if let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
                return lidar
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        } else {
            // Prefer TrueDepth on front if available
            if let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                return trueDepth
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }
    
    private func configureDepthIfAvailable(on device: AVCaptureDevice,
                                           depthOutput: AVCaptureDepthDataOutput) -> Bool {
        let supportedFormats = device.activeFormat.supportedDepthDataFormats
        guard !supportedFormats.isEmpty else { return false }
        
        let preferredFormats = supportedFormats.filter {
            let description = $0.formatDescription
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            return subtype == kCVPixelFormatType_DepthFloat16 ||
            subtype == kCVPixelFormatType_DepthFloat32
        }
        
        guard let selectedFormat = preferredFormats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else {
            return false
        }
        
        do {
            try device.lockForConfiguration()
            device.activeDepthDataFormat = selectedFormat
            device.unlockForConfiguration()
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Frame processing (2D fallback)
    
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !isDepthModeEnabled else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrame(pixelBuffer: pixelBuffer, depthData: nil)
    }
    
    private func visionPointToMetadataPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x,
            y: 1.0 - point.y
        )
    }

    private func visionRectToMetadataRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: 1.0 - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }

    private func displayNormalizedPoint(fromVisionPoint point: CGPoint) -> CGPoint {
        let displayPoint = previewLayer.layerPointConverted(
            fromCaptureDevicePoint: visionPointToMetadataPoint(point)
        )

        return CGPoint(
            x: displayPoint.x / max(view.bounds.width, 1),
            y: displayPoint.y / max(view.bounds.height, 1)
        )
    }

    private func displayNormalizedRect(fromVisionRect rect: CGRect) -> CGRect {
        let metadataRect = visionRectToMetadataRect(rect)
        let displayRect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)

        return CGRect(
            x: displayRect.origin.x / max(view.bounds.width, 1),
            y: displayRect.origin.y / max(view.bounds.height, 1),
            width: displayRect.width / max(view.bounds.width, 1),
            height: displayRect.height / max(view.bounds.height, 1)
        )
    }
    
    private func analyzeFacePosture(face: VNFaceObservation) -> FacePostureResult {
        let visionCenter = CGPoint(
            x: face.boundingBox.midX,
            y: face.boundingBox.midY
        )

        let displayCenter = displayNormalizedPoint(fromVisionPoint: visionCenter)
        let displayRect = displayNormalizedRect(fromVisionRect: face.boundingBox)

        let center = displayCenter
        let size = CGSize(
            width: face.boundingBox.width,
            height: face.boundingBox.height
        )

        if baselineFaceCenter == nil || baselineFaceSize == nil {
            if calibrationStartTime == nil {
                calibrationStartTime = Date()
                baselineSamples.removeAll()
            }

            let elapsed = Date().timeIntervalSince(calibrationStartTime ?? Date())
            let remaining = calibrationCountdownDuration - elapsed

            if remaining > 0 {
                let secondsLeft = Int(ceil(remaining))
                return FacePostureResult(
                    isBadPosture: false,
                    message: "Sit in your baseline posture\nStarting in \(secondsLeft)...",
                    score: 100,
                    center: center,
                    size: size,
                    verticalDrop: 0,
                    scaleRatio: 1.0
                )
            }

            baselineSamples.append((center: center, size: size))

            if baselineSamples.count >= baselineSampleTarget {
                let avgCenterX = baselineSamples.map { $0.center.x }.reduce(0, +) / CGFloat(baselineSamples.count)
                let avgCenterY = baselineSamples.map { $0.center.y }.reduce(0, +) / CGFloat(baselineSamples.count)
                let avgWidth = baselineSamples.map { $0.size.width }.reduce(0, +) / CGFloat(baselineSamples.count)
                let avgHeight = baselineSamples.map { $0.size.height }.reduce(0, +) / CGFloat(baselineSamples.count)

                baselineFaceCenter = CGPoint(x: avgCenterX, y: avgCenterY)
                baselineFaceSize = CGSize(width: avgWidth, height: avgHeight)
            }

            let progress = min(baselineSamples.count, baselineSampleTarget)

            return FacePostureResult(
                isBadPosture: false,
                message: "Hold still...\nCalibrating baseline (\(progress)/\(baselineSampleTarget))",
                score: 100,
                center: center,
                size: size,
                verticalDrop: 0,
                scaleRatio: 1.0
            )
        }

        guard let baselineCenter = baselineFaceCenter,
              let baselineSize = baselineFaceSize else {
            return FacePostureResult(
                isBadPosture: false,
                message: "Calibration error",
                score: 0,
                center: center,
                size: size,
                verticalDrop: 0,
                scaleRatio: 1.0
            )
        }

        let verticalDrop = center.y - baselineCenter.y
        let scaleRatio = size.height / max(baselineSize.height, 0.0001)

        let dropBad = verticalDrop > verticalDropThreshold
        let scaleBad = scaleRatio > faceScaleIncreaseThreshold
        let currentlyBad = dropBad || scaleBad

        /*
        print(String(format:
            "FACE   cx: %.3f  cy: %.3f  minY: %.3f  maxY: %.3f  h: %.3f | baseCx: %.3f  baseCy: %.3f  baseH: %.3f | drop: %.3f  scale: %.3f",
            center.x, center.y, minY, maxY, size.height,
            baselineCenter.x, baselineCenter.y, baselineSize.height,
            verticalDrop, scaleRatio
        ))
         */

        if currentlyBad {
            badPostureFrameCount += 1
            goodPostureFrameCount = 0
        } else {
            goodPostureFrameCount += 1
            badPostureFrameCount = 0
        }

        let latchedBadState: Bool
        if badPostureFrameCount >= framesForBadPosture {
            latchedBadState = true
        } else if goodPostureFrameCount >= framesForGoodPosture {
            latchedBadState = false
        } else {
            latchedBadState = lastSentBadFaceState ?? false
        }

        var details: [String] = []
        if dropBad { details.append("slouching / looking down") }
        if scaleBad { details.append("leaning forward") }

        let scorePenalty = (dropBad ? 25 : 0) + (scaleBad ? 25 : 0)
        let score = max(0, 100 - scorePenalty)

        if lastSentBadFaceState != latchedBadState {
            lastSentBadFaceState = latchedBadState
            sendPostureUpdate(score: score, bad: latchedBadState)
        }

        sendMotorLevelIfNeeded(score: score)

        let message: String
        if latchedBadState {
            message = "Adjust posture: \(details.joined(separator: ", "))"
        } else {
            message = "Posture looks perfect"
        }

        return FacePostureResult(
            isBadPosture: latchedBadState,
            message: message,
            score: score,
            center: center,
            size: size,
            verticalDrop: verticalDrop,
            scaleRatio: scaleRatio
        )
    }
    
    private func drawFaceDebug(face: VNFaceObservation, result: FacePostureResult) {
        DispatchQueue.main.async {
            let path = UIBezierPath()

            self.clearJointLabels()

            // Vision boundingBox uses normalized coordinates with origin at bottom-left.
            // AVCapture metadata coordinates expect normalized coordinates with origin at top-left.
            func visionRectToMetadataRect(_ rect: CGRect) -> CGRect {
                return CGRect(
                    x: rect.origin.x,
                    y: 1.0 - rect.origin.y - rect.size.height,
                    width: rect.size.width,
                    height: rect.size.height
                )
            }

            func visionPointToMetadataPoint(_ point: CGPoint) -> CGPoint {
                return CGPoint(
                    x: point.x,
                    y: 1.0 - point.y
                )
            }

            let metadataRect = visionRectToMetadataRect(face.boundingBox)
            let displayRect = self.previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)

            path.append(UIBezierPath(rect: displayRect))

            let faceCenterDisplay = CGPoint(
                x: result.center.x * self.view.bounds.width,
                y: result.center.y * self.view.bounds.height
            )

            path.move(to: faceCenterDisplay)
            path.addArc(
                withCenter: faceCenterDisplay,
                radius: 8,
                startAngle: 0,
                endAngle: CGFloat.pi * 2,
                clockwise: true
            )

            if let baselineCenter = self.baselineFaceCenter {
                let baselineDisplay = CGPoint(
                    x: baselineCenter.x * self.view.bounds.width,
                    y: baselineCenter.y * self.view.bounds.height
                )

                path.move(to: baselineDisplay)
                path.addArc(
                    withCenter: baselineDisplay,
                    radius: 6,
                    startAngle: 0,
                    endAngle: CGFloat.pi * 2,
                    clockwise: true
                )

                path.move(to: baselineDisplay)
                path.addLine(to: faceCenterDisplay)

                self.addJointLabel("B", at: baselineDisplay)
            }

            self.addJointLabel("F", at: faceCenterDisplay)

            self.overlayLayer.path = path.cgPath
            self.overlayLayer.strokeColor = result.isBadPosture
                ? UIColor.systemRed.cgColor
                : UIColor.systemGreen.cgColor
            self.overlayLayer.fillColor = UIColor.clear.cgColor

            self.statusLabel.text = result.message

            if self.baselineFaceCenter == nil || self.baselineFaceSize == nil {
                self.statusLabel.textColor = .white
            } else {
                self.statusLabel.textColor = result.isBadPosture ? .systemRed : .systemGreen
            }
        }
    }
    
    // MARK: - Frame processing (synchronized RGB + depth)
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        guard let videoOutput = videoOutput,
              let syncedVideo = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer)
        else {
            return
        }
        
        var depthData: AVDepthData?
        
        if let depthOutput = depthOutput,
           let syncedDepth = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepth.depthDataWasDropped {
            depthData = syncedDepth.depthData
        }
        
        processFrame(pixelBuffer: pixelBuffer, depthData: depthData)
    }
    
    private func processFrame(pixelBuffer: CVPixelBuffer, depthData: AVDepthData?) {
        if useFacePostureMode {
            let face = detectFace(in: pixelBuffer)

            guard let face else {
                DispatchQueue.main.async {
                    self.overlayLayer.path = nil
                    self.clearJointLabels()
                    self.statusLabel.text = "Move into frame"
                    self.statusLabel.textColor = .white
                }

                if self.baselineFaceCenter == nil || self.baselineFaceSize == nil {
                    self.calibrationStartTime = nil
                    self.baselineSamples.removeAll()
                }

                if self.lastSentMotorLevel != 0 {
                    self.bleManager.sendMotorLevel(0)
                    self.lastSentMotorLevel = 0
                }

                return
            }

            let result = analyzeFacePosture(face: face)
            drawFaceDebug(face: face, result: result)
            return
        }

        let bodyRequest = VNDetectHumanBodyPoseRequest()

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: exifOrientationForCurrentCamera(),
            options: [:]
        )

        do {
            try handler.perform([bodyRequest])

            let face = detectFace(in: pixelBuffer)

            guard let observation = bodyRequest.results?.first else {
                handleInvalidDetection(message: "No body detected")
                return
            }

            drawSkeleton(observation, face: face, depthData: depthData)

        } catch {
            DispatchQueue.main.async {
                self.statusLabel.text = "Pose detection failed"
            }
        }
    }
    
    private func handleInvalidDetection(message: String) {
        
        invalidPoseStreak += 1
        validPoseStreak = 0
        
        if invalidPoseStreak >= framesRequiredToLoseLock {
            
            hasLockedPose = false
            smoothedPoints.removeAll()
            
            DispatchQueue.main.async {
                self.overlayLayer.path = nil
                self.statusLabel.text = message
            }
        }
    }
    
    private func exifOrientationForCurrentCamera() -> CGImagePropertyOrientation {
        return currentCameraPosition == .front ? .leftMirrored : .right
    }
    // MARK: - Drawing + analysis
    
    private func normalizedFaceCenter(_ face: VNFaceObservation?) -> CGPoint? {
        
        guard let face else { return nil }
        
        return CGPoint(
            x: face.boundingBox.midX,
            y: face.boundingBox.midY
        )
    }
    
    private func validatePose(
        points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        face: VNFaceObservation?
    ) -> PoseValidationResult {
        
        func point(
            _ name: VNHumanBodyPoseObservation.JointName,
            minConfidence: Float = 0.30
        ) -> CGPoint? {
            
            guard let p = points[name], p.confidence >= minConfidence else {
                return nil
            }
            
            return CGPoint(x: p.location.x, y: p.location.y)
        }
        
        print("leftShoulder confidence:", points[.leftShoulder]?.confidence ?? -1)
        print("rightShoulder confidence:", points[.rightShoulder]?.confidence ?? -1)
        
        let leftShoulder = point(.leftShoulder)
        let rightShoulder = point(.rightShoulder)
        
        guard leftShoulder != nil || rightShoulder != nil else {
            return PoseValidationResult(
                isValid: false,
                message: "Need at least one shoulder visible"
            )
        }
        
        let shoulderCenter: CGPoint
        let shoulderWidth: CGFloat
        
        if let l = leftShoulder, let r = rightShoulder {
            shoulderCenter = CGPoint(
                x: (l.x + r.x) / 2,
                y: (l.y + r.y) / 2
            )
            shoulderWidth = distance(l, r)
        } else if let l = leftShoulder {
            shoulderCenter = l
            shoulderWidth = 0.08
        } else if let r = rightShoulder {
            shoulderCenter = r
            shoulderWidth = 0.08
        } else {
            return PoseValidationResult(
                isValid: false,
                message: "Need shoulder visible"
            )
        }
        
        let faceCenter = face.map {
            CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)
        }
        /*
         if let faceCenter, abs(faceCenter.x - shoulderCenter.x) > 0.35 {
         return PoseValidationResult(
         isValid: false,
         message: "Face-body alignment invalid"
         )
         }
         */
        
        let neck = point(.neck) ?? point(.nose)
        let leftHip = point(.leftHip)
        let rightHip = point(.rightHip)
        
        if shoulderWidth < 0.03 || shoulderWidth > 0.75 {
            return PoseValidationResult(
                isValid: false,
                message: "Pose scale looks invalid"
            )
        }
        
        if let l = leftShoulder, let r = rightShoulder,
           abs(l.y - r.y) > 0.35 {
            return PoseValidationResult(
                isValid: false,
                message: "Shoulder detection unstable"
            )
        }
        
        if let neck, neck.y < shoulderCenter.y - 0.12 {
            return PoseValidationResult(
                isValid: false,
                message: "Head/neck detection unstable"
            )
        }
        
        let singleHip = leftHip ?? rightHip
        
        if let l = leftHip, let r = rightHip {
            
            let hipCenter = CGPoint(
                x: (l.x + r.x) / 2,
                y: (l.y + r.y) / 2
            )
            
            let torsoLength = distance(shoulderCenter, hipCenter)
            
            if shoulderWidth > 0.01,
               (torsoLength < shoulderWidth * 0.3 || torsoLength > shoulderWidth * 4.5) {
                return PoseValidationResult(
                    isValid: false,
                    message: "Torso geometry invalid"
                )
            }
            
            if hipCenter.y >= shoulderCenter.y {
                return PoseValidationResult(
                    isValid: false,
                    message: "Hip detection unstable"
                )
            }
            
        } else if let hip = singleHip {
            
            if hip.y >= shoulderCenter.y {
                return PoseValidationResult(
                    isValid: false,
                    message: "Hip detection unstable"
                )
            }
            
        } else if face == nil {
            
            return PoseValidationResult(
                isValid: false,
                message: "Need torso or face visible"
            )
        }
        
        if abs(shoulderCenter.x - 0.5) > 0.5 ||
            abs(shoulderCenter.y - 0.55) > 0.55 {
            
            return PoseValidationResult(
                isValid: false,
                message: "Move into center of frame"
            )
        }
        /*
         if let faceCenter,
         faceCenter.y < shoulderCenter.y - 0.20 {
         
         return PoseValidationResult(
         isValid: false,
         message: "Face-body alignment invalid"
         )
         }
         */
        
        return PoseValidationResult(
            isValid: true,
            message: "Pose locked"
        )
    }
    
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        
        let dx = a.x - b.x
        let dy = a.y - b.y
        
        return sqrt(dx*dx + dy*dy)
    }
    
    private func drawSkeleton(
        _ observation: VNHumanBodyPoseObservation,
        face: VNFaceObservation?,
        depthData: AVDepthData?
    ) {
        guard let points = try? observation.recognizedPoints(.all) else { return }

        if jointDebugMode {
            DispatchQueue.main.async {
                let path = UIBezierPath()

                func recognizedPoint(_ name: VNHumanBodyPoseObservation.JointName) -> VNRecognizedPoint? {
                    return points[name]
                }

                func displayPoint(_ name: VNHumanBodyPoseObservation.JointName,
                                  minConfidence: Float = 0.25) -> CGPoint? {
                    guard let p = points[name], p.confidence >= minConfidence else { return nil }

                    let normalized = CGPoint(x: p.location.x, y: p.location.y)
                    let smoothed = self.smoothed(normalized, for: name)

                    let xValue: CGFloat
                    if self.currentCameraPosition == .front {
                        xValue = (1 - smoothed.x) * self.view.bounds.width
                    } else {
                        xValue = smoothed.x * self.view.bounds.width
                    }

                    return CGPoint(
                        x: xValue,
                        y: (1 - smoothed.y) * self.view.bounds.height
                    )
                }

                let head = displayPoint(.nose)
                let leftShoulder = displayPoint(.leftShoulder)
                let rightShoulder = displayPoint(.rightShoulder)

                print("---- Joint Debug ----")
                if let p = recognizedPoint(.nose) {
                    print("H  nose conf:", p.confidence, "loc:", p.location)
                } else {
                    print("H  nose: nil")
                }

                if let p = recognizedPoint(.leftShoulder) {
                    print("LS conf:", p.confidence, "loc:", p.location)
                } else {
                    print("LS: nil")
                }

                if let p = recognizedPoint(.rightShoulder) {
                    print("RS conf:", p.confidence, "loc:", p.location)
                } else {
                    print("RS: nil")
                }

                func connect(_ a: CGPoint?, _ b: CGPoint?) {
                    guard let a, let b else { return }
                    path.move(to: a)
                    path.addLine(to: b)
                }

                func drawJoint(_ point: CGPoint?) {
                    guard let point else { return }
                    path.move(to: point)
                    path.addArc(
                        withCenter: point,
                        radius: 8,
                        startAngle: 0,
                        endAngle: CGFloat.pi * 2,
                        clockwise: true
                    )
                }

                connect(leftShoulder, rightShoulder)

                drawJoint(head)
                drawJoint(leftShoulder)
                drawJoint(rightShoulder)

                self.overlayLayer.path = path.cgPath
                self.overlayLayer.strokeColor = UIColor.systemGreen.cgColor
                self.overlayLayer.fillColor = UIColor.clear.cgColor

                self.clearJointLabels()
                self.addJointLabel("H", at: head)
                self.addJointLabel("LS", at: leftShoulder)
                self.addJointLabel("RS", at: rightShoulder)

                self.statusLabel.text = "Debug Mode: H / LS / RS"
            }

            return
        }

        // Normal mode below
        let validation = validatePose(points: points, face: face)

        guard validation.isValid else {
            handleInvalidDetection(message: validation.message)
            return
        }

        validPoseStreak += 1
        invalidPoseStreak = 0

        if validPoseStreak >= framesRequiredForLock {
            hasLockedPose = true
        }

        guard hasLockedPose else {
            DispatchQueue.main.async {
                self.statusLabel.text = "Hold still... locking posture"
            }
            return
        }

        let postureResult: PostureResult
        if let depthData {
            let joints3D = reconstruct3DJoints(from: points, depthData: depthData)
            postureResult = analyzePosture3D(points, joints3D: joints3D)
        } else {
            postureResult = analyzePosture2D(points)
        }

        DispatchQueue.main.async {
            self.statusLabel.text = postureResult.message
        }
    }
    
    private func clearJointLabels() {
        view.subviews
            .filter { $0.tag == 999 }
            .forEach { $0.removeFromSuperview() }
    }

    private func addJointLabel(_ text: String, at point: CGPoint?) {
        guard let point else { return }

        let label = UILabel()
        label.tag = 999
        label.text = text
        label.textColor = .yellow
        label.font = UIFont.boldSystemFont(ofSize: 16)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        label.frame = CGRect(x: point.x + 10, y: point.y - 10, width: 40, height: 24)

        view.addSubview(label)
    }
    
    private func smoothed(_ point: CGPoint, for joint: VNHumanBodyPoseObservation.JointName) -> CGPoint {
        if let previous = smoothedPoints[joint] {
            let x = previous.x + (point.x - previous.x) * smoothingFactor
            let y = previous.y + (point.y - previous.y) * smoothingFactor
            let result = CGPoint(x: x, y: y)
            smoothedPoints[joint] = result
            return result
        } else {
            smoothedPoints[joint] = point
            return point
        }
    }
    
    // MARK: - Types
    
    private struct PostureResult {
        let isBadPosture: Bool
        let message: String
    }
    
    // MARK: - 3D reconstruction
    
    private func reconstruct3DJoints(
        from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        depthData: AVDepthData
    ) -> [VNHumanBodyPoseObservation.JointName: simd_float3] {
        
        var result: [VNHumanBodyPoseObservation.JointName: simd_float3] = [:]
        
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepth.depthDataMap
        
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return result
        }
        
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        let calibration = convertedDepth.cameraCalibrationData
        var fx: Float?
        var fy: Float?
        var cx: Float?
        var cy: Float?
        
        if let calibration {
            let intrinsics = calibration.intrinsicMatrix
            let refSize = calibration.intrinsicMatrixReferenceDimensions
            
            let scaleX = Float(width) / Float(refSize.width)
            let scaleY = Float(height) / Float(refSize.height)
            
            fx = intrinsics.columns.0.x * scaleX
            fy = intrinsics.columns.1.y * scaleY
            cx = intrinsics.columns.2.x * scaleX
            cy = intrinsics.columns.2.y * scaleY
        }
        
        func depthAtNormalizedPoint(_ point: CGPoint) -> Float? {
            let px = max(0, min(width - 1, Int(point.x * CGFloat(width))))
            let py = max(0, min(height - 1, Int((1 - point.y) * CGFloat(height))))
            
            let depth = depthPointer[py * width + px]
            guard depth.isFinite, depth > 0 else { return nil }
            return depth
        }
        
        for (jointName, recognizedPoint) in points {
            guard recognizedPoint.confidence >= 0.45 else { continue }
            
            let normalized = CGPoint(x: recognizedPoint.location.x, y: recognizedPoint.location.y)
            
            guard let z = depthAtNormalizedPoint(normalized) else { continue }
            
            let u = Float(normalized.x) * Float(width)
            let v = Float(1 - normalized.y) * Float(height)
            
            if let fx, let fy, let cx, let cy, fx > 0, fy > 0 {
                let x3D = (u - cx) * z / fx
                let y3D = (v - cy) * z / fy
                result[jointName] = simd_float3(x3D, y3D, z)
            } else {
                // Fallback pseudo-3D if calibration is unavailable
                result[jointName] = simd_float3(Float(normalized.x), Float(normalized.y), z)
            }
        }
        
        return result
    }
    
    // MARK: - 3D posture analysis
    
    private func analyzePosture3D(
        _ points2D: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        joints3D: [VNHumanBodyPoseObservation.JointName: simd_float3]
    ) -> PostureResult {
        
        let leftShoulder = joints3D[.leftShoulder]
        let rightShoulder = joints3D[.rightShoulder]
        
        guard leftShoulder != nil || rightShoulder != nil else {
            return PostureResult(
                isBadPosture: false,
                message: "Move upper body into frame\n3D depth mode"
            )
        }
        
        let shoulderCenter: simd_float3
        if let l = leftShoulder, let r = rightShoulder {
            shoulderCenter = (l + r) / 2
        } else {
            shoulderCenter = leftShoulder ?? rightShoulder!
        }
        
        let headPoint =
        joints3D[.nose] ??
        joints3D[.leftEar] ??
        joints3D[.rightEar]
        
        let leftHip = joints3D[.leftHip]
        let rightHip = joints3D[.rightHip]
        let hipCenter: simd_float3? = {
            guard let l = leftHip, let r = rightHip else { return nil }
            return (l + r) / 2
        }()
        
        var badFlags = 0
        var details: [String] = []
        
        // 1) Forward head using true depth
        if let headPoint {
            let forwardDistanceMeters = shoulderCenter.z - headPoint.z
            if forwardDistanceMeters > 0.07 {
                badFlags += 1
                details.append("forward head")
            }
        }
        
        // 2) Uneven shoulders in 3D vertical direction
        if let l = leftShoulder, let r = rightShoulder {
            let shoulderHeightDifference = abs(l.y - r.y)
            if shoulderHeightDifference > 0.05 {
                badFlags += 1
                details.append("uneven shoulders")
            }
        }
        
        // 3) Slouch / torso lean using 3D spine direction
        if let neck = joints3D[.neck] ?? joints3D[.nose],
           let hipCenter {
            let torsoVector = neck - hipCenter
            let torsoLength = simd_length(torsoVector)
            
            if torsoLength > 0.0001 {
                let torsoUnit = torsoVector / torsoLength
                let verticalUp = simd_float3(0, -1, 0)
                
                let dotValue = max(Float(-1.0), min(Float(1.0), simd_dot(torsoUnit, verticalUp)))
                let tiltAngleDegrees = acos(dotValue) * 180 / Float.pi
                
                if tiltAngleDegrees > 18 {
                    badFlags += 1
                    details.append("slouching")
                }
            }
        }
        
        // 4) Head lateral offset relative to shoulder center
        if let headPoint {
            let lateralOffset = abs(headPoint.x - shoulderCenter.x)
            if lateralOffset > 0.08 {
                badFlags += 1
                details.append("head misalignment")
            }
        }
        
        let score = max(0, 100 - badFlags * 20)
        let isBad = badFlags > 0
        sendPostureUpdate(score: score, bad: isBad)
        sendMotorLevelIfNeeded(score: score)
        
        if badFlags == 0 {
            return PostureResult(
                isBadPosture: false,
                message: "Posture looks okay\nScore: \(score)\n3D depth mode"
            )
        } else {
            return PostureResult(
                isBadPosture: true,
                message: "Adjust posture: \(details.joined(separator: ", "))\nScore: \(score)\n3D depth mode"
            )
        }
    }
    
    // MARK: - 2D fallback posture analysis
    
    private func analyzePosture2D(
        _ points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> PostureResult {
        
        func validPoint(_ name: VNHumanBodyPoseObservation.JointName,
                        minConfidence: Float = 0.25) -> CGPoint? {
            guard let p = points[name], p.confidence >= minConfidence else { return nil }
            return CGPoint(x: p.location.x, y: p.location.y)
        }
        
        let leftShoulder = validPoint(.leftShoulder)
        let rightShoulder = validPoint(.rightShoulder)
        
        guard leftShoulder != nil || rightShoulder != nil else {
            return PostureResult(
                isBadPosture: false,
                message: "Move upper body into frame\n2D fallback mode"
            )
        }
        
        let shoulderCenter: CGPoint
        if let l = leftShoulder, let r = rightShoulder {
            shoulderCenter = CGPoint(
                x: (l.x + r.x) / 2,
                y: (l.y + r.y) / 2
            )
        } else {
            shoulderCenter = leftShoulder ?? rightShoulder!
        }
        
        let leftHip = validPoint(.leftHip)
        let rightHip = validPoint(.rightHip)
        
        var hipCenter: CGPoint?
        if let l = leftHip, let r = rightHip {
            hipCenter = CGPoint(
                x: (l.x + r.x) / 2,
                y: (l.y + r.y) / 2
            )
        } else {
            hipCenter = leftHip ?? rightHip
        }
        
        let neck = validPoint(.neck)
        let ear = validPoint(.leftEar) ?? validPoint(.rightEar) ?? validPoint(.nose)
        
        var badFlags = 0
        var details: [String] = []
        
        if let ear {
            let headForwardThreshold: CGFloat = 0.12
            let forwardDistance = abs(ear.x - shoulderCenter.x)
            
            if forwardDistance > headForwardThreshold {
                badFlags += 1
                details.append("forward head")
            }
        }
        
        if let l = leftShoulder, let r = rightShoulder {
            let shoulderTilt = abs(l.y - r.y)
            if shoulderTilt > 0.09 {
                badFlags += 1
                details.append("uneven shoulders")
            }
        }
        
        if let neck, let hipCenter {
            let torsoAngle = angleBetween2D(a: neck, b: shoulderCenter, c: hipCenter)
            if torsoAngle < 145 {
                badFlags += 1
                details.append("slouching")
            }
        }
        
        let score = max(0, 100 - badFlags * 25)
        let isBad = badFlags > 0
        sendPostureUpdate(score: score, bad: isBad)
        sendMotorLevelIfNeeded(score: score)
        
        if badFlags == 0 {
            return PostureResult(
                isBadPosture: false,
                message: "Posture looks okay\nScore: \(score)\n2D fallback mode"
            )
        } else {
            return PostureResult(
                isBadPosture: true,
                message: "Adjust posture: \(details.joined(separator: ", "))\nScore: \(score)\n2D fallback mode"
            )
        }
    }
    
    // MARK: - Geometry

    private func angleBetween2D(a: CGPoint, b: CGPoint, c: CGPoint) -> CGFloat {
        let ba = CGVector(dx: a.x - b.x, dy: a.y - b.y)
        let bc = CGVector(dx: c.x - b.x, dy: c.y - b.y)

        let dot = ba.dx * bc.dx + ba.dy * bc.dy
        let magBA = sqrt(ba.dx * ba.dx + ba.dy * ba.dy)
        let magBC = sqrt(bc.dx * bc.dx + bc.dy * bc.dy)

        guard magBA > 0.0001, magBC > 0.0001 else { return 180 }

        let cosTheta = max(-1, min(1, dot / (magBA * magBC)))
        return acos(cosTheta) * 180 / .pi
    }
}
