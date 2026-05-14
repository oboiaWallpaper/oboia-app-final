// WallpaperARView.swift — FIXED: no competing ARSession during scan
// Drop-in replacement — put in ios/Runner/WallpaperARView.swift

import ARKit
import AVFoundation
import SceneKit
import Flutter
import UIKit

enum ARViewMode: String {
    case scanning = "scanning"
    case preview  = "preview"
    case legacy   = "legacy"
}

final class WallpaperARView: NSObject, FlutterPlatformView {

    private let sceneView: ARSCNView
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel

    private var currentMode: ARViewMode = .preview
    private var roomScanner: RoomScanner?
    private let textureCache = TextureCache.shared
    private let eraserTool = EraserTool()

    private var wallNodes: [String: SCNNode] = [:]
    private var currentWallIndex: Int = 0

    private var panGesture: UIPanGestureRecognizer?
    private var isEraserActive = false

    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    init(frame: CGRect,
         viewId: Int64,
         messenger: FlutterBinaryMessenger,
         args: Any?) {

        // ✅ FIX: Use screen bounds instead of zero-sized frame
        sceneView = ARSCNView(frame: UIScreen.main.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        sceneView.automaticallyUpdatesLighting = true
        sceneView.autoenablesDefaultLighting = true

        channel = FlutterMethodChannel(name: "com.oboia/ar", binaryMessenger: messenger)
        eventChannel = FlutterEventChannel(name: "com.oboia/ar_events", binaryMessenger: messenger)

        super.init()

        eventChannel.setStreamHandler(self)

        sceneView.delegate = self
        sceneView.session.delegate = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(pan)
        self.panGesture = pan

        channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result)
        }
    }

    func view() -> UIView { sceneView }

    // MARK: - Method Handler

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "initAR": initAR(result: result)
        case "disposeAR": disposeAR(result: result)
        case "setARMode":
            if let mode = call.arguments as? String { setARMode(mode, result: result) }
            else { result(FlutterError(code: "INVALID_ARG", message: "mode required", details: nil)) }
        case "startScan": startScan(result: result)
        case "stopScan": stopScan(result: result)
        case "placeWallpaper": placeWallpaper(call, result: result)
        case "switchWallpaper": switchWallpaper(call, result: result)
        case "selectWall": selectWall(call, result: result)
        case "clearWall": clearWall(call, result: result)
        case "lockWall": lockWall(call, result: result)
        case "getWallMeasurements": getWallMeasurements(call, result: result)
        case "enterCutMode": enterCutMode(call, result: result)
        case "exitCutMode": exitCutMode(result: result)
        case "setBrushSize": setBrushSize(call, result: result)
        case "setBrushColor": setBrushColor(call, result: result)
        case "undoCut": eraserTool.undoStroke(); result(nil)
        case "clearAllCuts": eraserTool.resetMask(); applyMaskToCurrentWall(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - AR Lifecycle

    private func initAR(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status != .authorized {
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.startARSession(result: result)
                        } else {
                            self?.emit("error", data: ["message": "Camera access denied by user"])
                            result(FlutterError(code: "CAMERA_DENIED", message: "Camera access denied", details: nil))
                        }
                    }
                }
                return
            } else {
                emit("error", data: ["message": "Camera access restricted or denied"])
                result(FlutterError(code: "CAMERA_DENIED", message: "Camera access denied", details: nil))
                return
            }
        }
        startARSession(result: result)
    }

    private func startARSession(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported on this device"])
            result(FlutterError(code: "ARKIT_UNSUPPORTED", message: "ARKit not supported", details: nil))
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical]
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        emit("boot", data: ["status": "AR session running"])
        result(nil)
    }

    private func disposeAR(result: @escaping FlutterResult) {
        sceneView.session.pause()
        result(nil)
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        guard let newMode = ARViewMode(rawValue: mode) else {
            result(FlutterError(code: "INVALID_MODE", message: "Unknown mode: \(mode)", details: nil))
            return
        }
        currentMode = newMode
        switch newMode {
        case .scanning:
            // ═══════════════════════════════════════════════════════════
            // NOTE: This mode is now only used if called directly.
            // startScan() no longer calls setARMode("scanning").
            // If called directly, it just sets debug options — no session run.
            // ═══════════════════════════════════════════════════════════
            sceneView.debugOptions = [.showFeaturePoints]
        case .preview:
            sceneView.debugOptions = []
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.vertical]
            sceneView.session.run(config, options: [])
        case .legacy:
            sceneView.debugOptions = [.showFeaturePoints]
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.vertical]
            sceneView.session.run(config, options: [])
        }
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    // MARK: - Scan Lifecycle (FIXED)

    private func startScan(result: @escaping FlutterResult) {
        guard #available(iOS 17.0, *) else {
            result(FlutterError(code: "UNSUPPORTED", message: "iOS 17+ required for RoomPlan", details: nil))
            return
        }

        // ═══════════════════════════════════════════════════════════
        // CRITICAL FIX: Do NOT call setARMode("scanning") here.
        // That would start a COMPETING ARSession which prevents
        // RoomPlan's internal ARSession from ever firing delegate events.
        //
        // Instead: just update the mode flag and debug options.
        // The actual AR session pause happens inside RoomScanner.start()
        // ═══════════════════════════════════════════════════════════
        currentMode = .scanning
        sceneView.debugOptions = [.showFeaturePoints]

        let scanner = RoomScanner(arView: sceneView, messenger: nil)
        scanner.setEventSink { [weak self] (event) in
            guard let dict = event as? [String: Any] else { return }
            let type = dict["type"] as? String ?? "scanUpdate"
            let data = dict["data"] as? [String: Any] ?? [:]
            self?.emit(type, data: data)
        }
        scanner.start()
        self.roomScanner = scanner
        emit("boot", data: ["status": "Room scan started"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        guard let scanner = roomScanner else { result(nil); return }
        scanner.stop { [weak self] snapshot in
            guard let self = self else { return }

            if let snapshot = snapshot,
               let jsonData = try? JSONEncoder().encode(snapshot),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self.emit("scanComplete", data: ["snapshot": jsonString])
            } else {
                self.emit("scanComplete", data: ["snapshot": ""])
            }
            self.roomScanner = nil

            // ═══════════════════════════════════════════════════════════
            // RESTORE: Create a fresh ARSession for preview mode.
            // RoomPlan's session is dead after stop(), so we need a new one.
            // ═══════════════════════════════════════════════════════════
            self.restorePreviewSession()
        }
        result(nil)
    }

    /// Restores the AR session after RoomPlan scanning ends.
    /// Creates a new ARSession so the sceneView has a working camera again.
    private func restorePreviewSession() {
        let newSession = ARSession()
        sceneView.session = newSession
        sceneView.session.delegate = self

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical]
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

        currentMode = .preview
        sceneView.debugOptions = []
        print("✅ Preview ARSession restored")
        emit("boot", data: ["status": "Preview session restored"])
    }

    // MARK: - Wallpaper Placement

    private func placeWallpaper(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let albedoUrl = args["albedoUrl"] as? String,
              let wallIndex = args["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "albedoUrl & wallIndex required", details: nil))
            return
        }
        let normalUrl = args["normalUrl"] as? String ?? ""
        let roughnessUrl = args["roughnessUrl"] as? String ?? ""
        let aoUrl = args["aoUrl"] as? String ?? ""

        let group = DispatchGroup()
        var albedoImage: UIImage?
        var normalImage: UIImage?
        var roughnessImage: UIImage?
        var aoImage: UIImage?

        group.enter()
        textureCache.loadImage(from: albedoUrl) { albedoImage = $0; group.leave() }
        group.enter()
        textureCache.loadImage(from: normalUrl) { normalImage = $0; group.leave() }
        group.enter()
        textureCache.loadImage(from: roughnessUrl) { roughnessImage = $0; group.leave() }
        group.enter()
        textureCache.loadImage(from: aoUrl) { aoImage = $0; group.leave() }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, let albedo = albedoImage else {
                self?.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": false])
                result(nil)
                return
            }
            let material = SCNMaterial()
            material.diffuse.contents = albedo
            if let n = normalImage { material.normal.contents = n; material.normal.intensity = 1.0 }
            if let r = roughnessImage { material.roughness.contents = r }
            if let a = aoImage { material.ambientOcclusion.contents = a }
            material.locksAmbientWithDiffuse = true

            if let node = self.wallNodes[String(wallIndex)] {
                node.geometry?.firstMaterial = material
                self.currentWallIndex = wallIndex
                self.eraserTool.createMask(width: Int(albedo.size.width), height: Int(albedo.size.height))
                self.applyMaskToCurrentWall()
                self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": true])
            } else {
                self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": false, "message": "Wall not found"])
            }
            result(nil)
        }
    }

    private func switchWallpaper(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        placeWallpaper(call, result: result)
    }

    private func selectWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let wallIndex = (call.arguments as? [String: Any])?["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex required", details: nil))
            return
        }
        currentWallIndex = wallIndex
        emit("wallSelected", data: ["wallIndex": wallIndex])
        result(nil)
    }

    private func clearWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let wallIndex = (call.arguments as? [String: Any])?["wallIndex"] as? Int else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex required", details: nil))
            return
        }
        if let node = wallNodes[String(wallIndex)] {
            node.geometry?.firstMaterial = nil
            emit("wallCleared", data: ["wallIndex": wallIndex])
        }
        result(nil)
    }

    private func lockWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let wallIndex = args["wallIndex"] as? Int,
              let locked = args["locked"] as? Bool else {
            result(FlutterError(code: "INVALID_ARG", message: "wallIndex & locked required", details: nil))
            return
        }
        emit("wallLockChanged", data: ["wallIndex": wallIndex, "locked": locked])
        result(nil)
    }

    private func getWallMeasurements(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(["width": 0.0, "height": 0.0, "sqm": 0.0])
    }

    // MARK: - Eraser

    private func enterCutMode(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        isEraserActive = true; result(nil)
    }

    private func exitCutMode(result: @escaping FlutterResult) {
        isEraserActive = false; result(nil)
    }

    private func setBrushSize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let size = (call.arguments as? [String: Any])?["size"] as? CGFloat {
            eraserTool.brushSize = size
        }
        result(nil)
    }

    private func setBrushColor(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let colorHex = (call.arguments as? [String: Any])?["color"] as? String {
            eraserTool.brushColor = UIColor(hex: colorHex) ?? .white
        }
        result(nil)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEraserActive else { return }
        let location = gesture.location(in: sceneView)
        switch gesture.state {
        case .began: eraserTool.startStroke(at: location)
        case .changed: eraserTool.continueStroke(at: location); applyMaskToCurrentWall()
        case .ended, .cancelled: eraserTool.endStroke(); applyMaskToCurrentWall(); emit("cutUpdate", data: ["wallIndex": currentWallIndex])
        default: break
        }
    }

    private func applyMaskToCurrentWall() {
        guard let node = wallNodes[String(currentWallIndex)],
              let material = node.geometry?.firstMaterial else { return }
        eraserTool.applyMask(to: material)
    }

    // MARK: - Event Emission with Buffering

    private func emit(_ type: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = ["type": type, "data": data]
        if let sink = eventSink {
            sink(payload)
        } else {
            pendingEvents.append(payload)
        }
    }
}

