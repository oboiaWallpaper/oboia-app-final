// WallpaperARView.swift — LiDAR MESH v2 (AUDITED)
// NO RoomPlan during scan (avoids dual ARSession)
// Uses ARKit mesh for wireframe + plane anchors for wall dimensions
// Replace: ios/Runner/WallpaperARView.swift

import ARKit
import AVFoundation
import SceneKit
import Flutter
import UIKit

enum ARViewMode: String {
    case idle     = "idle"
    case scanning = "scanning"
    case preview  = "preview"
    case legacy   = "legacy"
}

final class WallpaperARView: NSObject, FlutterPlatformView {

    private let sceneView: ARSCNView
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel

    private var currentMode: ARViewMode = .idle
    private let textureCache = TextureCache.shared
    private let eraserTool = EraserTool()

    // ═══════════════════════════════════════════════════════════
    // MESH TRACKING (thread-safe: only mutated on main thread)
    // ═══════════════════════════════════════════════════════════
    private var meshNodes: [UUID: SCNNode] = [:]

    // ═══════════════════════════════════════════════════════════
    // PLANE TRACKING (for wall dimensions — invisible during scan)
    // ═══════════════════════════════════════════════════════════
    private var trackedPlanes: [UUID: ARPlaneAnchor] = [:]

    // ═══════════════════════════════════════════════════════════
    // WALLPAPER STATE
    // ═══════════════════════════════════════════════════════════
    private var wallNodes: [String: SCNNode] = [:]
    private var currentWallIndex: Int = 0
    private var pendingAlbedo: UIImage?
    private var pendingNormal: UIImage?
    private var pendingRoughness: UIImage?
    private var pendingAO: UIImage?
    private var isWallpaperApplied = false

