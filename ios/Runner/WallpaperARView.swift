// WallpaperARView.swift — PHASE 1: Soft Brush Selection
// Per-face selection, gold overlay in edit mode, wallpaper on selected faces
// Replace: ios/Runner/WallpaperARView.swift

import ARKit
import AVFoundation
import SceneKit
import Flutter
import UIKit

enum ARViewMode: String {
    case idle = "idle", scanning = "scanning", preview = "preview", legacy = "legacy"
}
enum BrushMode { case paint, erase }

final class WallpaperARView: NSObject, FlutterPlatformView {

    private let sceneView: ARSCNView
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel

    private var currentMode: ARViewMode = .idle
    private let textureCache = TextureCache.shared
    private let eraserTool = EraserTool()

    // ── Mesh ─────────────────────────────────────────────────
    private var meshNodes: [UUID: SCNNode] = [:]
    private var meshFrozen = false

    // ── Selection system ─────────────────────────────────────
    /// Per mesh anchor: set of face indices that are SELECTED (will get wallpaper)
    private var selectedFaces: [UUID: Set<Int>] = [:]
    /// Precomputed face centroids in WORLD space for brush hit testing
    private var faceCentroids: [UUID: [SIMD3<Float>]] = [:]
    /// Total face count per anchor (for reset)
    private var faceCounts: [UUID: Int] = [:]
    /// Undo stack — each entry is a snapshot of selectedFaces for ONE anchor
    private var undoStack: [(UUID, Set<Int>)] = []
    private let maxUndo = 20
    /// Which anchor is currently being brushed
    private var activeBrushAnchor: UUID?

    // ── Brush ────────────────────────────────────────────────
    private var brushMode: BrushMode = .erase
    private var brushRadius: Float = 0.08 // meters (8cm default)
    private var editModeActive = false
    private var lastBrushWorld: SIMD3<Float>?
    private let brushMoveThreshold: Float = 0.005 // 5mm — rebuild only if moved this far

    // ── Wallpaper ────────────────────────────────────────────
    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var isWallpaperApplied = false
    private var totalSelectedAreaSqm: Float = 0.0

    // ── Other ────────────────────────────────────────────────
    private var currentWallIndex: Int = 0
    private var wallNodes: [String: SCNNode] = [:]
    private var panGesture: UIPanGestureRecognizer?
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // ═══════════════════════════════════════════════════════════
    // MATERIALS
    // ═══════════════════════════════════════════════════════════