// MARK: - FlutterStreamHandler

extension WallpaperARView: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = { event in events(event) }
        for event in pendingEvents {
            events(event)
        }
        pendingEvents.removeAll()
        emit("boot", data: ["status": "Dart listener attached"])
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}

// MARK: - ARSCNViewDelegate / ARSessionDelegate

extension WallpaperARView: ARSCNViewDelegate, ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {}

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard currentMode == .legacy || currentMode == .preview,
              let planeAnchor = anchor as? ARPlaneAnchor,
              planeAnchor.alignment == .vertical else { return }
        let plane = SCNPlane(width: CGFloat(planeAnchor.extent.x), height: CGFloat(planeAnchor.extent.z))
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.3)
        plane.materials = [material]
        let planeNode = SCNNode(geometry: plane)
        planeNode.position = SCNVector3(planeAnchor.center.x, planeAnchor.center.y, planeAnchor.center.z)
        planeNode.eulerAngles = SCNVector3(-Float.pi/2, 0, 0)
        node.addChildNode(planeNode)
        let wallId = planeAnchor.identifier.uuidString
        wallNodes[wallId] = planeNode
        emit("wallDetected", data: ["wallIndex": wallId, "type": "vertical"])
    }
}

// MARK: - UIColor Hex Helper

extension UIColor {
    convenience init?(hex: String) {
        let r, g, b, a: CGFloat
        let start = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let scanner = Scanner(string: start)
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber) else { return nil }
        switch start.count {
        case 8: r = CGFloat((hexNumber & 0xff000000) >> 24) / 255; g = CGFloat((hexNumber & 0x00ff0000) >> 16) / 255; b = CGFloat((hexNumber & 0x0000ff00) >> 8) / 255; a = CGFloat(hexNumber & 0x000000ff) / 255
        case 6: r = CGFloat((hexNumber & 0xff0000) >> 16) / 255; g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255; b = CGFloat(hexNumber & 0x0000ff) / 255; a = 1.0
        default: return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