    private var panGesture: UIPanGestureRecognizer?
    private var isEraserActive = false

    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // ═══════════════════════════════════════════════════════════
    // MATERIALS (lazy, created once)
    // ═══════════════════════════════════════════════════════════
    private lazy var wallWireframe: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.7)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    private lazy var ceilingWireframe: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.3)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    private lazy var floorWireframe: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.15)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    private lazy var openingWireframe: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor(red: 1.0, green: 0.83, blue: 0.41, alpha: 0.6)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    // ═══════════════════════════════════════════════════════════
    // INIT
    // ═══════════════════════════════════════════════════════════

    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
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
        panGesture = pan

        channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result)
        }
    }

    func view() -> UIView { sceneView }

    // MARK: - Method Router

    private func handleMethodCall(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "initAR":            initAR(result: result)
        case "disposeAR":         disposeAR(result: result)
        case "setARMode":
            if let mode = call.arguments as? String { setARMode(mode, result: result) }
            else { result(FlutterError(code: "INVALID_ARG", message: "mode required", details: nil)) }
        case "startScan":         startScan(result: result)
        case "stopScan":          stopScan(result: result)
        case "placeWallpaper":    placeWallpaper(call, result: result)
        case "switchWallpaper":   placeWallpaper(call, result: result)
        case "selectWall":        selectWall(call, result: result)
        case "clearWall":         clearWall(result: result)
        case "lockWall":          lockWall(call, result: result)
        case "getWallMeasurements": result(["width": 0.0, "height": 0.0, "sqm": 0.0])
        case "enterCutMode":      isEraserActive = true; result(nil)
        case "exitCutMode":       isEraserActive = false; result(nil)
        case "setBrushSize":
            if let s = (call.arguments as? [String: Any])?["size"] as? CGFloat { eraserTool.brushSize = s }
            result(nil)
        case "setBrushColor":
            if let h = (call.arguments as? [String: Any])?["color"] as? String { eraserTool.brushColor = UIColor(hex: h) ?? .white }
            result(nil)
        case "undoCut":           eraserTool.undoStroke(); result(nil)
        case "clearAllCuts":      eraserTool.resetMask(); applyMaskToCurrentWall(); result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - AR Lifecycle

    private func initAR(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.startIdleSession(result: result) }
                    else {
                        self?.emit("error", data: ["message": "Camera denied"])
                        result(FlutterError(code: "CAMERA_DENIED", message: "Camera denied", details: nil))
                    }
                }
            }
            return
        }
        guard status == .authorized else {
            emit("error", data: ["message": "Camera denied"])
            result(FlutterError(code: "CAMERA_DENIED", message: "Camera denied", details: nil))
            return
        }
        startIdleSession(result: result)
    }

    private func startIdleSession(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"])
            result(FlutterError(code: "NO_ARKIT", message: "ARKit not supported", details: nil))
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical]
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        currentMode = .idle
        emit("boot", data: ["status": "AR session running"])
        result(nil)
    }

    private func disposeAR(result: @escaping FlutterResult) {
        sceneView.session.pause()
        result(nil)
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        guard let m = ARViewMode(rawValue: mode) else {
            result(FlutterError(code: "INVALID_MODE", message: "Unknown: \(mode)", details: nil))
            return
        }
        currentMode = m
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    // MARK: - LiDAR Mesh Scan (NO RoomPlan — single ARSession only)

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan v3 MESH <<<"])

        // ═══════════════════════════════════════════════════════
        // CHECK: LiDAR mesh with classification
        // ═══════════════════════════════════════════════════════
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            emit("error", data: ["message": "LiDAR mesh not supported on this device"])
            result(FlutterError(code: "NO_LIDAR", message: "LiDAR mesh not supported", details: nil))
            return
        }
        emit("boot", data: ["status": "LiDAR mesh supported ✅"])

        // ═══════════════════════════════════════════════════════
        // CLEAR previous state
        // ═══════════════════════════════════════════════════════
        for (_, node) in meshNodes { node.removeFromParentNode() }
        meshNodes.removeAll()
        wallNodes.removeAll()
        trackedPlanes.removeAll()
        isWallpaperApplied = false
        currentMode = .scanning

        // ═══════════════════════════════════════════════════════
        // SINGLE ARSession with mesh + plane detection
        // NO RoomPlan — avoids dual ARSession conflict
        // Plane anchors give us wall dimensions for free
        // Mesh anchors give us the wireframe visual
        // ═══════════════════════════════════════════════════════
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.vertical, .horizontal]
        config.sceneReconstruction = .meshWithClassification
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }

        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        emit("boot", data: ["status": "Mesh scan LIVE — move around room slowly"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": "Stopping scan..."])
        currentMode = .preview

        // ═══════════════════════════════════════════════════════
        // BUILD surface list from tracked plane anchors
        // (wall dimensions come from ARKit plane detection, not RoomPlan)
        // ═══════════════════════════════════════════════════════
        var surfaces: [[String: Any]] = []
        var wallIdx = 0
        for (_, plane) in trackedPlanes {
            guard plane.alignment == .vertical else { continue }
            let w = plane.extent.x
            let h = plane.extent.z
            surfaces.append([
                "id": plane.identifier.uuidString,
                "type": "wall",
                "width": w,
                "height": h,
                "area": w * h,
                "excluded": false
            ])
            wallIdx += 1
        }

        // Encode as JSON matching the format Dart expects
        if let jsonData = try? JSONSerialization.data(withJSONObject: ["surfaces": surfaces, "objects": []], options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            emit("scanUpdate", data: ["data": jsonString])
        }

        emit("scanComplete", data: ["snapshot": "mesh"])
        emit("boot", data: ["status": "Scan done: \(meshNodes.count) mesh, \(surfaces.count) walls"])
        result(nil)
    }

    // MARK: - Mesh Geometry Builder (AUDITED: correct buffer access)

    private func buildMeshGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        let vertCount = geo.vertices.count
        let faceCount = geo.faces.count
        guard vertCount > 0, faceCount > 0 else { return nil }

        // ── Vertices (ARGeometrySource — has offset + stride) ──
        let vSrc = geo.vertices
        var verts: [SCNVector3] = []
        verts.reserveCapacity(vertCount)
        for i in 0..<vertCount {
            let ptr = vSrc.buffer.contents()
                .advanced(by: vSrc.offset + vSrc.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self)
            verts.append(SCNVector3(ptr.pointee.x, ptr.pointee.y, ptr.pointee.z))
        }

        // ── Classification (ARGeometrySource — has offset + stride) ──
        let cSrc = geo.classification

        // ── Faces (ARGeometryElement — NO offset/stride, flat packed) ──
        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex         // 2 or 4
        let ipf = fEl.indexCountPerPrimitive // 3 for triangles

        // Buckets by classification
        var wallIdx:    [UInt32] = []
        var ceilIdx:    [UInt32] = []
        var floorIdx:   [UInt32] = []
        var openIdx:    [UInt32] = []

        for f in 0..<faceCount {
            // Classification value for this face
            let cPtr = cSrc.buffer.contents()
                .advanced(by: cSrc.offset + cSrc.stride * f)
                .assumingMemoryBound(to: UInt8.self)
            let cls = ARMeshClassification(rawValue: Int(cPtr.pointee)) ?? .none

            // Triangle indices (flat packed in face buffer)
            var tri: [UInt32] = []
            tri.reserveCapacity(ipf)
            for j in 0..<ipf {
                let byteOff = (f * ipf + j) * bpi
                let p = fEl.buffer.contents().advanced(by: byteOff)
                if bpi == 4 {
                    tri.append(p.assumingMemoryBound(to: UInt32.self).pointee)
                } else {
                    tri.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee))
                }
            }

            switch cls {
            case .wall:           wallIdx.append(contentsOf: tri)
            case .ceiling:        ceilIdx.append(contentsOf: tri)
            case .floor:          floorIdx.append(contentsOf: tri)
            case .door, .window:  openIdx.append(contentsOf: tri)
            default: break // skip unclassified
            }
        }

        // ── Build multi-material SCNGeometry ──
        let src = SCNGeometrySource(vertices: verts)
        var elems: [SCNGeometryElement] = []
        var mats:  [SCNMaterial] = []

        func add(_ indices: [UInt32], _ mat: SCNMaterial) {
            guard !indices.isEmpty else { return }
            let d = Data(bytes: indices, count: indices.count * 4)
            elems.append(SCNGeometryElement(data: d, primitiveType: .triangles,
                                            primitiveCount: indices.count / 3, bytesPerIndex: 4))
            mats.append(mat)
        }

        add(wallIdx,  isWallpaperApplied ? makeWallpaperMaterial() : wallWireframe)
        add(ceilIdx,  ceilingWireframe)
        add(floorIdx, floorWireframe)
        add(openIdx,  openingWireframe)

        guard !elems.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: [src], elements: elems)
        geometry.materials = mats
        return geometry
    }

    // MARK: - Wallpaper Material

    private func makeWallpaperMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.fillMode = .fill
        m.isDoubleSided = true
        m.lightingModel = .physicallyBased
        m.transparency = 0.90

        if let img = pendingAlbedo {
            m.diffuse.contents = img
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(2.0, 2.0, 1.0)
        }
        if let img = pendingNormal {
            m.normal.contents = img
            m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
            m.normal.contentsTransform = SCNMatrix4MakeScale(2.0, 2.0, 1.0)
            m.normal.intensity = 0.8
        }
        if let img = pendingRoughness {
            m.roughness.contents = img
            m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat
            m.roughness.contentsTransform = SCNMatrix4MakeScale(2.0, 2.0, 1.0)
        }
        if let img = pendingAO {
            m.ambientOcclusion.contents = img
            m.ambientOcclusion.wrapS = .repeat; m.ambientOcclusion.wrapT = .repeat
            m.ambientOcclusion.contentsTransform = SCNMatrix4MakeScale(2.0, 2.0, 1.0)
        }
        return m
    }

    /// Re-renders all mesh nodes with wallpaper on wall faces
    private func applyWallpaperToMeshes() {
        isWallpaperApplied = true
        guard let frame = sceneView.session.currentFrame else { return }

        for anchor in frame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor,
                  let node = meshNodes[meshAnchor.identifier] else { continue }
            if let geo = buildMeshGeometry(from: meshAnchor) {
                node.geometry = geo
            }
        }
        emit("boot", data: ["status": "Wallpaper applied to walls ✅"])
    }

    // MARK: - Wallpaper API

    private func placeWallpaper(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let albedoUrl = args["albedoUrl"] as? String else {
            result(FlutterError(code: "INVALID_ARG", message: "albedoUrl required", details: nil))
            return
        }
        let normalUrl = args["normalUrl"] as? String ?? ""
        let roughnessUrl = args["roughnessUrl"] as? String ?? ""
        let aoUrl = args["aoUrl"] as? String ?? ""
        let wallIndex = args["wallIndex"] as? Int ?? 0

        emit("boot", data: ["status": "Loading textures..."])

        let group = DispatchGroup()
        var a: UIImage?, n: UIImage?, r: UIImage?, o: UIImage?

        group.enter(); textureCache.loadImage(from: albedoUrl) { a = $0; group.leave() }
        if !normalUrl.isEmpty   { group.enter(); textureCache.loadImage(from: normalUrl)    { n = $0; group.leave() } }
        if !roughnessUrl.isEmpty { group.enter(); textureCache.loadImage(from: roughnessUrl) { r = $0; group.leave() } }
        if !aoUrl.isEmpty       { group.enter(); textureCache.loadImage(from: aoUrl)        { o = $0; group.leave() } }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, let albedo = a else {
                self?.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": false])
                result(nil); return
            }
            self.pendingAlbedo = albedo
            self.pendingNormal = n
            self.pendingRoughness = r
            self.pendingAO = o

            self.applyWallpaperToMeshes()
            self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": true])
            result(nil)
        }
    }

    private func selectWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let idx = (call.arguments as? [String: Any])?["wallIndex"] as? Int {
            currentWallIndex = idx
            emit("wallSelected", data: ["wallIndex": idx])
        }
        result(nil)
    }

    private func clearWall(result: @escaping FlutterResult) {
        isWallpaperApplied = false
        pendingAlbedo = nil
        // Re-render meshes as wireframe
        guard let frame = sceneView.session.currentFrame else { result(nil); return }
        for anchor in frame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor,
                  let node = meshNodes[meshAnchor.identifier] else { continue }
            if let geo = buildMeshGeometry(from: meshAnchor) { node.geometry = geo }
        }
        emit("wallCleared", data: ["wallIndex": 0])
        result(nil)
    }

    private func lockWall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if let args = call.arguments as? [String: Any],
           let idx = args["wallIndex"] as? Int, let locked = args["locked"] as? Bool {
            emit("wallLockChanged", data: ["wallIndex": idx, "locked": locked])
        }
        result(nil)
    }

    // MARK: - Eraser

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isEraserActive else { return }
        let loc = gesture.location(in: sceneView)
        switch gesture.state {
        case .began:             eraserTool.startStroke(at: loc)
        case .changed:           eraserTool.continueStroke(at: loc); applyMaskToCurrentWall()
        case .ended, .cancelled: eraserTool.endStroke(); applyMaskToCurrentWall()
                                 emit("cutUpdate", data: ["wallIndex": currentWallIndex])
        default: break
        }
    }

    private func applyMaskToCurrentWall() {
        guard let node = wallNodes[String(currentWallIndex)],
              let mat = node.geometry?.firstMaterial else { return }
        eraserTool.applyMask(to: mat)
    }

    // MARK: - Event Emission

    private func emit(_ type: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = ["type": type, "data": data]
        if let sink = eventSink { sink(payload) }
        else { pendingEvents.append(payload) }
    }
}