    // Scan phase wireframes
    private lazy var matWallWire: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.65))
    private lazy var matCeilWire: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.25))
    private lazy var matFloorWire: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.12))
    private lazy var matDoorWire: SCNMaterial = makeWire(UIColor(red:1,green:0.83,blue:0.41,alpha:0.5))

    // Edit phase: gold selection overlay (semi-transparent fill)
    private lazy var matGoldSel: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .fill
        m.diffuse.contents = UIColor(red: 1.0, green: 0.83, blue: 0.41, alpha: 0.25)
        m.isDoubleSided = true
        m.lightingModel = .constant
        m.writesToDepthBuffer = true
        return m
    }()

    // Edit phase: gold wireframe on top of fill
    private lazy var matGoldWire: SCNMaterial = {
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor(red: 1.0, green: 0.83, blue: 0.41, alpha: 0.4)
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    // Hidden material
    private lazy var matHidden: SCNMaterial = {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.clear
        m.isDoubleSided = true
        m.transparency = 0.0
        m.writesToDepthBuffer = false
        return m
    }()

    private func makeWire(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = color
        m.isDoubleSided = true; m.lightingModel = .constant; return m
    }

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
    // METHOD ROUTER
    // ═══════════════════════════════════════════════════════════

    private func route(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {

        // Lifecycle
        case "initAR":       initAR(result: result)
        case "disposeAR":    sceneView.session.pause(); result(nil)
        case "setARMode":
            if let m = call.arguments as? String { setARMode(m, result: result) }
            else { result(FlutterError(code: "BAD", message: "mode string needed", details: nil)) }
        case "startScan":    startScan(result: result)
        case "stopScan":     stopScan(result: result)

        // Brush / Edit
        case "enterCutMode":
            enterEditMode()
            result(nil)
        case "exitCutMode":
            exitEditMode()
            result(nil)
        case "setBrushMode":
            if let m = call.arguments as? String {
                brushMode = (m == "paint") ? .paint : .erase
                emit("boot", data: ["status": "Brush: \(m)"])
            }
            result(nil)
        case "setBrushSize":
            if let s = args?["size"] as? Double {
                brushRadius = Float(s)
                emit("boot", data: ["status": "Brush size: \(Int(s * 100))cm"])
            }
            result(nil)
        case "undoCut":
            undoSelection()
            result(nil)
        case "clearAllCuts":
            resetSelection()
            result(nil)

        // Wallpaper
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
            if let i = args?["wallIndex"] as? Int, let l = args?["locked"] as? Bool {
                emit("wallLockChanged", data: ["wallIndex": i, "locked": l])
            }
            result(nil)
        case "getWallMeasurements":
            result(["width": 0.0, "height": 0.0, "sqm": Double(totalSelectedAreaSqm)])

        // Passthrough
        case "toggleSurfaceExclusion", "toggleObjectExclusion", "setBrushColor":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // AR LIFECYCLE
    // ═══════════════════════════════════════════════════════════

    private func initAR(result: @escaping FlutterResult) {
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        if st == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.runIdleSession(result: result) }
                    else {
                        self?.emit("error", data: ["message": "Camera denied"])
                        result(FlutterError(code: "CAM", message: "denied", details: nil))
                    }
                }
            }; return
        }
        guard st == .authorized else {
            emit("error", data: ["message": "Camera denied"])
            result(FlutterError(code: "CAM", message: "denied", details: nil)); return
        }
        runIdleSession(result: result)
    }

    private func runIdleSession(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"])
            result(FlutterError(code: "NOAR", message: "no ARKit", details: nil)); return
        }
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.vertical]
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        currentMode = .idle
        emit("boot", data: ["status": "AR session running"])
        result(nil)
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        if let m = ARViewMode(rawValue: mode) { currentMode = m }
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    // ═══════════════════════════════════════════════════════════
    // SCAN
    // ═══════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan PHASE1 <<<"])
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            emit("error", data: ["message": "LiDAR mesh not supported"])
            result(FlutterError(code: "NOLIDAR", message: "Need LiDAR", details: nil)); return
        }

        for (_, n) in meshNodes { n.removeFromParentNode() }
        meshNodes.removeAll(); selectedFaces.removeAll()
        faceCentroids.removeAll(); faceCounts.removeAll()
        wallNodes.removeAll(); undoStack.removeAll()
        totalSelectedAreaSqm = 0; isWallpaperApplied = false
        meshFrozen = false; editModeActive = false
        currentMode = .scanning

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
        meshFrozen = true
        currentMode = .preview

        // Switch to plain config (stops mesh generation)
        let plain = ARWorldTrackingConfiguration()
        plain.planeDetection = []
        plain.environmentTexturing = .automatic
        sceneView.session.run(plain, options: [])

        // Precompute face centroids + initialize all faces as SELECTED
        guard let frame = sceneView.session.currentFrame else {
            emit("scanComplete", data: ["totalWallArea": 0, "meshSegments": meshNodes.count])
            result(nil); return
        }

        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            let uuid = ma.identifier
            let count = ma.geometry.faces.count

            // Initialize: ALL faces selected
            selectedFaces[uuid] = Set(0..<count)
            faceCounts[uuid] = count

            // Precompute world-space centroids for brush hit testing
            faceCentroids[uuid] = computeCentroids(anchor: ma)
        }

        // Calculate initial area (all wall-classified faces)
        totalSelectedAreaSqm = computeSelectedArea()

        // Rebuild all mesh nodes in preview mode (wallpaper on wall faces, hide rest)
        rebuildAllMeshNodes()

        let wallArea = totalSelectedAreaSqm
        emit("scanComplete", data: [
            "totalWallArea": wallArea,
            "meshSegments": meshNodes.count
        ])
        emit("boot", data: ["status": "Done: \(String(format: "%.1f", wallArea)) m² walls"])
        result(nil)
    }

    // ═══════════════════════════════════════════════════════════
    // CENTROID PRECOMPUTATION
    // ═══════════════════════════════════════════════════════════

    private func computeCentroids(anchor: ARMeshAnchor) -> [SIMD3<Float>] {
        let geo = anchor.geometry
        let vSrc = geo.vertices
        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive
        let transform = anchor.transform

        var centroids: [SIMD3<Float>] = []
        centroids.reserveCapacity(fEl.count)

        for f in 0..<fEl.count {
            var sum = SIMD3<Float>(0, 0, 0)
            for j in 0..<ipf {
                let off = (f * ipf + j) * bpi
                let p = fEl.buffer.contents().advanced(by: off)
                let idx: Int
                if bpi == 4 { idx = Int(p.assumingMemoryBound(to: UInt32.self).pointee) }
                else { idx = Int(p.assumingMemoryBound(to: UInt16.self).pointee) }

                let vPtr = vSrc.buffer.contents()
                    .advanced(by: vSrc.offset + vSrc.stride * idx)
                    .assumingMemoryBound(to: SIMD3<Float>.self)
                let local = vPtr.pointee
                let w = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                sum += SIMD3<Float>(w.x, w.y, w.z)
            }
            centroids.append(sum / Float(ipf))
        }
        return centroids
    }

    // ═══════════════════════════════════════════════════════════
    // SELECTED AREA CALCULATION
    // ═══════════════════════════════════════════════════════════

    private func computeSelectedArea() -> Float {
        guard let frame = sceneView.session.currentFrame else { return 0 }
        var total: Float = 0

        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            let uuid = ma.identifier
            guard let selected = selectedFaces[uuid] else { continue }
            let geo = ma.geometry
            let vSrc = geo.vertices
            let fEl = geo.faces
            let bpi = fEl.bytesPerIndex
            let ipf = fEl.indexCountPerPrimitive
            let transform = ma.transform

            for f in selected {
                guard f < fEl.count else { continue }
                var positions: [SIMD3<Float>] = []
                for j in 0..<ipf {
                    let off = (f * ipf + j) * bpi
                    let p = fEl.buffer.contents().advanced(by: off)
                    let idx: Int
                    if bpi == 4 { idx = Int(p.assumingMemoryBound(to: UInt32.self).pointee) }
                    else { idx = Int(p.assumingMemoryBound(to: UInt16.self).pointee) }

                    let vPtr = vSrc.buffer.contents()
                        .advanced(by: vSrc.offset + vSrc.stride * idx)
                        .assumingMemoryBound(to: SIMD3<Float>.self)
                    let local = vPtr.pointee
                    let w = transform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                    positions.append(SIMD3<Float>(w.x, w.y, w.z))
                }
                if positions.count == 3 {
                    total += simd_length(simd_cross(positions[1] - positions[0], positions[2] - positions[0])) * 0.5
                }
            }
        }
        return total
    }

    // ═══════════════════════════════════════════════════════════
    // EDIT MODE
    // ═══════════════════════════════════════════════════════════

    private func enterEditMode() {
        editModeActive = true
        isWallpaperApplied = false
        rebuildAllMeshNodes()
        emit("boot", data: ["status": "Edit mode — paint or erase selection"])
    }

    private func exitEditMode() {
        editModeActive = false
        totalSelectedAreaSqm = computeSelectedArea()
        rebuildAllMeshNodes()
        emit("boot", data: ["status": "Selection: \(String(format: "%.1f", totalSelectedAreaSqm)) m²"])
        emit("selectionChanged", data: ["area": totalSelectedAreaSqm])
    }

    private func undoSelection() {
        guard let last = undoStack.popLast() else { return }
        selectedFaces[last.0] = last.1
        rebuildMeshNode(for: last.0)
        emit("boot", data: ["status": "Undo (\(undoStack.count) left)"])
    }

    private func resetSelection() {
        // Re-select ALL faces for every anchor
        for (uuid, count) in faceCounts {
            selectedFaces[uuid] = Set(0..<count)
        }
        undoStack.removeAll()
        rebuildAllMeshNodes()
        emit("boot", data: ["status": "Selection reset — all faces selected"])
    }

    // ═══════════════════════════════════════════════════════════
    // BRUSH — Pan Gesture Handler
    // ═══════════════════════════════════════════════════════════

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive else { return }

        let screenPt = gesture.location(in: sceneView)

        switch gesture.state {
        case .began:
            lastBrushWorld = nil
            activeBrushAnchor = nil
            // Hit test to find which mesh we're touching
            if let hit = meshHitTest(screenPt) {
                // Save undo snapshot for the hit anchor
                if let uuid = anchorUUID(for: hit.node),
                   let current = selectedFaces[uuid] {
                    undoStack.append((uuid, current))
                    if undoStack.count > maxUndo { undoStack.removeFirst() }
                    activeBrushAnchor = uuid
                }
                applyBrush(at: hit.worldCoordinates)
            }

        case .changed:
            if let hit = meshHitTest(screenPt) {
                let worldPt = SIMD3<Float>(Float(hit.worldCoordinates.x),
                                           Float(hit.worldCoordinates.y),
                                           Float(hit.worldCoordinates.z))
                // Throttle: only update if moved enough
                if let last = lastBrushWorld, simd_distance(last, worldPt) < brushMoveThreshold {
                    return
                }
                lastBrushWorld = worldPt
                applyBrush(at: hit.worldCoordinates)
            }

        case .ended, .cancelled:
            lastBrushWorld = nil
            activeBrushAnchor = nil
            // Recalculate area after stroke
            totalSelectedAreaSqm = computeSelectedArea()
            emit("selectionChanged", data: ["area": totalSelectedAreaSqm])

        default: break
        }
    }

    private func meshHitTest(_ screenPt: CGPoint) -> SCNHitTestResult? {
        let results = sceneView.hitTest(screenPt, options: [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue
        ])
        // Find first hit on a mesh node
        for r in results {
            if anchorUUID(for: r.node) != nil { return r }
        }
        return nil
    }

    /// Find which mesh anchor UUID a node belongs to
    private func anchorUUID(for node: SCNNode) -> UUID? {
        var current: SCNNode? = node
        while let n = current {
            for (uuid, meshNode) in meshNodes {
                if n === meshNode { return uuid }
            }
            current = n.parent
        }
        return nil
    }

    private func applyBrush(at worldCoords: SCNVector3) {
        let brushPt = SIMD3<Float>(Float(worldCoords.x), Float(worldCoords.y), Float(worldCoords.z))

        // Apply to all nearby mesh anchors (brush might span anchor boundaries)
        var rebuiltUUIDs: Set<UUID> = []

        for (uuid, centroids) in faceCentroids {
            guard var selected = selectedFaces[uuid] else { continue }
            var changed = false

            for (faceIdx, centroid) in centroids.enumerated() {
                let dist = simd_distance(brushPt, centroid)
                if dist <= brushRadius {
                    if brushMode == .paint {
                        if !selected.contains(faceIdx) {
                            selected.insert(faceIdx)
                            changed = true
                        }
                    } else { // erase
                        if selected.contains(faceIdx) {
                            selected.remove(faceIdx)
                            changed = true
                        }
                    }
                }
            }

            if changed {
                selectedFaces[uuid] = selected
                rebuiltUUIDs.insert(uuid)
            }
        }

        // Rebuild affected mesh nodes
        for uuid in rebuiltUUIDs {
            rebuildMeshNode(for: uuid)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GEOMETRY BUILDERS
    // ═══════════════════════════════════════════════════════════

    private func rebuildAllMeshNodes() {
        guard let frame = sceneView.session.currentFrame else { return }
        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            rebuildMeshNode(for: ma.identifier)
        }
    }

    private func rebuildMeshNode(for uuid: UUID) {
        guard let node = meshNodes[uuid] else { return }
        guard let frame = sceneView.session.currentFrame else { return }
        guard let anchor = frame.anchors.first(where: { $0.identifier == uuid }) as? ARMeshAnchor else { return }

        if let geo = buildGeometryForMode(from: anchor) {
            node.geometry = geo
        }
    }

    private func buildGeometryForMode(from anchor: ARMeshAnchor) -> SCNGeometry? {
        if currentMode == .scanning {
            return buildScanGeometry(from: anchor)
        } else if editModeActive {
            return buildEditGeometry(from: anchor)
        } else if isWallpaperApplied {
            return buildWallpaperGeometry(from: anchor)
        } else {
            // Preview mode, no wallpaper yet — show wall wireframe for selected faces
            return buildEditGeometry(from: anchor)
        }
    }

    /// Scan phase: classification-based wireframe (wall/ceiling/floor/door)
    private func buildScanGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }

        let verts = extractVertices(geo)
        let cOpt = geo.classification
        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive

        var wallI: [UInt32] = [], ceilI: [UInt32] = []
        var floorI: [UInt32] = [], doorI: [UInt32] = []

        for f in 0..<fEl.count {
            var cls: ARMeshClassification = .none
            if let c = cOpt {
                let cv = c.buffer.contents().advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                cls = ARMeshClassification(rawValue: Int(cv)) ?? .none
            }
            let tri = readFaceIndices(fEl, face: f, bpi: bpi, ipf: ipf)
            switch cls {
            case .wall: wallI.append(contentsOf: tri)
            case .ceiling: ceilI.append(contentsOf: tri)
            case .floor: floorI.append(contentsOf: tri)
            case .door, .window: doorI.append(contentsOf: tri)
            default: break
            }
        }

        let src = SCNGeometrySource(vertices: verts)
        var els: [SCNGeometryElement] = [], mats: [SCNMaterial] = []
        addEl(&els, &mats, wallI, matWallWire)
        addEl(&els, &mats, ceilI, matCeilWire)
        addEl(&els, &mats, floorI, matFloorWire)
        addEl(&els, &mats, doorI, matDoorWire)
        guard !els.isEmpty else { return nil }
        let g = SCNGeometry(sources: [src], elements: els); g.materials = mats; return g
    }

    /// Edit phase: gold overlay on selected faces, hidden on unselected
    private func buildEditGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }

        let verts = extractVertices(geo)
        let selected = selectedFaces[anchor.identifier] ?? Set<Int>()
        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive

        var selI: [UInt32] = []
        var unselI: [UInt32] = []

        for f in 0..<fEl.count {
            let tri = readFaceIndices(fEl, face: f, bpi: bpi, ipf: ipf)
            if selected.contains(f) {
                selI.append(contentsOf: tri)
            } else {
                unselI.append(contentsOf: tri)
            }
        }

        let src = SCNGeometrySource(vertices: verts)
        var els: [SCNGeometryElement] = [], mats: [SCNMaterial] = []
        addEl(&els, &mats, selI, matGoldSel)    // gold semi-transparent
        addEl(&els, &mats, unselI, matHidden)    // invisible
        guard !els.isEmpty else { return nil }
        let g = SCNGeometry(sources: [src], elements: els); g.materials = mats; return g
    }

    /// Wallpaper phase: wallpaper on selected faces, hidden on unselected
    private func buildWallpaperGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }

        let verts = extractVertices(geo)
        let uvs = generateUVs(geo, transform: anchor.transform)
        let selected = selectedFaces[anchor.identifier] ?? Set<Int>()
        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive

        var selI: [UInt32] = []

        for f in 0..<fEl.count {
            if selected.contains(f) {
                selI.append(contentsOf: readFaceIndices(fEl, face: f, bpi: bpi, ipf: ipf))
            }
        }

        let vertSrc = SCNGeometrySource(vertices: verts)
        let uvSrc = SCNGeometrySource(textureCoordinates: uvs)
        var els: [SCNGeometryElement] = [], mats: [SCNMaterial] = []
        addEl(&els, &mats, selI, makeWallpaperMaterial())
        guard !els.isEmpty else { return nil }
        let g = SCNGeometry(sources: [vertSrc, uvSrc], elements: els); g.materials = mats; return g
    }

    // ── Geometry Helpers ─────────────────────────────────────

    private func extractVertices(_ geo: ARMeshGeometry) -> [SCNVector3] {
        let vSrc = geo.vertices
        var v: [SCNVector3] = []
        v.reserveCapacity(vSrc.count)
        for i in 0..<vSrc.count {
            let p = vSrc.buffer.contents().advanced(by: vSrc.offset + vSrc.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            v.append(SCNVector3(p.x, p.y, p.z))
        }
        return v
    }

    private func generateUVs(_ geo: ARMeshGeometry, transform: simd_float4x4) -> [CGPoint] {
        let vSrc = geo.vertices
        var uvs: [CGPoint] = []
        uvs.reserveCapacity(vSrc.count)
        let s: Float = 1.0 / 0.53
        for i in 0..<vSrc.count {
            let p = vSrc.buffer.contents().advanced(by: vSrc.offset + vSrc.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let w = transform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
            uvs.append(CGPoint(x: CGFloat((w.x + w.z) * s), y: CGFloat(w.y * s)))
        }
        return uvs
    }

    private func readFaceIndices(_ fEl: ARGeometryElement, face f: Int, bpi: Int, ipf: Int) -> [UInt32] {
        var tri: [UInt32] = []
        for j in 0..<ipf {
            let off = (f * ipf + j) * bpi
            let p = fEl.buffer.contents().advanced(by: off)
            if bpi == 4 { tri.append(p.assumingMemoryBound(to: UInt32.self).pointee) }
            else { tri.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)) }
        }
        return tri
    }

    private func addEl(_ els: inout [SCNGeometryElement], _ mats: inout [SCNMaterial],
                       _ indices: [UInt32], _ mat: SCNMaterial) {
        guard !indices.isEmpty else { return }
        let d = Data(bytes: indices, count: indices.count * 4)
        els.append(SCNGeometryElement(data: d, primitiveType: .triangles,
                                       primitiveCount: indices.count / 3, bytesPerIndex: 4))
        mats.append(mat)
    }

    // ═══════════════════════════════════════════════════════════
    // WALLPAPER MATERIAL
    // ═══════════════════════════════════════════════════════════

    private func makeWallpaperMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.fillMode = .fill; m.isDoubleSided = true
        m.lightingModel = .physicallyBased
        m.transparency = 0.96 // 96% — real wall bleeds through

        if let img = wpAlbedo {
            m.diffuse.contents = img
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        }
        if let img = wpNormal {
            m.normal.contents = img
            m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
            m.normal.intensity = 0.8
        }
        if let img = wpRoughness {
            m.roughness.contents = img
            m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat
        }
        if let img = wpAO {
            m.ambientOcclusion.contents = img
            m.ambientOcclusion.wrapS = .repeat; m.ambientOcclusion.wrapT = .repeat
        }
        return m
    }

    // ═══════════════════════════════════════════════════════════
    // PLACE / CLEAR WALLPAPER
    // ═══════════════════════════════════════════════════════════

    private func placeWallpaper(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let args = args, let url = args["albedoUrl"] as? String, !url.isEmpty else {
            emit("wallpaperPlaced", data: ["success": false, "message": "No URL"])
            result(nil); return
        }
        let nUrl = args["normalUrl"] as? String ?? ""
        let rUrl = args["roughnessUrl"] as? String ?? ""
        let aUrl = args["aoUrl"] as? String ?? ""
        let wIdx = args["wallIndex"] as? Int ?? 0

        emit("boot", data: ["status": "Loading textures..."])
        let g = DispatchGroup()
        var a: UIImage?, n: UIImage?, r: UIImage?, o: UIImage?

        g.enter(); textureCache.loadImage(from: url)  { a = $0; g.leave() }
        if !nUrl.isEmpty { g.enter(); textureCache.loadImage(from: nUrl) { n = $0; g.leave() } }
        if !rUrl.isEmpty { g.enter(); textureCache.loadImage(from: rUrl) { r = $0; g.leave() } }
        if !aUrl.isEmpty { g.enter(); textureCache.loadImage(from: aUrl) { o = $0; g.leave() } }

        g.notify(queue: .main) { [weak self] in
            guard let self = self, let albedo = a else {
                self?.emit("wallpaperPlaced", data: ["wallIndex": wIdx, "success": false, "message": "Load failed"])
                result(nil); return
            }
            self.wpAlbedo = albedo; self.wpNormal = n; self.wpRoughness = r; self.wpAO = o
            self.isWallpaperApplied = true
            self.editModeActive = false
            self.totalSelectedAreaSqm = self.computeSelectedArea()
            self.rebuildAllMeshNodes()
            self.emit("wallpaperPlaced", data: ["wallIndex": wIdx, "success": true, "area": self.totalSelectedAreaSqm])
            self.emit("boot", data: ["status": "Wallpaper applied ✅"])
            result(nil)
        }
    }

    private func clearAllWallpaper() {
        isWallpaperApplied = false
        wpAlbedo = nil; wpNormal = nil; wpRoughness = nil; wpAO = nil
        rebuildAllMeshNodes()
        emit("wallCleared", data: ["wallIndex": 0])
    }

    // ═══════════════════════════════════════════════════════════
    // EVENTS
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

// MARK: - AR Delegates

extension WallpaperARView: ARSCNViewDelegate, ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {}

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        guard !meshFrozen, currentMode == .scanning else { return }
        guard let geo = buildScanGeometry(from: ma) else { return }
        let meshNode = SCNNode(geometry: geo)
        node.addChildNode(meshNode)
        DispatchQueue.main.async { [weak self] in
            self?.meshNodes[ma.identifier] = meshNode
            let c = self?.meshNodes.count ?? 0
            if c % 3 == 0 { self?.emit("boot", data: ["status": "Scanning: \(c) mesh"]) }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        guard !meshFrozen, currentMode == .scanning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let n = self.meshNodes[ma.identifier],
                  let g = self.buildScanGeometry(from: ma) else { return }
            n.geometry = g
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        DispatchQueue.main.async { [weak self] in
            self?.meshNodes[ma.identifier]?.removeFromParentNode()
            self?.meshNodes.removeValue(forKey: ma.identifier)
            self?.selectedFaces.removeValue(forKey: ma.identifier)
            self?.faceCentroids.removeValue(forKey: ma.identifier)
            self?.faceCounts.removeValue(forKey: ma.identifier)
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
