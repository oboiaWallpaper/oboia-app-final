// WallpaperARView.swift — v10 — Plane-anchor architecture (IKEA Place / RoomPlan style)
//
// What's different from previous versions:
//   1. SCAN: LiDAR mesh wireframe (same as before, this works)
//   2. STOP SCAN: collect ARPlaneAnchor verticals, build flat SCNPlanes per wall
//   3. EDIT/PREVIEW: wallpaper renders on FLAT planes, brush/lasso edit 2D BITMAP MASK
//   4. LiDAR mesh becomes invisible depth occluder (furniture hides wallpaper)
//
// Critical guards (lessons from v7 failure):
//   - Wallpaper planes ONLY exist after stopScan
//   - Plane nodes are children of anchor node (no manual world positioning)
//   - Minimum size filter: ignore tiny noise plane anchors
//   - If no planes detected, fall back to old LiDAR-mesh-alpha path

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

    // ════════════════════════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════════════════════════

    // SCAN STATE: LiDAR mesh wireframe (visible during scanning only)
    private var meshWireframeNodes: [UUID: SCNNode] = [:]
    private var meshFrozen = false

    // OCCLUDER STATE: LiDAR mesh as invisible depth (visible during preview/edit)
    private var occluderNodes: [UUID: SCNNode] = [:]

    // WALL STATE: flat planes that get wallpaper (built at stopScan)
    private struct Wall {
        let anchorID: UUID
        let node: SCNNode
        let plane: SCNPlane
        var maskImage: UIImage         // alpha mask (white = visible wallpaper)
        var maskSize: CGSize           // pixels
        var wallSize: CGSize           // meters (width × height)
    }
    private var walls: [UUID: Wall] = [:]
    private let maskPxPerMeter: CGFloat = 256  // 4mm per pixel — plenty sharp
    private let minWallArea: Float = 0.5       // m² — ignore tiny noise planes

    // BRUSH
    private var brushMode: BrushMode = .erase
    private var brushRadiusMeters: Float = 0.08
    private var editModeActive = false
    private var lastBrushPanLocation: CGPoint?
    private var brushStrokeStarted = false
    private var brushCursorNode: SCNNode?

    // LASSO
    private var lassoModeActive = false
    private var lassoWorldPoints: [SIMD3<Float>] = []
    private var lassoDotNodes: [SCNNode] = []
    private var lassoLineNodes: [SCNNode] = []
    private var lassoClosed = false
    private var lastLassoBroadcast: TimeInterval = 0

    // UNDO: snapshot is (anchorID, maskImage)
    private var undoStack: [(UUID, UIImage)] = []
    private let maxUndo = 30

    // WALLPAPER
    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var wallpaperOpacity: CGFloat = 0.96
    private var wallpaperRollWidth: CGFloat = 0.53
    private var isWallpaperApplied = false

    // Channel state
    private var currentWallIndex: Int = 0
    private var panGesture: UIPanGestureRecognizer?
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // ════════════════════════════════════════════════════════════
    // MATERIALS
    // ════════════════════════════════════════════════════════════

    private lazy var wireWall: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.65))
    private lazy var wireCeil: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.25))
    private lazy var wireFloor: SCNMaterial = makeWire(UIColor.white.withAlphaComponent(0.12))
    private lazy var wireDoor: SCNMaterial = makeWire(UIColor(red:1,green:0.83,blue:0.41,alpha:0.5))

    private func makeWire(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial(); m.fillMode = .lines
        m.diffuse.contents = color; m.isDoubleSided = true; m.lightingModel = .constant; return m
    }

    private lazy var occluderMat: SCNMaterial = {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []      // invisible
        m.writesToDepthBuffer = true     // but writes depth
        m.readsFromDepthBuffer = true
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    private static let cursorRingImage: UIImage = {
        let size = CGSize(width: 256, height: 256)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(12)
            cg.setShadow(offset: .zero, blur: 8, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            let inset: CGFloat = 16
            cg.strokeEllipse(in: CGRect(x: inset, y: inset, width: size.width - inset*2, height: size.height - inset*2))
        }
    }()

    // ════════════════════════════════════════════════════════════
    // INIT
    // ════════════════════════════════════════════════════════════

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

        channel.setMethodCallHandler { [weak self] (call, result) in self?.route(call, result) }
    }

    func view() -> UIView { sceneView }

    // ════════════════════════════════════════════════════════════
    // ROUTER
    // ════════════════════════════════════════════════════════════

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
            if let s = args?["size"] as? Double { brushRadiusMeters = Float(s); updateCursorSize() }
            result(nil)
        case "setWallpaperOpacity":
            if let o = args?["opacity"] as? Double {
                wallpaperOpacity = CGFloat(o)
                refreshAllWalls()
                emit("boot", data: ["status": "Opacity: \(Int(o*100))%"])
            }
            result(nil)
        case "undoCut":      undoLast(); result(nil)
        case "clearAllCuts": resetMasks(); result(nil)
        case "lassoStart":   startLassoMode(); result(nil)
        case "lassoEnd":     endLassoMode(); result(nil)
        case "lassoAddPoint":
            if let x = args?["x"] as? Double, let y = args?["y"] as? Double {
                addLassoPoint(CGPoint(x: x, y: y))
            }
            result(nil)
        case "lassoClear":   clearLassoPoints(); result(nil)
        case "lassoApply":
            if let mode = args?["mode"] as? String { applyLasso(mode: mode) }
            result(nil)
        case "pauseSession", "resumeSession": result(nil)
        case "placeWallpaper", "switchWallpaper": placeWallpaper(args, result: result)
        case "selectWall":
            currentWallIndex = args?["wallIndex"] as? Int ?? 0
            emit("wallSelected", data: ["wallIndex": currentWallIndex])
            result(nil)
        case "clearWall": clearWallpaper(); result(nil)
        case "lockWall":
            if let i = args?["wallIndex"] as? Int, let l = args?["locked"] as? Bool {
                emit("wallLockChanged", data: ["wallIndex": i, "locked": l])
            }
            result(nil)
        case "getWallMeasurements":
            result(["width": 0.0, "height": 0.0, "sqm": Double(totalArea())])
        case "toggleSurfaceExclusion", "toggleObjectExclusion", "setBrushColor": result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // ════════════════════════════════════════════════════════════
    // AR LIFECYCLE
    // ════════════════════════════════════════════════════════════

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

    // ════════════════════════════════════════════════════════════
    // SCAN — wireframe only, NO wallpaper planes yet
    // ════════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan v10 <<<"])
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            emit("error", data: ["message": "LiDAR not supported"])
            result(FlutterError(code: "NOLIDAR", message: "Need LiDAR", details: nil)); return
        }

        // Clear ALL state
        for (_, n) in meshWireframeNodes { n.removeFromParentNode() }
        for (_, n) in occluderNodes { n.removeFromParentNode() }
        for (_, w) in walls { w.node.removeFromParentNode() }
        meshWireframeNodes.removeAll()
        occluderNodes.removeAll()
        walls.removeAll()
        undoStack.removeAll()
        isWallpaperApplied = false
        meshFrozen = false
        editModeActive = false
        endLassoMode()
        removeCursor()
        currentMode = .scanning

        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.vertical, .horizontal]
        c.sceneReconstruction = .meshWithClassification
        c.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            c.frameSemantics.insert(.sceneDepth)
        }
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        emit("boot", data: ["status": "Scanning — move slowly across walls"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        meshFrozen = true
        currentMode = .preview

        // Keep tracking, but no more plane updates after this point
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = []
        c.environmentTexturing = .automatic
        sceneView.session.run(c, options: [])

        // STAGE 1: Remove all wireframe nodes (LiDAR mesh becomes invisible occluder instead)
        for (uuid, wireNode) in meshWireframeNodes {
            wireNode.removeFromParentNode()
            // Replace with invisible occluder geometry on the same parent (the ARMeshAnchor's node)
            if let frame = sceneView.session.currentFrame,
               let anchor = frame.anchors.first(where: { $0.identifier == uuid }) as? ARMeshAnchor,
               let parentNode = sceneView.node(for: anchor),
               let occGeo = buildOccluderGeometry(from: anchor) {
                let occNode = SCNNode(geometry: occGeo)
                occNode.renderingOrder = -100  // draw first so depth gates wallpaper
                parentNode.addChildNode(occNode)
                occluderNodes[uuid] = occNode
            }
        }
        meshWireframeNodes.removeAll()

        // STAGE 2: Build flat wallpaper planes from detected vertical plane anchors
        var wallsBuilt = 0
        if let frame = sceneView.session.currentFrame {
            for anchor in frame.anchors {
                guard let pa = anchor as? ARPlaneAnchor,
                      pa.alignment == .vertical else { continue }
                let w = Float(pa.planeExtent.width)
                let h = Float(pa.planeExtent.height)
                let area = w * h
                guard area >= minWallArea else { continue }  // skip noise
                if buildWall(for: pa) { wallsBuilt += 1 }
            }
        }

        let area = totalArea()
        emit("scanComplete", data: [
            "totalWallArea": area,
            "meshSegments": wallsBuilt,
            "wallsDetected": wallsBuilt
        ])
        emit("boot", data: ["status": "Done: \(wallsBuilt) walls, \(String(format: "%.1f", area)) m²"])
        result(nil)
    }

    /// Compute total opaque-mask area across all walls (m²)
    private func totalArea() -> Float {
        var total: Float = 0
        for (_, w) in walls {
            total += Float(w.wallSize.width * w.wallSize.height)
        }
        return total
    }

    // ════════════════════════════════════════════════════════════
    // WALL CREATION (only called from stopScan — never during scan)
    // ════════════════════════════════════════════════════════════

    private func buildWall(for anchor: ARPlaneAnchor) -> Bool {
        guard let anchorNode = sceneView.node(for: anchor) else { return false }
        let wMeters = CGFloat(anchor.planeExtent.width)
        let hMeters = CGFloat(anchor.planeExtent.height)

        // SCNPlane sized to wall
        let plane = SCNPlane(width: wMeters, height: hMeters)
        plane.cornerRadius = 0

        // Initial mask: fully opaque (wallpaper covers entire wall)
        let maskW = max(64, Int(wMeters * maskPxPerMeter))
        let maskH = max(64, Int(hMeters * maskPxPerMeter))
        let maskSize = CGSize(width: maskW, height: maskH)
        let mask = makeOpaqueMask(size: maskSize)

        // Wall material
        let mat = buildWallMaterial(mask: mask, wallWidth: wMeters, wallHeight: hMeters)
        plane.materials = [mat]

        // Build node, attach to anchor node (so it follows the anchor's pose automatically)
        let node = SCNNode(geometry: plane)
        // Anchor pose is the plane's pose; anchor.center is the offset from anchor origin to plane center
        node.simdPosition = anchor.center
        // ARPlaneAnchor's local space: plane lies in XZ, normal is +Y.
        // SCNPlane default lies in XY facing +Z.
        // Rotate -90° around X so SCNPlane lies in XZ facing +Y → matches anchor.
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        anchorNode.addChildNode(node)

        walls[anchor.identifier] = Wall(
            anchorID: anchor.identifier,
            node: node,
            plane: plane,
            maskImage: mask,
            maskSize: maskSize,
            wallSize: CGSize(width: wMeters, height: hMeters)
        )
        return true
    }

    // ════════════════════════════════════════════════════════════
    // MATERIAL BUILDER
    // ════════════════════════════════════════════════════════════

    private func buildWallMaterial(mask: UIImage, wallWidth: CGFloat, wallHeight: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = false
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.blendMode = .alpha

        let tilesX = max(1.0, wallWidth / wallpaperRollWidth)
        let tilesY = max(1.0, wallHeight / wallpaperRollWidth)
        let tileTransform = SCNMatrix4MakeScale(Float(tilesX), Float(tilesY), 1)

        if let albedo = wpAlbedo {
            m.lightingModel = .physicallyBased
            m.diffuse.contents = albedo
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = tileTransform
        } else {
            // Edit-mode placeholder: yellow tint shows selection
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(red: 1, green: 0.83, blue: 0.41, alpha: 1.0)
        }
        if let n = wpNormal {
            m.normal.contents = n; m.normal.wrapS = .repeat; m.normal.wrapT = .repeat
            m.normal.contentsTransform = tileTransform; m.normal.intensity = 0.8
        }
        if let r = wpRoughness {
            m.roughness.contents = r; m.roughness.wrapS = .repeat; m.roughness.wrapT = .repeat
            m.roughness.contentsTransform = tileTransform
        }
        if let a = wpAO {
            m.ambientOcclusion.contents = a; m.ambientOcclusion.wrapS = .repeat; m.ambientOcclusion.wrapT = .repeat
            m.ambientOcclusion.contentsTransform = tileTransform
        }

        // Mask = transparency channel. NOT tiled — stretches to wall extent.
        m.transparent.contents = mask
        m.transparent.wrapS = .clamp; m.transparent.wrapT = .clamp

        // Global opacity
        m.transparency = isWallpaperApplied ? wallpaperOpacity : wallpaperOpacity * 0.7

        return m
    }

    private func refreshAllWalls() {
        for (id, _) in walls { refreshWall(id) }
    }

    private func refreshWall(_ id: UUID) {
        guard let w = walls[id] else { return }
        let mat = buildWallMaterial(mask: w.maskImage, wallWidth: w.wallSize.width, wallHeight: w.wallSize.height)
        w.plane.materials = [mat]
    }

    // ════════════════════════════════════════════════════════════
    // MASK BITMAP HELPERS
    // ════════════════════════════════════════════════════════════

    private func makeOpaqueMask(size: CGSize) -> UIImage {
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Paint a circle on a mask. erase=cut hole, paint=fill in
    private func paintCircle(on mask: UIImage, size: CGSize, center: CGPoint, radius: CGFloat, erase: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0; fmt.opaque = false
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        return r.image { ctx in
            mask.draw(in: CGRect(origin: .zero, size: size))
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            if erase {
                ctx.cgContext.setBlendMode(.destinationOut)
                ctx.cgContext.setFillColor(UIColor.black.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
            } else {
                ctx.cgContext.setBlendMode(.normal)
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: rect)
            }
        }
    }

    /// Fill a polygon on a mask. erase=cut polygon out, paint=fill polygon in
    private func fillPolygon(on mask: UIImage, size: CGSize, polygon: [CGPoint], erase: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0; fmt.opaque = false
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        return r.image { ctx in
            mask.draw(in: CGRect(origin: .zero, size: size))
            guard polygon.count >= 3 else { return }
            let path = UIBezierPath()
            path.move(to: polygon[0])
            for i in 1..<polygon.count { path.addLine(to: polygon[i]) }
            path.close()
            if erase {
                ctx.cgContext.setBlendMode(.destinationOut)
                ctx.cgContext.setFillColor(UIColor.black.cgColor)
                path.fill()
            } else {
                ctx.cgContext.setBlendMode(.normal)
                UIColor.white.setFill()
                path.fill()
            }
        }
    }

    // ════════════════════════════════════════════════════════════
    // EDIT MODE
    // ════════════════════════════════════════════════════════════

    private func enterEditMode() {
        editModeActive = true
        isWallpaperApplied = false
        createCursor()
        refreshAllWalls()
        emit("boot", data: ["status": "Edit mode — brush or lasso"])
    }

    private func exitEditMode() {
        editModeActive = false
        removeCursor()
        endLassoMode()
        refreshAllWalls()
        emit("selectionChanged", data: ["area": totalArea()])
    }

    private func saveUndo(anchorID: UUID, mask: UIImage) {
        undoStack.append((anchorID, mask))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
    }

    private func undoLast() {
        guard let last = undoStack.popLast() else {
            emit("boot", data: ["status": "Nothing to undo"]); return
        }
        guard var w = walls[last.0] else { return }
        w.maskImage = last.1
        walls[last.0] = w
        refreshWall(last.0)
        emit("boot", data: ["status": "Undo ✅"])
    }

    private func resetMasks() {
        for (id, var w) in walls {
            w.maskImage = makeOpaqueMask(size: w.maskSize)
            walls[id] = w
            refreshWall(id)
        }
        undoStack.removeAll()
        emit("selectionChanged", data: ["area": totalArea()])
        emit("boot", data: ["status": "Reset"])
    }

    // ════════════════════════════════════════════════════════════
    // BRUSH CURSOR
    // ════════════════════════════════════════════════════════════

    private func createCursor() {
        removeCursor()
        let d = CGFloat(brushRadiusMeters * 2)
        let plane = SCNPlane(width: d, height: d)
        let mat = SCNMaterial()
        mat.diffuse.contents = WallpaperARView.cursorRingImage
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.blendMode = .alpha
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.isHidden = true
        node.renderingOrder = 500
        let bb = SCNBillboardConstraint(); bb.freeAxes = .all
        node.constraints = [bb]
        sceneView.scene.rootNode.addChildNode(node)
        brushCursorNode = node
    }

    private func removeCursor() { brushCursorNode?.removeFromParentNode(); brushCursorNode = nil }

    private func updateCursorSize() {
        guard let n = brushCursorNode, let p = n.geometry as? SCNPlane else { return }
        let d = CGFloat(brushRadiusMeters * 2)
        p.width = d; p.height = d
    }

    private func moveCursor(to pos: SCNVector3) {
        brushCursorNode?.isHidden = false
        brushCursorNode?.position = pos
    }

    // ════════════════════════════════════════════════════════════
    // BRUSH HANDLING (uses SCNHitTest against wallpaper plane to get UV)
    // ════════════════════════════════════════════════════════════

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive else { return }
        guard !lassoModeActive else { return }
        let pt = gesture.location(in: sceneView)

        switch gesture.state {
        case .began:
            brushStrokeStarted = false
            lastBrushPanLocation = pt
            applyBrushAt(pt)
        case .changed:
            // Interpolate to avoid gaps for fast finger moves
            if let last = lastBrushPanLocation {
                let dist = hypot(pt.x - last.x, pt.y - last.y)
                if dist > 4 {
                    let steps = max(1, Int(dist / 4))
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        let p = CGPoint(x: last.x + (pt.x - last.x) * t, y: last.y + (pt.y - last.y) * t)
                        applyBrushAt(p)
                    }
                }
            }
            lastBrushPanLocation = pt
        case .ended, .cancelled:
            lastBrushPanLocation = nil
            brushCursorNode?.isHidden = true
            brushStrokeStarted = false
            emit("selectionChanged", data: ["area": totalArea()])
        default: break
        }
    }

    private func applyBrushAt(_ screenPoint: CGPoint) {
        let opts: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: false
        ]
        let hits = sceneView.hitTest(screenPoint, options: opts)
        for hit in hits {
            // Find the wall whose plane was hit
            var cur: SCNNode? = hit.node
            while let n = cur {
                if let entry = walls.first(where: { $0.value.node === n }) {
                    applyBrushHit(anchorID: entry.key, hit: hit)
                    return
                }
                cur = n.parent
            }
        }
    }

    private func applyBrushHit(anchorID: UUID, hit: SCNHitTestResult) {
        guard var w = walls[anchorID] else { return }

        if !brushStrokeStarted {
            saveUndo(anchorID: anchorID, mask: w.maskImage)
            brushStrokeStarted = true
        }

        let uv = hit.textureCoordinates(withMappingChannel: 0)
        let maskW = w.maskSize.width
        let maskH = w.maskSize.height
        // SCNPlane UV: (0,0) bottom-left. UIImage origin: top-left. Flip Y.
        let px = uv.x * maskW
        let py = (1 - uv.y) * maskH

        let pxPerMeterW = maskW / w.wallSize.width
        let radiusPx = CGFloat(brushRadiusMeters) * pxPerMeterW

        let newMask = paintCircle(
            on: w.maskImage,
            size: w.maskSize,
            center: CGPoint(x: px, y: py),
            radius: radiusPx,
            erase: (brushMode == .erase))

        w.maskImage = newMask
        walls[anchorID] = w
        refreshWall(anchorID)

        moveCursor(to: hit.worldCoordinates)
    }

    // ════════════════════════════════════════════════════════════
    // LASSO (world-anchored 3D points, same UX as v9)
    // ════════════════════════════════════════════════════════════

    private func startLassoMode() {
        lassoModeActive = true; lassoClosed = false
        clearLassoPoints()
        emit("boot", data: ["status": "Lasso — tap on wall"])
        emit("lassoState", data: ["active": true, "closed": false, "count": 0])
    }

    private func endLassoMode() {
        lassoModeActive = false; lassoClosed = false
        clearLassoPoints()
        emit("lassoState", data: ["active": false, "closed": false, "count": 0])
    }

    private func clearLassoPoints() {
        lassoWorldPoints.removeAll()
        for n in lassoDotNodes { n.removeFromParentNode() }
        for n in lassoLineNodes { n.removeFromParentNode() }
        lassoDotNodes.removeAll(); lassoLineNodes.removeAll()
        lassoClosed = false
        emit("lassoState", data: ["active": lassoModeActive, "closed": false, "count": 0])
        broadcastLassoScreenPoints()
    }

    private func addLassoPoint(_ screenPoint: CGPoint) {
        guard lassoModeActive, !lassoClosed else { return }

        // Use ARKit raycast against detected planes (clean, since we have plane anchors)
        var world: SIMD3<Float>?
        if let q = sceneView.raycastQuery(from: screenPoint, allowing: .existingPlaneGeometry, alignment: .vertical),
           let r = sceneView.session.raycast(q).first {
            world = SIMD3<Float>(r.worldTransform.columns.3.x, r.worldTransform.columns.3.y, r.worldTransform.columns.3.z)
        } else if let q = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .vertical),
                  let r = sceneView.session.raycast(q).first {
            world = SIMD3<Float>(r.worldTransform.columns.3.x, r.worldTransform.columns.3.y, r.worldTransform.columns.3.z)
        }
        guard let pickedWorld = world else {
            emit("boot", data: ["status": "Tap on wall"]); return
        }

        // Close-loop check (10cm tolerance in 3D)
        if lassoWorldPoints.count >= 3 {
            if simd_distance(lassoWorldPoints[0], pickedWorld) < 0.10 {
                lassoClosed = true
                addLassoLine(from: lassoWorldPoints.last!, to: lassoWorldPoints[0], isClosing: true)
                emit("lassoState", data: ["active": true, "closed": true, "count": lassoWorldPoints.count])
                emit("boot", data: ["status": "Loop closed — tap Apply"])
                broadcastLassoScreenPoints()
                return
            }
        }

        lassoWorldPoints.append(pickedWorld)
        addLassoDot(at: pickedWorld)
        if lassoWorldPoints.count >= 2 {
            addLassoLine(from: lassoWorldPoints[lassoWorldPoints.count - 2], to: pickedWorld, isClosing: false)
        }
        emit("lassoState", data: ["active": true, "closed": false, "count": lassoWorldPoints.count])
        emit("boot", data: ["status": "Pt \(lassoWorldPoints.count)"])
        broadcastLassoScreenPoints()
    }

    private func addLassoDot(at world: SIMD3<Float>) {
        let s = SCNSphere(radius: 0.025)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemRed
        m.emission.contents = UIColor.systemRed.withAlphaComponent(0.6)
        m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
        s.materials = [m]
        let n = SCNNode(geometry: s)
        n.position = SCNVector3(world.x, world.y, world.z)
        n.renderingOrder = 1000
        sceneView.scene.rootNode.addChildNode(n)
        lassoDotNodes.append(n)
    }

    private func addLassoLine(from a: SIMD3<Float>, to b: SIMD3<Float>, isClosing: Bool) {
        let dir = b - a
        let length = simd_length(dir)
        guard length > 0.001 else { return }
        let cyl = SCNCylinder(radius: 0.006, height: CGFloat(length))
        let m = SCNMaterial()
        m.diffuse.contents = isClosing ? UIColor.systemYellow : UIColor.systemRed
        m.emission.contents = (isClosing ? UIColor.systemYellow : UIColor.systemRed).withAlphaComponent(0.5)
        m.lightingModel = .constant; m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
        cyl.materials = [m]
        let n = SCNNode(geometry: cyl)
        let mid = (a + b) * 0.5
        n.position = SCNVector3(mid.x, mid.y, mid.z)
        let up = SIMD3<Float>(0, 1, 0)
        let nd = simd_normalize(dir)
        let d = simd_dot(up, nd)
        if d > 0.9999 {
            // aligned
        } else if d < -0.9999 {
            n.eulerAngles = SCNVector3(Float.pi, 0, 0)
        } else {
            let axis = simd_normalize(simd_cross(up, nd))
            n.simdRotation = SIMD4<Float>(axis.x, axis.y, axis.z, acos(d))
        }
        n.renderingOrder = 999
        sceneView.scene.rootNode.addChildNode(n)
        lassoLineNodes.append(n)
    }

    private func broadcastLassoScreenPoints() {
        let now = CACurrentMediaTime()
        guard now - lastLassoBroadcast > 0.033 else { return }
        lastLassoBroadcast = now
        var pts: [[Double]] = []
        for wp in lassoWorldPoints {
            let sp = sceneView.projectPoint(SCNVector3(wp.x, wp.y, wp.z))
            let visible = sp.z > 0 && sp.z < 1
            pts.append([Double(sp.x), Double(sp.y), visible ? 1.0 : 0.0])
        }
        emit("lassoScreenPoints", data: ["points": pts])
    }

    /// Apply lasso: project polygon onto each wall's plane, convert to mask UV, fill polygon
    private func applyLasso(mode: String) {
        guard lassoWorldPoints.count >= 3 else {
            emit("boot", data: ["status": "Need 3+ points"]); return
        }
        guard let frame = sceneView.session.currentFrame else { return }
        let isErase = (mode == "erase")

        for (anchorID, w) in walls {
            let wallTransform = w.node.simdWorldTransform
            let planeNormal = SIMD3<Float>(wallTransform.columns.2.x, wallTransform.columns.2.y, wallTransform.columns.2.z)
            let planeOrigin = SIMD3<Float>(wallTransform.columns.3.x, wallTransform.columns.3.y, wallTransform.columns.3.z)
            let invWorld = simd_inverse(wallTransform)

            var uvPoly: [CGPoint] = []
            for wp in lassoWorldPoints {
                // Use the world point directly — it's already on a wall surface
                // Transform to wall's local space
                let localH = invWorld * SIMD4<Float>(wp.x, wp.y, wp.z, 1.0)
                // Check the point is roughly on this wall's plane (within 10cm)
                let toPoint = wp - planeOrigin
                let dist = abs(simd_dot(toPoint, planeNormal))
                guard dist < 0.15 else {
                    // Point not on this wall — project it via screen ray onto this wall's plane
                    let sp = sceneView.projectPoint(SCNVector3(wp.x, wp.y, wp.z))
                    let screenPt = CGPoint(x: CGFloat(sp.x), y: CGFloat(sp.y))
                    if let projected = projectScreenOntoPlane(
                        screenPoint: screenPt, planeOrigin: planeOrigin,
                        planeNormal: planeNormal, frame: frame) {
                        let localH2 = invWorld * SIMD4<Float>(projected.x, projected.y, projected.z, 1.0)
                        let u = (CGFloat(localH2.x) + w.wallSize.width/2) / w.wallSize.width
                        let v = (CGFloat(localH2.y) + w.wallSize.height/2) / w.wallSize.height
                        uvPoly.append(CGPoint(x: u * w.maskSize.width, y: (1 - v) * w.maskSize.height))
                    }
                    continue
                }
                let u = (CGFloat(localH.x) + w.wallSize.width/2) / w.wallSize.width
                let v = (CGFloat(localH.y) + w.wallSize.height/2) / w.wallSize.height
                uvPoly.append(CGPoint(x: u * w.maskSize.width, y: (1 - v) * w.maskSize.height))
            }
            guard uvPoly.count >= 3 else { continue }

            saveUndo(anchorID: anchorID, mask: w.maskImage)
            var updated = w
            updated.maskImage = fillPolygon(on: w.maskImage, size: w.maskSize, polygon: uvPoly, erase: isErase)
            walls[anchorID] = updated
            refreshWall(anchorID)
        }

        let wasClosed = lassoClosed
        clearLassoPoints()
        emit("selectionChanged", data: ["area": totalArea()])
        emit("boot", data: ["status": wasClosed ? "Lasso applied ✅" : "Lasso applied"])
    }

    private func projectScreenOntoPlane(
        screenPoint: CGPoint, planeOrigin: SIMD3<Float>,
        planeNormal: SIMD3<Float>, frame: ARFrame
    ) -> SIMD3<Float>? {
        let vs = sceneView.bounds.size
        let camT = frame.camera.transform
        let proj = frame.camera.projectionMatrix(for: .portrait, viewportSize: vs, zNear: 0.001, zFar: 1000)
        let ndcX = Float((screenPoint.x / vs.width) * 2 - 1)
        let ndcY = Float(-((screenPoint.y / vs.height) * 2 - 1))
        let invProj = simd_inverse(proj)
        let near4 = invProj * SIMD4<Float>(ndcX, ndcY, -1, 1)
        let far4 = invProj * SIMD4<Float>(ndcX, ndcY, 1, 1)
        let nearW4 = camT * (near4 / near4.w)
        let farW4 = camT * (far4 / far4.w)
        let nearW = SIMD3<Float>(nearW4.x, nearW4.y, nearW4.z)
        let farW = SIMD3<Float>(farW4.x, farW4.y, farW4.z)
        let rayDir = simd_normalize(farW - nearW)
        let denom = simd_dot(planeNormal, rayDir)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(planeOrigin - nearW, planeNormal) / denom
        guard t > 0 else { return nil }
        return nearW + rayDir * t
    }

    // ════════════════════════════════════════════════════════════
    // PLACE / CLEAR WALLPAPER
    // ════════════════════════════════════════════════════════════

    private func placeWallpaper(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let args = args, let url = args["albedoUrl"] as? String, !url.isEmpty else {
            emit("wallpaperPlaced", data: ["success": false]); result(nil); return
        }
        let nU = args["normalUrl"] as? String ?? ""
        let rU = args["roughnessUrl"] as? String ?? ""
        let aU = args["aoUrl"] as? String ?? ""
        let wI = args["wallIndex"] as? Int ?? 0
        if let rw = args["rollWidth"] as? Double, rw > 0.1 { wallpaperRollWidth = CGFloat(rw) }

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
            self.isWallpaperApplied = true
            self.editModeActive = false
            self.removeCursor(); self.endLassoMode()
            self.refreshAllWalls()
            self.emit("wallpaperPlaced", data: ["wallIndex": wI, "success": true, "area": self.totalArea()])
            self.emit("boot", data: ["status": "Wallpaper applied ✅"])
            result(nil)
        }
    }

    private func clearWallpaper() {
        isWallpaperApplied = false
        wpAlbedo = nil; wpNormal = nil; wpRoughness = nil; wpAO = nil
        refreshAllWalls()
        emit("wallCleared", data: ["wallIndex": 0])
    }

    // ════════════════════════════════════════════════════════════
    // OCCLUDER GEOMETRY (LiDAR mesh → invisible depth surface)
    // ════════════════════════════════════════════════════════════

    private func buildOccluderGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let g = anchor.geometry
        let vCount = g.vertices.count
        let fCount = g.faces.count
        guard vCount > 0, fCount > 0 else { return nil }

        var verts = [SCNVector3](); verts.reserveCapacity(vCount)
        let vS = g.vertices
        for i in 0..<vCount {
            let p = vS.buffer.contents().advanced(by: vS.offset + vS.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            verts.append(SCNVector3(p.x, p.y, p.z))
        }

        // Skip wall-classified faces (let plane anchors handle walls; mesh occludes other objects)
        let fEl = g.faces; let bpi = fEl.bytesPerIndex; let ipf = fEl.indexCountPerPrimitive
        let cOpt = g.classification
        var idx: [UInt32] = []
        for f in 0..<fCount {
            var isWall = false
            if let c = cOpt {
                let cv = c.buffer.contents().advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                isWall = (ARMeshClassification(rawValue: Int(cv)) == .wall)
            }
            if isWall { continue }
            for j in 0..<ipf {
                let p = fEl.buffer.contents().advanced(by: (f * ipf + j) * bpi)
                if bpi == 4 { idx.append(p.assumingMemoryBound(to: UInt32.self).pointee) }
                else { idx.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)) }
            }
        }
        guard !idx.isEmpty else { return nil }

        let vertSrc = SCNGeometrySource(vertices: verts)
        let idxData = Data(bytes: idx, count: idx.count * 4)
        let element = SCNGeometryElement(data: idxData, primitiveType: .triangles,
            primitiveCount: idx.count / 3, bytesPerIndex: 4)
        let geom = SCNGeometry(sources: [vertSrc], elements: [element])
        geom.materials = [occluderMat]
        return geom
    }

    // ════════════════════════════════════════════════════════════
    // SCAN GEOMETRY (mesh wireframe — only during .scanning)
    // ════════════════════════════════════════════════════════════

    private func buildScanWireframe(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }

        var verts = [SCNVector3]()
        let vS = geo.vertices
        for i in 0..<vS.count {
            let p = vS.buffer.contents().advanced(by: vS.offset + vS.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            verts.append(SCNVector3(p.x, p.y, p.z))
        }

        let cOpt = geo.classification
        let fEl = geo.faces; let bpi = fEl.bytesPerIndex; let ipf = fEl.indexCountPerPrimitive

        var wI: [UInt32] = [], cI: [UInt32] = [], fI: [UInt32] = [], dI: [UInt32] = []
        for f in 0..<fEl.count {
            var cls: ARMeshClassification = .none
            if let c = cOpt {
                let cv = c.buffer.contents().advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                cls = ARMeshClassification(rawValue: Int(cv)) ?? .none
            }
            var tri: [UInt32] = []
            for j in 0..<ipf {
                let p = fEl.buffer.contents().advanced(by: (f * ipf + j) * bpi)
                if bpi == 4 { tri.append(p.assumingMemoryBound(to: UInt32.self).pointee) }
                else { tri.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)) }
            }
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
        func addEl(_ i: [UInt32], _ m: SCNMaterial) {
            guard !i.isEmpty else { return }
            els.append(SCNGeometryElement(data: Data(bytes: i, count: i.count * 4),
                primitiveType: .triangles, primitiveCount: i.count / 3, bytesPerIndex: 4))
            mats.append(m)
        }
        addEl(wI, wireWall); addEl(cI, wireCeil); addEl(fI, wireFloor); addEl(dI, wireDoor)
        guard !els.isEmpty else { return nil }
        let g = SCNGeometry(sources: [src], elements: els); g.materials = mats; return g
    }

    // ════════════════════════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════════════════════════

    private func emit(_ type: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = ["type": type, "data": data]
        if let sink = eventSink { sink(payload) } else { pendingEvents.append(payload) }
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
    func onCancel(withArguments arguments: Any?) -> FlutterError? { eventSink = nil; return nil }
}

