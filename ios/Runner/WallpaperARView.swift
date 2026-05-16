// WallpaperARView.swift — PHASE A: Wireframe + Wallpaper on Mesh
// Single ARSession, proper UV mapping, wall area from mesh
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

    // ── Mesh state (only mutated on main thread) ─────────────
    private var meshNodes: [UUID: SCNNode] = [:]
    private var totalWallAreaSqm: Float = 0.0
    private var currentWallIndex: Int = 0
    private var wallNodes: [String: SCNNode] = [:]

    // ── Wallpaper textures ───────────────────────────────────
    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var isWallpaperApplied = false

    // ── Eraser ───────────────────────────────────────────────
    private var panGesture: UIPanGestureRecognizer?
    private var isEraserActive = false

    // ── Events ───────────────────────────────────────────────
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // ═══════════════════════════════════════════════════════════
    // WIREFRAME MATERIALS (lazy, created once, reused)
    // ═══════════════════════════════════════════════════════════

    private lazy var matWallWire: SCNMaterial = {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.65)
        m.isDoubleSided = true; m.lightingModel = .constant; return m
    }()
    private lazy var matCeilWire: SCNMaterial = {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.25)
        m.isDoubleSided = true; m.lightingModel = .constant; return m
    }()
    private lazy var matFloorWire: SCNMaterial = {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = UIColor.white.withAlphaComponent(0.12)
        m.isDoubleSided = true; m.lightingModel = .constant; return m
    }()
    private lazy var matDoorWire: SCNMaterial = {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = UIColor(red: 1.0, green: 0.83, blue: 0.41, alpha: 0.5)
        m.isDoubleSided = true; m.lightingModel = .constant; return m
    }()
    private lazy var matHidden: SCNMaterial = {
        let m = SCNMaterial(); m.diffuse.contents = UIColor.clear
        m.isDoubleSided = true; m.transparency = 0.0; return m
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
            self?.route(call, result)
        }
    }

    func view() -> UIView { sceneView }

    // ═══════════════════════════════════════════════════════════
    // METHOD ROUTER — every method ar_service.dart calls
    // ═══════════════════════════════════════════════════════════

    private func route(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {

        // ── Lifecycle ──
        case "initAR":       initAR(result: result)
        case "disposeAR":    sceneView.session.pause(); result(nil)
        case "setARMode":
            if let mode = call.arguments as? String { setARMode(mode, result: result) }
            else { result(FlutterError(code: "BAD_ARG", message: "mode string required", details: nil)) }
        case "startScan":    startScan(result: result)
        case "stopScan":     stopScan(result: result)

        // ── Wallpaper ──
        case "placeWallpaper", "switchWallpaper":
            placeWallpaper(args, result: result)
        case "selectWall":
            currentWallIndex = args?["wallIndex"] as? Int ?? 0
            emit("wallSelected", data: ["wallIndex": currentWallIndex])
            result(nil)
        case "clearWall":
            clearAllWallpaper()
            result(nil)
        case "lockWall":
            if let idx = args?["wallIndex"] as? Int, let locked = args?["locked"] as? Bool {
                emit("wallLockChanged", data: ["wallIndex": idx, "locked": locked])
            }
            result(nil)
        case "getWallMeasurements":
            result(["width": 0.0, "height": 0.0, "sqm": Double(totalWallAreaSqm)])

        // ── Eraser / Cut ──
        case "enterCutMode":  isEraserActive = true; result(nil)
        case "exitCutMode":   isEraserActive = false; result(nil)
        case "setBrushSize":
            if let s = args?["size"] as? CGFloat { eraserTool.brushSize = s }
            result(nil)
        case "setBrushColor":
            if let h = args?["color"] as? String { eraserTool.brushColor = UIColor(hex: h) ?? .white }
            result(nil)
        case "undoCut":       eraserTool.undoStroke(); result(nil)
        case "clearAllCuts":  eraserTool.resetMask(); result(nil)

        // ── Exclusion (for future use) ──
        case "toggleSurfaceExclusion", "toggleObjectExclusion":
            result(nil)

        // ── Anything else → not implemented ──
        default: result(FlutterMethodNotImplemented)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // AR LIFECYCLE
    // ═══════════════════════════════════════════════════════════

    private func initAR(result: @escaping FlutterResult) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.runIdleSession(result: result) }
                    else {
                        self?.emit("error", data: ["message": "Camera denied"])
                        result(FlutterError(code: "CAM", message: "Camera denied", details: nil))
                    }
                }
            }
            return
        }
        guard status == .authorized else {
            emit("error", data: ["message": "Camera denied"])
            result(FlutterError(code: "CAM", message: "Camera denied", details: nil))
            return
        }
        runIdleSession(result: result)
    }

    private func runIdleSession(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"])
            result(FlutterError(code: "NOAR", message: "ARKit not supported", details: nil))
            return
        }
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.vertical]
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        currentMode = .idle
        emit("boot", data: ["status": "AR session running"])
        result(nil)
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        guard let m = ARViewMode(rawValue: mode) else {
            result(FlutterError(code: "BAD_MODE", message: "Unknown: \(mode)", details: nil))
            return
        }
        currentMode = m
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    // ═══════════════════════════════════════════════════════════
    // SCAN — Single ARSession with LiDAR mesh
    // ═══════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan PHASE-A <<<"])

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            emit("error", data: ["message": "LiDAR mesh not supported"])
            result(FlutterError(code: "NOLIDAR", message: "Need LiDAR", details: nil))
            return
        }
        emit("boot", data: ["status": "LiDAR ✅"])

        // Clear previous
        for (_, n) in meshNodes { n.removeFromParentNode() }
        meshNodes.removeAll()
        wallNodes.removeAll()
        totalWallAreaSqm = 0
        isWallpaperApplied = false
        currentMode = .scanning

        // Single ARSession — mesh + planes, no RoomPlan
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.vertical, .horizontal]
        c.sceneReconstruction = .meshWithClassification
        c.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            c.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        emit("boot", data: ["status": "Scanning — move slowly around room"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        currentMode = .preview

        // ── Calculate total wall area from mesh triangles ──
        totalWallAreaSqm = 0
        if let frame = sceneView.session.currentFrame {
            for anchor in frame.anchors {
                guard let ma = anchor as? ARMeshAnchor else { continue }
                totalWallAreaSqm += computeWallArea(anchor: ma)
            }
        }

        emit("scanComplete", data: [
            "totalWallArea": totalWallAreaSqm,
            "meshSegments": meshNodes.count
        ])
        emit("boot", data: ["status": "Done: \(String(format: "%.1f", totalWallAreaSqm)) m² walls"])
        result(nil)
    }

    /// Computes the total area of wall-classified triangles in world space
    private func computeWallArea(anchor: ARMeshAnchor) -> Float {
        let geo = anchor.geometry
        let vSrc = geo.vertices
        let fEl = geo.faces
        let cOpt = geo.classification
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive
        let transform = anchor.transform
        var area: Float = 0

        for f in 0..<fEl.count {
            // Check classification
            var isWall = true
            if let c = cOpt {
                let cv = c.buffer.contents()
                    .advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                let cls = ARMeshClassification(rawValue: Int(cv)) ?? .none
                isWall = (cls == .wall)
            }
            guard isWall else { continue }

            // Get 3 vertex indices
            var idx: [Int] = []
            for j in 0..<ipf {
                let off = (f * ipf + j) * bpi
                let p = fEl.buffer.contents().advanced(by: off)
                if bpi == 4 { idx.append(Int(p.assumingMemoryBound(to: UInt32.self).pointee)) }
                else { idx.append(Int(p.assumingMemoryBound(to: UInt16.self).pointee)) }
            }
            guard idx.count == 3 else { continue }

            // Get world positions
            func worldPos(_ i: Int) -> SIMD3<Float> {
                let ptr = vSrc.buffer.contents()
                    .advanced(by: vSrc.offset + vSrc.stride * i)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let local = ptr.pointee
                let w = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                return SIMD3<Float>(w.x, w.y, w.z)
            }
            let p0 = worldPos(idx[0])
            let p1 = worldPos(idx[1])
            let p2 = worldPos(idx[2])
            let cross = simd_cross(p1 - p0, p2 - p0)
            area += simd_length(cross) * 0.5
        }
        return area
    }

    // ═══════════════════════════════════════════════════════════
    // MESH GEOMETRY BUILDER
    // ═══════════════════════════════════════════════════════════

    private func buildMeshGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        let vertCount = geo.vertices.count
        let faceCount = geo.faces.count
        guard vertCount > 0, faceCount > 0 else { return nil }

        let vSrc = geo.vertices
        let fEl = geo.faces
        let cOpt = geo.classification
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive
        let transform = anchor.transform

        // ── Extract vertices + generate UVs ──────────────────
        var verts: [SCNVector3] = []
        var uvs: [CGPoint] = []
        verts.reserveCapacity(vertCount)
        uvs.reserveCapacity(vertCount)

        for i in 0..<vertCount {
            let ptr = vSrc.buffer.contents()
                .advanced(by: vSrc.offset + vSrc.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self)
            let local = ptr.pointee
            verts.append(SCNVector3(local.x, local.y, local.z))

            // UV from world position for consistent tiling across room
            let w = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
            // Use world X+Z as horizontal, world Y as vertical
            // Tiles every ~0.53m (standard wallpaper roll width)
            let tileScale: Float = 1.0 / 0.53
            let u = (w.x + w.z) * tileScale
            let v = w.y * tileScale
            uvs.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
        }

        // ── Classify faces into buckets ──────────────────────
        var wallIdx:  [UInt32] = []
        var ceilIdx:  [UInt32] = []
        var floorIdx: [UInt32] = []
        var doorIdx:  [UInt32] = []

        for f in 0..<faceCount {
            // Classification (optional — default to wall if missing)
            var cls: ARMeshClassification = .wall
            if let c = cOpt {
                let cv = c.buffer.contents()
                    .advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                cls = ARMeshClassification(rawValue: Int(cv)) ?? .none
            }

            // Read triangle indices (flat-packed, no offset/stride)
            var tri: [UInt32] = []
            for j in 0..<ipf {
                let off = (f * ipf + j) * bpi
                let p = fEl.buffer.contents().advanced(by: off)
                if bpi == 4 { tri.append(p.assumingMemoryBound(to: UInt32.self).pointee) }
                else { tri.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)) }
            }

            switch cls {
            case .wall:          wallIdx.append(contentsOf: tri)
            case .ceiling:       ceilIdx.append(contentsOf: tri)
            case .floor:         floorIdx.append(contentsOf: tri)
            case .door, .window: doorIdx.append(contentsOf: tri)
            default:             wallIdx.append(contentsOf: tri) // unclassified → wall
            }
        }

        // ── Build SCNGeometry with UV source ─────────────────
        let vertSrc = SCNGeometrySource(vertices: verts)
        let uvSrc = SCNGeometrySource(textureCoordinates: uvs)

        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []

        func addElement(_ indices: [UInt32], _ mat: SCNMaterial) {
            guard !indices.isEmpty else { return }
            let data = Data(bytes: indices, count: indices.count * 4)
            elements.append(SCNGeometryElement(
                data: data, primitiveType: .triangles,
                primitiveCount: indices.count / 3, bytesPerIndex: 4))
            materials.append(mat)
        }

        // Wall: wireframe during scan, wallpaper when applied
        let wallMat = isWallpaperApplied ? makeWallpaperMaterial() : matWallWire
        addElement(wallIdx, wallMat)

        // Other surfaces: always wireframe (hidden after scan)
        if currentMode == .scanning {
            addElement(ceilIdx, matCeilWire)
            addElement(floorIdx, matFloorWire)
            addElement(doorIdx, matDoorWire)
        } else {
            // In preview: hide non-wall mesh so only wallpaper is visible
            addElement(ceilIdx, matHidden)
            addElement(floorIdx, matHidden)
            addElement(doorIdx, matHidden)
        }

        guard !elements.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: [vertSrc, uvSrc], elements: elements)
        geometry.materials = materials
        return geometry
    }

    // ═══════════════════════════════════════════════════════════
    // WALLPAPER MATERIAL
    // ═══════════════════════════════════════════════════════════

    private func makeWallpaperMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.fillMode = .fill
        m.isDoubleSided = true
        m.lightingModel = .physicallyBased
        m.transparency = 0.92 // slight see-through for realism

        if let img = wpAlbedo {
            m.diffuse.contents = img
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
        }
        if let img = wpNormal {
            m.normal.contents = img
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
            m.normal.intensity = 0.8
        }
        if let img = wpRoughness {
            m.roughness.contents = img
            m.roughness.wrapS = .repeat
            m.roughness.wrapT = .repeat
        }
        if let img = wpAO {
            m.ambientOcclusion.contents = img
            m.ambientOcclusion.wrapS = .repeat
            m.ambientOcclusion.wrapT = .repeat
        }
        return m
    }

    // ═══════════════════════════════════════════════════════════
    // APPLY / CLEAR WALLPAPER
    // ═══════════════════════════════════════════════════════════

    private func applyWallpaperToAllMeshes() {
        isWallpaperApplied = true
        guard let frame = sceneView.session.currentFrame else { return }
        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor,
                  let node = meshNodes[ma.identifier] else { continue }
            if let g = buildMeshGeometry(from: ma) { node.geometry = g }
        }
        emit("boot", data: ["status": "Wallpaper applied ✅"])
    }

    private func clearAllWallpaper() {
        isWallpaperApplied = false
        wpAlbedo = nil; wpNormal = nil; wpRoughness = nil; wpAO = nil
        guard let frame = sceneView.session.currentFrame else { return }
        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor,
                  let node = meshNodes[ma.identifier] else { continue }
            if let g = buildMeshGeometry(from: ma) { node.geometry = g }
        }
        emit("wallCleared", data: ["wallIndex": 0])
    }

    // ═══════════════════════════════════════════════════════════
    // PLACE WALLPAPER (loads textures then applies)
    // ═══════════════════════════════════════════════════════════

    private func placeWallpaper(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let args = args, let albedoUrl = args["albedoUrl"] as? String, !albedoUrl.isEmpty else {
            emit("wallpaperPlaced", data: ["success": false, "message": "No albedoUrl"])
            result(nil); return
        }
        let normalUrl    = args["normalUrl"] as? String ?? ""
        let roughnessUrl = args["roughnessUrl"] as? String ?? ""
        let aoUrl        = args["aoUrl"] as? String ?? ""
        let wallIndex    = args["wallIndex"] as? Int ?? 0

        emit("boot", data: ["status": "Loading textures..."])

        let group = DispatchGroup()
        var a: UIImage?, n: UIImage?, r: UIImage?, o: UIImage?

        group.enter()
        textureCache.loadImage(from: albedoUrl) { img in a = img; group.leave() }

        if !normalUrl.isEmpty {
            group.enter()
            textureCache.loadImage(from: normalUrl) { img in n = img; group.leave() }
        }
        if !roughnessUrl.isEmpty {
            group.enter()
            textureCache.loadImage(from: roughnessUrl) { img in r = img; group.leave() }
        }
        if !aoUrl.isEmpty {
            group.enter()
            textureCache.loadImage(from: aoUrl) { img in o = img; group.leave() }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            guard let albedo = a else {
                self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": false, "message": "Failed to load albedo texture"])
                self.emit("boot", data: ["status": "❌ Texture load failed"])
                result(nil); return
            }

            self.wpAlbedo = albedo
            self.wpNormal = n
            self.wpRoughness = r
            self.wpAO = o

            self.emit("boot", data: ["status": "Textures loaded, applying..."])
            self.applyWallpaperToAllMeshes()
            self.emit("wallpaperPlaced", data: ["wallIndex": wallIndex, "success": true])
            result(nil)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ERASER
    // ═══════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════
    // EVENT EMISSION
    // ═══════════════════════════════════════════════════════════

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
        guard let ma = anchor as? ARMeshAnchor else { return }
        guard currentMode == .scanning || currentMode == .preview else { return }
        guard let geo = buildMeshGeometry(from: ma) else { return }

        let meshNode = SCNNode(geometry: geo)
        node.addChildNode(meshNode)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.meshNodes[ma.identifier] = meshNode
            let count = self.meshNodes.count
            if count % 3 == 0 {
                self.emit("boot", data: ["status": "Scanning: \(count) mesh segments"])
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        guard currentMode == .scanning || currentMode == .preview else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let meshNode = self.meshNodes[ma.identifier],
                  let geo = self.buildMeshGeometry(from: ma) else { return }
            meshNode.geometry = geo
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        DispatchQueue.main.async { [weak self] in
            self?.meshNodes[ma.identifier]?.removeFromParentNode()
            self?.meshNodes.removeValue(forKey: ma.identifier)
        }
    }
}

// MARK: - UIColor Hex

extension UIColor {
    convenience init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let sc = Scanner(string: s); var n: UInt64 = 0
        guard sc.scanHexInt64(&n) else { return nil }
        switch s.count {
        case 8: self.init(red: CGFloat((n>>24)&0xff)/255, green: CGFloat((n>>16)&0xff)/255,
                          blue: CGFloat((n>>8)&0xff)/255, alpha: CGFloat(n&0xff)/255)
        case 6: self.init(red: CGFloat((n>>16)&0xff)/255, green: CGFloat((n>>8)&0xff)/255,
                          blue: CGFloat(n&0xff)/255, alpha: 1.0)
        default: return nil
        }
    }
}
