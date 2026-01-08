//
//  CameraManager.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-29.
//

import AVFoundation
import SwiftUI

@Observable
final class CameraManager: NSObject {
    // MARK: - Properties
    
    private(set) var isRunning = false
    private(set) var error: CameraError?
    private(set) var isConfigured = false
    
    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    
    var frameHandler: ((CMSampleBuffer) -> Void)?
    
    // MARK: - Static Permission Check
    
    static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
    
    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }
    
    // MARK: - Configuration
    
    func configure() async {
        guard !isConfigured else {
            print("[Camera] Already configured, skipping")
            return
        }
        
        // Request permission if needed
        print("[Camera] Requesting permission...")
        let authorized = await Self.requestPermission()
        print("[Camera] Permission result: \(authorized)")
        
        guard authorized else {
            print("[Camera] Not authorized (permission denied or restricted)")
            await MainActor.run {
                error = .permissionDenied
            }
            return
        }
        
        print("[Camera] Configuring session...")
        
        // Configure on session queue (async to not block main thread)
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                
                do {
                    try self.setupSession()
                    DispatchQueue.main.async {
                        self.isConfigured = true
                        self.error = nil
                        print("[Camera] Configuration complete")
                        continuation.resume()
                    }
                } catch let err as CameraError {
                    DispatchQueue.main.async {
                        self.error = err
                        print("[Camera] Configuration failed: \(err.localizedDescription ?? "unknown")")
                        continuation.resume()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.error = .unknown(error)
                        print("[Camera] Configuration failed: \(error)")
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func setupSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Remove existing inputs/outputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        
        captureSession.sessionPreset = .high
        
        // Get front camera
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CameraError.cameraUnavailable
        }
        
        // Add input
        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        captureSession.addInput(input)
        
        // Configure output
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        
        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        captureSession.addOutput(videoOutput)
        
        // Set video orientation for portrait
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = true
        }
        
        print("[Camera] Session setup complete")
    }
    
    // MARK: - Start/Stop
    
    func start() {
        guard isConfigured else {
            print("[Camera] Cannot start - not configured")
            return
        }
        
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            if !self.captureSession.isRunning {
                print("[Camera] Starting session...")
                self.captureSession.startRunning()
                
                DispatchQueue.main.async {
                    self.isRunning = self.captureSession.isRunning
                    print("[Camera] Running: \(self.isRunning)")
                }
            }
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            if self.captureSession.isRunning {
                print("[Camera] Stopping session...")
                self.captureSession.stopRunning()
                
                DispatchQueue.main.async {
                    self.isRunning = false
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameHandler?(sampleBuffer)
    }
}

// MARK: - Camera Error

enum CameraError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case permissionDenied
    case unknown(Error)
    
    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Camera not available"
        case .cannotAddInput:
            return "Cannot add camera input"
        case .cannotAddOutput:
            return "Cannot add video output"
        case .permissionDenied:
            return "Camera permission denied"
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}
