// WallpaperARView.swift — v6 DEFINITIVE
// Frozen screen positions + UIImage snapshot overlay (perfect lasso alignment)
// SDF-based smooth alpha + fwidth shader anti-aliasing (ruler-straight smooth edges)
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

    // Mesh
    private var meshNodes: [UUID: SCNNode] = [:]
    private var meshFrozen = false

    // Per-vertex alpha
    private var vertexAlpha: [UUID: [Float]] = [:]
    private var vertexWorldPos: [UUID: [SIMD3<Float>]] = [:]
    private var wallVertices: [UUID: Set<Int>] = [:]
    private var vertexCounts: [UUID: Int] = [:]

    // Undo (batched)
    private var undoStack: [[UUID: [Float]]] = []
    private let maxUndo = 20

    // Brush
    private var brushMode: BrushMode = .erase
    private var brushRadius: Float = 0.08
    private var editModeActive = false
    private var lastBrushWorld: SIMD3<Float>?
    private let brushMoveThreshold: Float = 0.003

    // Cursor
    private var brushCursorNode: SCNNode?

    // ═══════════════════════════════════════════════════════════
    // FROZEN STATE FOR LASSO
    // ═══════════════════════════════════════════════════════════
    /// Screen position of every vertex at the moment lasso was activated.
    /// nil = vertex wasn't visible at that moment.
    private var frozenVertexScreenPositions: [UUID: [CGPoint?]] = [:]
    /// Snapshot UIImageView shown on top of ARSCNView while lasso is active
    /// (so user sees a static image they can draw over without misalignment)
    private var snapshotImageView: UIImageView?

    // Wallpaper
    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var isWallpaperApplied = false
    private var totalSelectedAreaSqm: Float = 0.0
    private var wallpaperOpacity: CGFloat = 0.96

    // Other
    private var currentWallIndex: Int = 0
    private var wallNodes: [String: SCNNode] = [:]
    private var panGesture: UIPanGestureRecognizer?
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // ═══════════════════════════════════════════════════════════
    // SHADER MODIFIER (fwidth-based anti-aliasing for crisp smooth edges)
    // ═══════════════════════════════════════════════════════════
    private static let fragmentShaderModifier: String = """
    #pragma transparent
    float vAlpha = _surface.diffuse.a;
    float aaWidth = max(fwidth(vAlpha), 0.001);
    float mask = smoothstep(0.5 - aaWidth, 0.5 + aaWidth, vAlpha);
    if (mask < 0.01) {
        discard_fragment();
    }
    if (vAlpha > 0.001) {
        _output.color.a = _output.color.a * mask / vAlpha;
    }
    """

    // ═══════════════════════════════════════════════════════════
    // MATERIALS
    // ═══════════════════════════════════════════════════════════

    private lazy var matWallWire: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.65))
    private lazy var matCeilWire: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.25))
    private lazy var matFloorWire: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.12))
    private lazy var matDoorWire: SCNMaterial = makeWire(UIColor(red:1,green:0.83,blue:0.41,alpha:0.5))

    private func makeWire(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = color; m.isDoubleSided = true; m.lightingModel = .constant; return m
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
        sceneView.delegate = self; sceneView.session.delegate = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(pan); panGesture = pan

        channel.setMethodCallHandler { [weak self] (call, result) in self?.route(call, result) }
    }

    func view() -> UIView { sceneView }

    // ═══════════════════════════════════════════════════════════
    // ROUTER
    // ═══════════════════════════════════════════════════════════

    private func route(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "initAR":       initAR(result: result)
        case "disposeAR":    sceneView.session.pause(); result(nil)
        case "setARMode":
            if let m = call.arguments as? String { setARMode(m, result: result) }
            else { result(FlutterError(code: "BAD", message: "mode needed", details: nil)) }
        case "startScan":    startScan(result: result)
        case "stopScan":     stopScan(result: result)
        case "enterCutMode": enterEditMode(); result(nil)
        case "exitCutMode":  exitEditMode(); result(nil)
        case "setBrushMode":
            if let m = call.arguments as? String { brushMode = (m == "paint") ? .paint : .erase }
            result(nil)
        case "setBrushSize":
            if let s = args?["size"] as? Double { brushRadius = Float(s); updateCursorSize() }
            result(nil)
        case "setWallpaperOpacity":
            if let o = args?["opacity"] as? Double {
                wallpaperOpacity = CGFloat(o)
                forceRefreshMaterials()
                emit("boot", data: ["status": "Opacity: \(Int(o * 100))%"])
            }
            result(nil)
        case "undoCut":      undoAlpha(); result(nil)
        case "clearAllCuts": resetAlpha(); result(nil)

        case "applyLasso":
            if let pts = args?["points"] as? [[Double]], let mode = args?["mode"] as? String {
                applyLassoWithSDF(screenPoints: pts, mode: mode)
            }
            result(nil)

        // pauseSession → enter lasso mode (freeze screen, capture positions, show snapshot)
        case "pauseSession":
            enterLassoMode()
            result(nil)
        // resumeSession → exit lasso mode (release snapshot, clear positions)
        case "resumeSession":
            exitLassoMode()
            result(nil)

        case "placeWallpaper", "switchWallpaper": placeWallpaper(args, result: result)
        case "selectWall":
            currentWallIndex = args?["wallIndex"] as? Int ?? 0
            emit("wallSelected", data: ["wallIndex": currentWallIndex]); result(nil)
        case "clearWall": clearWallpaper(); result(nil)
        case "lockWall":
            if let i = args?["wallIndex"] as? Int, let l = args?["locked"] as? Bool {
                emit("wallLockChanged", data: ["wallIndex": i, "locked": l])
            }; result(nil)
        case "getWallMeasurements":
            result(["width": 0.0, "height": 0.0, "sqm": Double(totalSelectedAreaSqm)])
        case "toggleSurfaceExclusion", "toggleObjectExclusion", "setBrushColor": result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // ═══════════════════════════════════════════════════════════
    // LASSO FREEZE/RELEASE
    // ═══════════════════════════════════════════════════════════

    private func enterLassoMode() {
        // CRITICAL: projectPoint and snapshot must both run on main thread,
        // and projectPoint must run AT THE SAME FRAME as the snapshot
        // so the captured positions match the captured image exactly.
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }

            // Step 1: Capture screen position of every vertex
            self.frozenVertexScreenPositions.removeAll()
            for (uuid, worldPositions) in self.vertexWorldPos {
                var screenPts: [CGPoint?] = []
                screenPts.reserveCapacity(worldPositions.count)
                for wPos in worldPositions {
                    let scnPos = SCNVector3(wPos.x, wPos.y, wPos.z)
                    let sp = self.sceneView.projectPoint(scnPos)
                    if sp.z > 0 && sp.z < 1 {
                        screenPts.append(CGPoint(x: CGFloat(sp.x), y: CGFloat(sp.y)))
                    } else {
                        screenPts.append(nil)
                    }
                }
                self.frozenVertexScreenPositions[uuid] = screenPts
            }

            // Step 2: Same frame — capture UIImage snapshot, display as overlay
            let snapshot = self.sceneView.snapshot()
            let imageView = UIImageView(frame: self.sceneView.bounds)
            imageView.image = snapshot
            imageView.contentMode = .scaleAspectFill
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.isUserInteractionEnabled = false
            self.sceneView.addSubview(imageView)
            self.snapshotImageView = imageView

            self.emit("boot", data: ["status": "Lasso angle frozen ✓"])
        }

        if Thread.isMainThread { work() }
        else { DispatchQueue.main.sync(execute: work) }
    }

    private func exitLassoMode() {
        frozenVertexScreenPositions.removeAll()
        let work: () -> Void = { [weak self] in
            self?.snapshotImageView?.removeFromSuperview()
            self?.snapshotImageView = nil
        }
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.sync(execute: work) }
        emit("boot", data: ["status": "Lasso released"])
    }

    // ═══════════════════════════════════════════════════════════
    // OPACITY: FORCE-FRESH MATERIALS
    // ═══════════════════════════════════════════════════════════

    private func forceRefreshMaterials() {
        guard let frame = sceneView.session.currentFrame else { return }
        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor,
                  let node = meshNodes[ma.identifier] else { continue }
            node.geometry = nil
            if let freshGeo = buildGeo(from: ma) {
                node.geometry = freshGeo
            }
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
                    if ok { self?.runIdle(result: result) }
                    else { self?.emit("error", data: ["message": "Camera denied"])
                        result(FlutterError(code: "CAM", message: "denied", details: nil)) }
                }
            }; return
        }
        guard st == .authorized else {
            emit("error", data: ["message": "Camera denied"])
            result(FlutterError(code: "CAM", message: "denied", details: nil)); return
        }
        runIdle(result: result)
    }

    private func runIdle(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"])
            result(FlutterError(code: "NOAR", message: "no ARKit", details: nil)); return
        }
        let c = ARWorldTrackingConfiguration(); c.planeDetection = [.vertical]
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        currentMode = .idle; emit("boot", data: ["status": "AR session running"]); result(nil)
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        if let m = ARViewMode(rawValue: mode) { currentMode = m }
        emit("arModeChanged", data: ["mode": mode]); result(nil)
    }

    // ═══════════════════════════════════════════════════════════
    // SCAN
    // ═══════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan v6 <<<"])
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            emit("error", data: ["message": "LiDAR not supported"])
            result(FlutterError(code: "NOLIDAR", message: "Need LiDAR", details: nil)); return
        }
        for (_, n) in meshNodes { n.removeFromParentNode() }
        meshNodes.removeAll(); vertexAlpha.removeAll(); vertexWorldPos.removeAll()
        wallVertices.removeAll(); vertexCounts.removeAll()
        wallNodes.removeAll(); undoStack.removeAll()
        totalSelectedAreaSqm = 0; isWallpaperApplied = false
        meshFrozen = false; editModeActive = false; removeCursor()
        exitLassoMode()
        currentMode = .scanning

        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.vertical, .horizontal]
        c.sceneReconstruction = .meshWithClassification; c.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { c.frameSemantics.insert(.sceneDepth) }
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        emit("boot", data: ["status": "Scanning — move slowly"]); result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        meshFrozen = true; currentMode = .preview

        let plain = ARWorldTrackingConfiguration()
        plain.planeDetection = []; plain.environmentTexturing = .automatic
        sceneView.session.run(plain, options: [])

        guard let frame = sceneView.session.currentFrame else {
            emit("scanComplete", data: ["totalWallArea": 0, "meshSegments": meshNodes.count])
            result(nil); return
        }

        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            let uuid = ma.identifier; let geo = ma.geometry
            let vCount = geo.vertices.count; let fEl = geo.faces
            let cOpt = geo.classification; let bpi = fEl.bytesPerIndex
            let ipf = fEl.indexCountPerPrimitive; let vSrc = geo.vertices
            let transform = ma.transform

            vertexCounts[uuid] = vCount

            var worldPos = [SIMD3<Float>](); worldPos.reserveCapacity(vCount)
            for i in 0..<vCount {
                let p = vSrc.buffer.contents().advanced(by: vSrc.offset + vSrc.stride * i)
                    .assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let w = transform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
                worldPos.append(SIMD3<Float>(w.x, w.y, w.z))
            }
            vertexWorldPos[uuid] = worldPos

            var wallVerts = Set<Int>()
            for f in 0..<fEl.count {
                var isWall = false
                if let c = cOpt {
                    let cv = c.buffer.contents().advanced(by: c.offset + c.stride * f)
                        .assumingMemoryBound(to: UInt8.self).pointee
                    isWall = (ARMeshClassification(rawValue: Int(cv)) == .wall)
                }
                if isWall {
                    for j in 0..<ipf {
                        let off = (f * ipf + j) * bpi
                        let p = fEl.buffer.contents().advanced(by: off)
                        let idx: Int
                        if bpi == 4 { idx = Int(p.assumingMemoryBound(to: UInt32.self).pointee) }
                        else { idx = Int(p.assumingMemoryBound(to: UInt16.self).pointee) }
                        wallVerts.insert(idx)
                    }
                }
            }
            wallVertices[uuid] = wallVerts

            var alpha = [Float](repeating: 0.0, count: vCount)
            for vi in wallVerts { alpha[vi] = 1.0 }
            vertexAlpha[uuid] = alpha
        }

        totalSelectedAreaSqm = computeArea()
        rebuildAll()
        emit("scanComplete", data: ["totalWallArea": totalSelectedAreaSqm, "meshSegments": meshNodes.count])
        emit("boot", data: ["status": "Done: \(String(format: "%.1f", totalSelectedAreaSqm)) m²"])
        result(nil)
    }

    // ═══════════════════════════════════════════════════════════
    // AREA
    // ═══════════════════════════════════════════════════════════

    private func computeArea() -> Float {
        guard let frame = sceneView.session.currentFrame else { return 0 }
        var total: Float = 0
        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            let uuid = ma.identifier
            guard let alpha = vertexAlpha[uuid], let wPos = vertexWorldPos[uuid] else { continue }
            let fEl = ma.geometry.faces; let bpi = fEl.bytesPerIndex; let ipf = fEl.indexCountPerPrimitive

            for f in 0..<fEl.count {
                var indices = [Int](); var avgA: Float = 0
                for j in 0..<ipf {
                    let p = fEl.buffer.contents().advanced(by: (f * ipf + j) * bpi)
                    let idx: Int
                    if bpi == 4 { idx = Int(p.assumingMemoryBound(to: UInt32.self).pointee) }
                    else { idx = Int(p.assumingMemoryBound(to: UInt16.self).pointee) }
                    indices.append(idx); if idx < alpha.count { avgA += alpha[idx] }
                }
                avgA /= Float(ipf)
                guard avgA > 0.5, indices.count == 3 else { continue }
                let p0 = wPos[indices[0]], p1 = wPos[indices[1]], p2 = wPos[indices[2]]
                total += simd_length(simd_cross(p1 - p0, p2 - p0)) * 0.5
            }
        }
        return total
    }

    // ═══════════════════════════════════════════════════════════
    // EDIT MODE
    // ═══════════════════════════════════════════════════════════

    private func enterEditMode() {
        editModeActive = true; isWallpaperApplied = false
        createCursor(); rebuildAll()
        emit("boot", data: ["status": "Edit mode"])
    }

    private func exitEditMode() {
        editModeActive = false; removeCursor()
        exitLassoMode()
        totalSelectedAreaSqm = computeArea(); rebuildAll()
        emit("selectionChanged", data: ["area": totalSelectedAreaSqm])
    }

    private func saveUndoSnapshot() {
        var snapshot = [UUID: [Float]]()
        for (uuid, alpha) in vertexAlpha { snapshot[uuid] = alpha }
        undoStack.append(snapshot)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
    }

    private func undoAlpha() {
        guard let snapshot = undoStack.popLast() else {
            emit("boot", data: ["status": "Nothing to undo"]); return
        }
        for (uuid, alpha) in snapshot { vertexAlpha[uuid] = alpha }
        totalSelectedAreaSqm = computeArea(); rebuildAll()
        emit("selectionChanged", data: ["area": totalSelectedAreaSqm])
        emit("boot", data: ["status": "Undo ✅"])
    }

    private func resetAlpha() {
        for (uuid, walls) in wallVertices {
            guard let count = vertexCounts[uuid] else { continue }
            var alpha = [Float](repeating: 0.0, count: count)
            for vi in walls { alpha[vi] = 1.0 }
            vertexAlpha[uuid] = alpha
        }
        undoStack.removeAll(); totalSelectedAreaSqm = computeArea()
        rebuildAll(); emit("selectionChanged", data: ["area": totalSelectedAreaSqm])
    }

    // ═══════════════════════════════════════════════════════════
    // CURSOR
    // ═══════════════════════════════════════════════════════════

    private func createCursor() {
        removeCursor()
        let diameter = CGFloat(brushRadius * 2)
        let ring = SCNTube(innerRadius: diameter * 0.45, outerRadius: diameter * 0.5, height: 0.001)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white.withAlphaComponent(0.9)
        mat.lightingModel = .constant; mat.isDoubleSided = true
        ring.materials = [mat, mat, mat]
        let node = SCNNode(geometry: ring); node.isHidden = true
        let billboard = SCNBillboardConstraint(); billboard.freeAxes = .all
        node.constraints = [billboard]
        sceneView.scene.rootNode.addChildNode(node); brushCursorNode = node
    }

    private func removeCursor() { brushCursorNode?.removeFromParentNode(); brushCursorNode = nil }

    private func updateCursorSize() {
        guard let node = brushCursorNode, let tube = node.geometry as? SCNTube else { return }
        let d = CGFloat(brushRadius * 2)
        tube.innerRadius = d * 0.45; tube.outerRadius = d * 0.5
    }

    private func moveCursor(to pos: SCNVector3) {
        guard let n = brushCursorNode else { return }
        n.isHidden = false; n.position = pos
    }

    // ═══════════════════════════════════════════════════════════
    // BRUSH
    // ═══════════════════════════════════════════════════════════

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive else { return }
        // Disable brush while in lasso mode (snapshot covers the view)
        guard snapshotImageView == nil else { return }
        let pt = gesture.location(in: sceneView)

        switch gesture.state {
        case .began:
            lastBrushWorld = nil
            saveUndoSnapshot()
            if let hit = firstMeshHit(pt) {
                moveCursor(to: hit.worldCoordinates)
                applyGaussianBrush(at: hit.worldCoordinates)
            }
        case .changed:
            if let hit = firstMeshHit(pt) {
                let wp = SIMD3<Float>(Float(hit.worldCoordinates.x),
                                      Float(hit.worldCoordinates.y),
                                      Float(hit.worldCoordinates.z))
                if let last = lastBrushWorld, simd_distance(last, wp) < brushMoveThreshold { return }
                lastBrushWorld = wp
                moveCursor(to: hit.worldCoordinates)
                applyGaussianBrush(at: hit.worldCoordinates)
            }
        case .ended, .cancelled:
            lastBrushWorld = nil
            brushCursorNode?.isHidden = true
            totalSelectedAreaSqm = computeArea()
            emit("selectionChanged", data: ["area": totalSelectedAreaSqm])
        default: break
        }
    }

    private func firstMeshHit(_ pt: CGPoint) -> SCNHitTestResult? {
        let results = sceneView.hitTest(pt, options: [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue
        ])
        for r in results {
            var cur: SCNNode? = r.node
            while let n = cur {
                if meshNodes.values.contains(where: { $0 === n }) { return r }
                cur = n.parent
            }
        }
        return nil
    }

    private func applyGaussianBrush(at worldCoords: SCNVector3) {
        let center = SIMD3<Float>(Float(worldCoords.x), Float(worldCoords.y), Float(worldCoords.z))
        let sigma = brushRadius * 0.5
        let twoSigmaSq = 2.0 * sigma * sigma
        var rebuilt = Set<UUID>()

        for (uuid, positions) in vertexWorldPos {
            guard var alpha = vertexAlpha[uuid] else { continue }
            var changed = false
            for (vi, vPos) in positions.enumerated() {
                let dist = simd_distance(center, vPos)
                guard dist <= brushRadius else { continue }
                let weight = exp(-(dist * dist) / twoSigmaSq)
                if brushMode == .erase {
                    let newA = max(0.0, alpha[vi] - weight)
                    if newA != alpha[vi] { alpha[vi] = newA; changed = true }
                } else {
                    let newA = min(1.0, alpha[vi] + weight)
                    if newA != alpha[vi] { alpha[vi] = newA; changed = true }
                }
            }
            if changed { vertexAlpha[uuid] = alpha; rebuilt.insert(uuid) }
        }
        for uuid in rebuilt { rebuildMesh(for: uuid) }
    }

    // ═══════════════════════════════════════════════════════════
    // LASSO WITH SDF (Signed Distance Field) — ruler-straight smooth edges
    // ═══════════════════════════════════════════════════════════

    private func applyLassoWithSDF(screenPoints: [[Double]], mode: String) {
        guard screenPoints.count >= 3 else { return }
        guard !frozenVertexScreenPositions.isEmpty else {
            emit("boot", data: ["status": "No frozen positions — re-tap Lasso"])
            return
        }

        let polygon = screenPoints.map { CGPoint(x: $0[0], y: $0[1]) }
        let isErase = (mode == "erase")
        // Gradient width in screen pixels: vertices within this distance from polygon edge
        // get a smooth alpha transition. Wider = softer mesh interpolation feeding the shader.
        let aaWidth: CGFloat = 20.0

        saveUndoSnapshot()

        for (uuid, frozenScreens) in frozenVertexScreenPositions {
            guard var alpha = vertexAlpha[uuid] else { continue }
            var changed = false

            for (vi, spOpt) in frozenScreens.enumerated() {
                guard let sp = spOpt else { continue }  // vertex wasn't visible at lasso start

                // Signed distance: negative = inside polygon, positive = outside
                let sdf = signedDistanceToPolygon(sp, polygon: polygon)

                // Normalize SDF to [-1, +1] over the gradient zone
                let normalized = max(-1.0, min(1.0, sdf / aaWidth))
                // alphaMask: 0 deep inside polygon, 0.5 at edge, 1 outside polygon
                let alphaMask = Float((normalized + 1.0) / 2.0)

                let newAlpha: Float
                if isErase {
                    // Erase inside polygon → take min (preserves outside parts)
                    newAlpha = min(alpha[vi], alphaMask)
                } else {
                    // Paint inside polygon → take max with inverted mask
                    newAlpha = max(alpha[vi], 1.0 - alphaMask)
                }
                if abs(newAlpha - alpha[vi]) > 0.001 {
                    alpha[vi] = newAlpha
                    changed = true
                }
            }
            if changed { vertexAlpha[uuid] = alpha }
        }

        // Auto-release lasso state so user sees the result
        exitLassoMode()

        rebuildAll()
        totalSelectedAreaSqm = computeArea()
        emit("selectionChanged", data: ["area": totalSelectedAreaSqm])
        emit("boot", data: ["status": "Lasso applied ✅"])
    }

    /// Signed distance from point to polygon edge.
    /// Negative if inside, positive if outside. Magnitude = distance to nearest edge.
    private func signedDistanceToPolygon(_ point: CGPoint, polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        var minDist = CGFloat.greatestFiniteMagnitude
        let n = polygon.count
        for i in 0..<n {
            let a = polygon[i]
            let b = polygon[(i + 1) % n]
            let d = distanceFromPointToSegment(point: point, a: a, b: b)
            if d < minDist { minDist = d }
        }
        let inside = pointInPolygon(point, polygon: polygon)
        return inside ? -minDist : minDist
    }

    private func distanceFromPointToSegment(point P: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let abx = b.x - a.x; let aby = b.y - a.y
        let apx = P.x - a.x; let apy = P.y - a.y
        let abSq = abx * abx + aby * aby
        if abSq < 1e-6 { return hypot(apx, apy) }
        var t = (apx * abx + apy * aby) / abSq
        t = max(0, min(1, t))
        let cx = a.x + t * abx
        let cy = a.y + t * aby
        return hypot(P.x - cx, P.y - cy)
    }

    private func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        var inside = false; let n = polygon.count; var j = n - 1
        for i in 0..<n {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > point.y) != (pj.y > point.y) {
                if point.x < pi.x + (point.y - pi.y) / (pj.y - pi.y) * (pj.x - pi.x) { inside = !inside }
            }; j = i
        }
        return inside
    }

    // ═══════════════════════════════════════════════════════════
    // GEOMETRY
    // ═══════════════════════════════════════════════════════════

    private func rebuildAll() {
        guard let frame = sceneView.session.currentFrame else { return }
        for anchor in frame.anchors {
            guard let ma = anchor as? ARMeshAnchor else { continue }
            rebuildMesh(for: ma.identifier)
        }
    }

    private func rebuildMesh(for uuid: UUID) {
        guard let node = meshNodes[uuid],
              let frame = sceneView.session.currentFrame,
              let anchor = frame.anchors.first(where: { $0.identifier == uuid }) as? ARMeshAnchor
        else { return }
        if let geo = buildGeo(from: anchor) { node.geometry = geo }
    }

    private func buildGeo(from anchor: ARMeshAnchor) -> SCNGeometry? {
        if currentMode == .scanning { return buildScanGeo(from: anchor) }
        return buildAlphaGeo(from: anchor)
    }

    private func buildScanGeo(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }
        let verts = extractVerts(geo); let cOpt = geo.classification
        let fEl = geo.faces; let bpi = fEl.bytesPerIndex; let ipf = fEl.indexCountPerPrimitive

        var wI: [UInt32] = [], cI: [UInt32] = [], fI: [UInt32] = [], dI: [UInt32] = []
        for f in 0..<fEl.count {
            var cls: ARMeshClassification = .none
            if let c = cOpt {
                let cv = c.buffer.contents().advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                cls = ARMeshClassification(rawValue: Int(cv)) ?? .none
            }
            let tri = readFace(fEl, f: f, bpi: bpi, ipf: ipf)
            switch cls {
            case .wall: wI.append(contentsOf: tri)
            case .ceiling: cI.append(contentsOf: tri)
            case .floor: fI.append(contentsOf: tri)
            case .door, .window: dI.append(contentsOf: tri)
            default: break
            }
        }
        let src = SCNGeometrySource(vertices: verts)
        var els: [SCNGeometryElement] = [], mats: [SCNMaterial] = []
        addEl(&els, &mats, wI, matWallWire); addEl(&els, &mats, cI, matCeilWire)
        addEl(&els, &mats, fI, matFloorWire); addEl(&els, &mats, dI, matDoorWire)
        guard !els.isEmpty else { return nil }
        let g = SCNGeometry(sources: [src], elements: els); g.materials = mats; return g
    }

    /// Alpha geometry — smooth gradient (no hard threshold) + fragment shader anti-aliasing
    private func buildAlphaGeo(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry; let vCount = geo.vertices.count; let fCount = geo.faces.count
        guard vCount > 0, fCount > 0 else { return nil }
        let uuid = anchor.identifier
        guard let alpha = vertexAlpha[uuid] else { return nil }

        let verts = extractVerts(geo)
        let uvs = genUVs(geo, transform: anchor.transform)

        // Use RAW alpha values — no hard threshold
        // The fragment shader (fwidth + smoothstep) will handle anti-aliasing
        var colors = [SIMD4<Float>](repeating: SIMD4<Float>(1,1,1,0), count: vCount)
        for i in 0..<vCount {
            let a = i < alpha.count ? alpha[i] : 0.0
            colors[i] = SIMD4<Float>(1, 1, 1, a)
        }

        // Include triangles where ANY vertex has visible alpha (lets shader anti-alias gradient zone)
        let fEl = geo.faces; let bpi = fEl.bytesPerIndex; let ipf = fEl.indexCountPerPrimitive
        var visIdx = [UInt32](); visIdx.reserveCapacity(fCount * ipf)
        for f in 0..<fCount {
            let tri = readFace(fEl, f: f, bpi: bpi, ipf: ipf)
            var anyVisible = false
            for idx in tri {
                if Int(idx) < alpha.count && alpha[Int(idx)] > 0.01 { anyVisible = true; break }
            }
            if anyVisible { visIdx.append(contentsOf: tri) }
        }
        guard !visIdx.isEmpty else { return nil }

        let vertSrc = SCNGeometrySource(vertices: verts)
        let uvSrc = SCNGeometrySource(textureCoordinates: uvs)
        let colorData = Data(bytes: &colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colorSrc = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: vCount,
            usesFloatComponents: true, componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.stride,
            dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)

        let idxData = Data(bytes: visIdx, count: visIdx.count * 4)
        let element = SCNGeometryElement(data: idxData, primitiveType: .triangles,
            primitiveCount: visIdx.count / 3, bytesPerIndex: 4)

        let mat: SCNMaterial = isWallpaperApplied ? makeWPMat() : makeEditMat()

        let g = SCNGeometry(sources: [vertSrc, uvSrc, colorSrc], elements: [element])
        g.materials = [mat]; return g
    }

    private func makeEditMat() -> SCNMaterial {
        let m = SCNMaterial(); m.isDoubleSided = true; m.blendMode = .alpha
        m.writesToDepthBuffer = true; m.readsFromDepthBuffer = true
        if let img = wpAlbedo {
            m.diffuse.contents = img; m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
            m.lightingModel = .physicallyBased
            m.transparency = wallpaperOpacity * 0.4
        } else {
            m.diffuse.contents = UIColor(red: 1, green: 0.83, blue: 0.41, alpha: 1.0)
            m.lightingModel = .constant
            m.transparency = wallpaperOpacity * 0.3
        }
        // NO shader modifier in edit mode — keep brush gradient natural and visible
        return m
    }

    private func makeWPMat() -> SCNMaterial {
        let m = SCNMaterial(); m.isDoubleSided = true; m.blendMode = .alpha
        m.lightingModel = .physicallyBased
        m.transparency = wallpaperOpacity
        m.writesToDepthBuffer = true; m.readsFromDepthBuffer = true
        if let img = wpAlbedo { m.diffuse.contents = img; m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat }
        if let img = wpNormal { m.normal.contents = img; m.normal.wrapS = .repeat; m.normal.wrapT = .repeat; m.normal.intensity = 0.8 }
        if let img = wpRoughness { m.roughness.contents = img; m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat }
        if let img = wpAO { m.ambientOcclusion.contents = img; m.ambientOcclusion.wrapS = .repeat; m.ambientOcclusion.wrapT = .repeat }
        // Anti-aliased crisp edges ONLY for applied wallpaper
        m.shaderModifiers = [.fragment: WallpaperARView.fragmentShaderModifier]
        return m
    }

    // Helpers
    private func extractVerts(_ geo: ARMeshGeometry) -> [SCNVector3] {
        let s = geo.vertices; var v = [SCNVector3](); v.reserveCapacity(s.count)
        for i in 0..<s.count {
            let p = s.buffer.contents().advanced(by: s.offset + s.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            v.append(SCNVector3(p.x, p.y, p.z))
        }
        return v
    }

    private func genUVs(_ geo: ARMeshGeometry, transform: simd_float4x4) -> [CGPoint] {
        let s = geo.vertices; var uv = [CGPoint](); uv.reserveCapacity(s.count)
        let sc: Float = 1.0 / 0.53
        for i in 0..<s.count {
            let p = s.buffer.contents().advanced(by: s.offset + s.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            let w = transform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
            uv.append(CGPoint(x: CGFloat((w.x + w.z) * sc), y: CGFloat(w.y * sc)))
        }
        return uv
    }

    private func readFace(_ fEl: ARGeometryElement, f: Int, bpi: Int, ipf: Int) -> [UInt32] {
        var t = [UInt32]()
        for j in 0..<ipf {
            let p = fEl.buffer.contents().advanced(by: (f * ipf + j) * bpi)
            if bpi == 4 { t.append(p.assumingMemoryBound(to: UInt32.self).pointee) }
            else { t.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)) }
        }
        return t
    }

    private func addEl(_ els: inout [SCNGeometryElement], _ mats: inout [SCNMaterial], _ idx: [UInt32], _ mat: SCNMaterial) {
        guard !idx.isEmpty else { return }
        els.append(SCNGeometryElement(data: Data(bytes: idx, count: idx.count * 4),
            primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4))
        mats.append(mat)
    }

    // ═══════════════════════════════════════════════════════════
    // PLACE / CLEAR
    // ═══════════════════════════════════════════════════════════

    private func placeWallpaper(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let args = args, let url = args["albedoUrl"] as? String, !url.isEmpty else {
            emit("wallpaperPlaced", data: ["success": false, "message": "No URL"]); result(nil); return
        }
        let nU = args["normalUrl"] as? String ?? ""
        let rU = args["roughnessUrl"] as? String ?? ""
        let aU = args["aoUrl"] as? String ?? ""
        let wI = args["wallIndex"] as? Int ?? 0

        emit("boot", data: ["status": "Loading textures..."])
        let g = DispatchGroup()
        var a: UIImage?, n: UIImage?, r: UIImage?, o: UIImage?
        g.enter(); textureCache.loadImage(from: url) { a = $0; g.leave() }
        if !nU.isEmpty { g.enter(); textureCache.loadImage(from: nU) { n = $0; g.leave() } }
        if !rU.isEmpty { g.enter(); textureCache.loadImage(from: rU) { r = $0; g.leave() } }
        if !aU.isEmpty { g.enter(); textureCache.loadImage(from: aU) { o = $0; g.leave() } }

        g.notify(queue: .main) { [weak self] in
            guard let self = self, let albedo = a else {
                self?.emit("wallpaperPlaced", data: ["wallIndex": wI, "success": false]); result(nil); return
            }
            self.wpAlbedo = albedo; self.wpNormal = n; self.wpRoughness = r; self.wpAO = o
            self.isWallpaperApplied = true; self.editModeActive = false; self.removeCursor()
            self.exitLassoMode()
            self.totalSelectedAreaSqm = self.computeArea()
            self.forceRefreshMaterials()
            self.emit("wallpaperPlaced", data: ["wallIndex": wI, "success": true, "area": self.totalSelectedAreaSqm])
            self.emit("boot", data: ["status": "Wallpaper applied ✅"]); result(nil)
        }
    }

    private func clearWallpaper() {
        isWallpaperApplied = false
        wpAlbedo = nil; wpNormal = nil; wpRoughness = nil; wpAO = nil
        rebuildAll(); emit("wallCleared", data: ["wallIndex": 0])
    }

    private func emit(_ type: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = ["type": type, "data": data]
        if let sink = eventSink { sink(payload) } else { pendingEvents.append(payload) }
    }
}