// MARK: - FlutterStreamHandler

extension WallpaperARView: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = { event in events(event) }
        for e in pendingEvents { events(e) }
        pendingEvents.removeAll()
        emit("boot", data: ["status": "Dart listener attached"])
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil; return nil
    }
}

// MARK: - ARSCNViewDelegate + ARSessionDelegate

extension WallpaperARView: ARSCNViewDelegate, ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {}

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        // ── MESH ANCHOR: build wireframe ──
        if let meshAnchor = anchor as? ARMeshAnchor {
            guard currentMode == .scanning || currentMode == .preview else { return }
            if let geo = buildMeshGeometry(from: meshAnchor) {
                let meshNode = SCNNode(geometry: geo)
                node.addChildNode(meshNode)
                // Thread-safe: dispatch dictionary mutation to main
                DispatchQueue.main.async { [weak self] in
                    self?.meshNodes[meshAnchor.identifier] = meshNode
                    let count = self?.meshNodes.count ?? 0
                    if count % 5 == 0 { // don't spam events
                        self?.emit("boot", data: ["status": "Mesh: \(count) segments"])
                    }
                }
            }
            return
        }

        // ── PLANE ANCHOR: track for wall dimensions (invisible during scan) ──
        if let planeAnchor = anchor as? ARPlaneAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.trackedPlanes[planeAnchor.identifier] = planeAnchor

                // Send live update to Dart during scanning
                if self?.currentMode == .scanning {
                    let wallCount = self?.trackedPlanes.values.filter({ $0.alignment == .vertical }).count ?? 0
                    self?.emit("boot", data: ["status": "Scanning: \(wallCount) walls found"])
                }
            }

            // In idle/legacy mode, show visible plane overlays
            if currentMode == .idle || currentMode == .legacy {
                guard planeAnchor.alignment == .vertical else { return }
                let plane = SCNPlane(width: CGFloat(planeAnchor.extent.x), height: CGFloat(planeAnchor.extent.z))
                let mat = SCNMaterial()
                mat.diffuse.contents = UIColor.white.withAlphaComponent(0.3)
                plane.materials = [mat]
                let planeNode = SCNNode(geometry: plane)
                planeNode.position = SCNVector3(planeAnchor.center.x, planeAnchor.center.y, planeAnchor.center.z)
                planeNode.eulerAngles = SCNVector3(-Float.pi/2, 0, 0)
                node.addChildNode(planeNode)
            }
            return
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        // ── Update mesh as LiDAR refines ──
        if let meshAnchor = anchor as? ARMeshAnchor {
            guard currentMode == .scanning || currentMode == .preview else { return }
            DispatchQueue.main.async { [weak self] in
                if let meshNode = self?.meshNodes[meshAnchor.identifier],
                   let geo = self?.buildMeshGeometry(from: meshAnchor) {
                    meshNode.geometry = geo
                }
            }
            return
        }

        // ── Update tracked plane dimensions ──
        if let planeAnchor = anchor as? ARPlaneAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.trackedPlanes[planeAnchor.identifier] = planeAnchor
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.meshNodes[meshAnchor.identifier]?.removeFromParentNode()
                self?.meshNodes.removeValue(forKey: meshAnchor.identifier)
            }
        }
        if let planeAnchor = anchor as? ARPlaneAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.trackedPlanes.removeValue(forKey: planeAnchor.identifier)
            }
        }
    }
}

// MARK: - UIColor Hex

extension UIColor {
    convenience init?(hex: String) {
        let r, g, b, a: CGFloat
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let sc = Scanner(string: s)
        var n: UInt64 = 0
        guard sc.scanHexInt64(&n) else { return nil }
        switch s.count {
        case 8: r = CGFloat((n >> 24) & 0xff)/255; g = CGFloat((n >> 16) & 0xff)/255
                b = CGFloat((n >> 8) & 0xff)/255;  a = CGFloat(n & 0xff)/255
        case 6: r = CGFloat((n >> 16) & 0xff)/255; g = CGFloat((n >> 8) & 0xff)/255
                b = CGFloat(n & 0xff)/255;          a = 1.0
        default: return nil
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