// MARK: - AR Delegates

extension WallpaperARView: ARSCNViewDelegate, ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if lassoModeActive && !lassoWorldPoints.isEmpty {
            broadcastLassoScreenPoints()
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        // ONLY during scan: render LiDAR mesh wireframe
        if let ma = anchor as? ARMeshAnchor, !meshFrozen, currentMode == .scanning {
            guard let geo = buildScanWireframe(from: ma) else { return }
            let n = SCNNode(geometry: geo)
            node.addChildNode(n)
            DispatchQueue.main.async { [weak self] in
                self?.meshWireframeNodes[ma.identifier] = n
                let c = self?.meshWireframeNodes.count ?? 0
                if c % 3 == 0 { self?.emit("boot", data: ["status": "Scanning: \(c) mesh"]) }
            }
        }
        // Plane anchors are tracked silently during scan; we don't render them yet
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        if let ma = anchor as? ARMeshAnchor, !meshFrozen, currentMode == .scanning {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let n = self.meshWireframeNodes[ma.identifier],
                      let g = self.buildScanWireframe(from: ma) else { return }
                n.geometry = g
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let ma = anchor as? ARMeshAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.meshWireframeNodes[ma.identifier]?.removeFromParentNode()
                self?.meshWireframeNodes.removeValue(forKey: ma.identifier)
                self?.occluderNodes[ma.identifier]?.removeFromParentNode()
                self?.occluderNodes.removeValue(forKey: ma.identifier)
            }
        } else if let pa = anchor as? ARPlaneAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.walls[pa.identifier]?.node.removeFromParentNode()
                self?.walls.removeValue(forKey: pa.identifier)
            }
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