// MARK: - FlutterStreamHandler

extension WallpaperARView: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = { event in events(event) }
        for e in pendingEvents { events(e) }; pendingEvents.removeAll()
        emit("boot", data: ["status": "Dart listener attached"]); return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { eventSink = nil; return nil }
}

// MARK: - AR Delegates

extension WallpaperARView: ARSCNViewDelegate, ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {}

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor, !meshFrozen, currentMode == .scanning else { return }
        guard let geo = buildScanGeo(from: ma) else { return }
        let meshNode = SCNNode(geometry: geo); node.addChildNode(meshNode)
        DispatchQueue.main.async { [weak self] in
            self?.meshNodes[ma.identifier] = meshNode
            let c = self?.meshNodes.count ?? 0
            if c % 3 == 0 { self?.emit("boot", data: ["status": "Scanning: \(c) mesh"]) }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor, !meshFrozen, currentMode == .scanning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let n = self.meshNodes[ma.identifier],
                  let g = self.buildScanGeo(from: ma) else { return }
            n.geometry = g
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        DispatchQueue.main.async { [weak self] in
            let uuid = ma.identifier
            self?.meshNodes[uuid]?.removeFromParentNode()
            self?.meshNodes.removeValue(forKey: uuid)
            self?.vertexAlpha.removeValue(forKey: uuid)
            self?.vertexWorldPos.removeValue(forKey: uuid)
            self?.wallVertices.removeValue(forKey: uuid)
            self?.vertexCounts.removeValue(forKey: uuid)
        }
    }
}

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
