// WallpaperARView.swift — v12 (4 targeted fixes on top of v11 RoomPlan)
//
// Changes from v11:
//   FIX 1: Brush UV computed from world position (not hit.textureCoordinates)
//          to avoid contentsTransform tiling distortion → erase hits correct spot
//   FIX 2: Lasso uses ray-plane intersection against each wall's mathematical
//          plane (infinite extent) → can lasso outside the wallpaper area
//   FIX 3: Live wall wireframe during RoomPlan scan → user sees progress
//   FIX 4: Freehand pen-tool lasso (pan gesture samples continuous path)
//
// Replace: ios/Runner/WallpaperARView.swift

import ARKit
import AVFoundation
import SceneKit
import Flutter
import UIKit
import RoomPlan

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

    // RoomPlan
    private var roomCaptureSession: RoomCaptureSession?
    private var latestCapturedRoom: CapturedRoom?
    private var roomBuilder: RoomBuilder?

    // ════════════════════════════════════════════════════════════
    // FIX 3: LIVE SCAN VISUALIZATION
    // Wireframe overlays of walls as they're detected
    // ════════════════════════════════════════════════════════════
    private var scanPreviewNodes: [UUID: SCNNode] = [:]

    // Wall state
    private struct Wall {
        let id: UUID
        let node: SCNNode
        let plane: SCNPlane
        var maskImage: UIImage
        var maskSize: CGSize
        var wallSize: CGSize
        let transform: simd_float4x4
    }
    private var walls: [UUID: Wall] = [:]
    private let maskPxPerMeter: CGFloat = 256

    // Brush
    private var brushMode: BrushMode = .erase
    private var brushRadiusMeters: Float = 0.08
    private var editModeActive = false
    private var lastBrushPanLocation: CGPoint?
    private var brushStrokeStarted = false
    private var brushCursorNode: SCNNode?

    // Lasso
    private var lassoModeActive = false
    private var lassoWorldPoints: [SIMD3<Float>] = []
    private var lassoDotNodes: [SCNNode] = []
    private var lassoLineNodes: [SCNNode] = []
    private var lassoClosed = false
    private var lastLassoBroadcast: TimeInterval = 0

    // FIX 4: Freehand pen mode
    // When true, lasso pan gesture samples points along drag path
    private var lassoFreehandActive = false
    private var lassoFreehandLastSample: SIMD3<Float>?
    private let freehandMinSampleDistance: Float = 0.025  // 2.5cm in 3D space

    // Undo
    private var undoStack: [(UUID, UIImage)] = []
    private let maxUndo = 30

    // Wallpaper
    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var wallpaperOpacity: CGFloat = 0.96
    private var wallpaperRollWidth: CGFloat = 0.53
    private var isWallpaperApplied = false

    // Channel
    private var currentWallIndex: Int = 0
    private var panGesture: UIPanGestureRecognizer?
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // Cursor texture
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
        case "disposeAR":    teardown(); result(nil)
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
            // Tap-mode (still supported for backwards compat)
            if let x = args?["x"] as? Double, let y = args?["y"] as? Double {
                addLassoPoint(CGPoint(x: x, y: y))
            }
            result(nil)
        case "lassoClear":   clearLassoPoints(); result(nil)
        case "lassoApply":
            if let mode = args?["mode"] as? String { applyLasso(mode: mode) }
            result(nil)
        // FIX 4: Freehand pen mode toggle from Dart
        case "lassoSetFreehand":
            lassoFreehandActive = (call.arguments as? Bool) ?? false
            emit("boot", data: ["status": lassoFreehandActive ? "Pen mode" : "Tap mode"])
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
    // LIFECYCLE
    // ════════════════════════════════════════════════════════════

    private func initAR(result: @escaping FlutterResult) {
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        if st == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.bootIdleSession(); result(nil) }
                    else { self?.emit("error", data: ["message": "Camera denied"])
                        result(FlutterError(code: "CAM", message: "denied", details: nil)) }
                }
            }; return
        }
        guard st == .authorized else {
            emit("error", data: ["message": "Camera denied"])
            result(FlutterError(code: "CAM", message: "denied", details: nil)); return
        }
        bootIdleSession()
        result(nil)
    }

    private func bootIdleSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"]); return
        }
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = []
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        currentMode = .idle
        emit("boot", data: ["status": "AR ready (v12)"])
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        if let m = ARViewMode(rawValue: mode) { currentMode = m }
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    private func teardown() {
        roomCaptureSession?.stop(pauseARSession: true)
        roomCaptureSession = nil
        sceneView.session.pause()
    }

    // ════════════════════════════════════════════════════════════
    // SCAN
    // ════════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan v12 <<<"])
        guard RoomCaptureSession.isSupported else {
            emit("error", data: ["message": "RoomPlan not supported"])
            result(FlutterError(code: "NOROOMPLAN", message: "Not supported", details: nil))
            return
        }

        // Clear state
        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()
        clearScanPreview()
        undoStack.removeAll()
        latestCapturedRoom = nil
        isWallpaperApplied = false
        editModeActive = false
        removeCursor()
        endLassoMode()
        currentMode = .scanning

        let session = RoomCaptureSession()
        session.delegate = self
        roomCaptureSession = session
        roomBuilder = RoomBuilder(options: [.beautifyObjects])

        sceneView.session = session.arSession
        sceneView.session.delegate = self

        let config = RoomCaptureSession.Configuration()
        session.run(configuration: config)
        emit("boot", data: ["status": "Move slowly to scan walls"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        guard let session = roomCaptureSession else {
            emit("error", data: ["message": "No scan in progress"])
            result(nil); return
        }
        session.stop(pauseARSession: false)
        currentMode = .preview
        clearScanPreview()
        emit("boot", data: ["status": "Processing room..."])
        result(nil)
    }

    // ════════════════════════════════════════════════════════════
    // FIX 3: LIVE SCAN PREVIEW
    // Draw wireframe rectangle on each detected wall during scan
    // ════════════════════════════════════════════════════════════

    private func updateScanPreview(room: CapturedRoom) {
        var keepIDs = Set<UUID>()
        for surface in room.walls {
            keepIDs.insert(surface.identifier)
            updateOrCreatePreviewNode(for: surface, color: UIColor.systemYellow.withAlphaComponent(0.85))
        }
        // Also show doors/windows in different color
        for surface in room.doors + room.windows {
            keepIDs.insert(surface.identifier)
            updateOrCreatePreviewNode(for: surface, color: UIColor.systemBlue.withAlphaComponent(0.7))
        }
        // Remove preview nodes that no longer exist
        for id in scanPreviewNodes.keys where !keepIDs.contains(id) {
            scanPreviewNodes[id]?.removeFromParentNode()
            scanPreviewNodes.removeValue(forKey: id)
        }
    }

    private func updateOrCreatePreviewNode(for surface: CapturedRoom.Surface, color: UIColor) {
        let w = CGFloat(surface.dimensions.x)
        let h = CGFloat(surface.dimensions.y)
        guard w > 0.1 && h > 0.1 else { return }

        if let existing = scanPreviewNodes[surface.identifier] {
            // Update existing node's transform and size
            existing.simdTransform = surface.transform
            if let plane = existing.geometry as? SCNPlane {
                plane.width = w; plane.height = h
            }
            return
        }

        // Build wireframe rectangle = SCNPlane with lines-only material
        let plane = SCNPlane(width: w, height: h)
        let mat = SCNMaterial()
        mat.fillMode = .lines
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.simdTransform = surface.transform
        node.renderingOrder = 100
        sceneView.scene.rootNode.addChildNode(node)
        scanPreviewNodes[surface.identifier] = node
    }

    private func clearScanPreview() {
        for (_, n) in scanPreviewNodes { n.removeFromParentNode() }
        scanPreviewNodes.removeAll()
    }

    // ════════════════════════════════════════════════════════════
    // FINAL ROOM PROCESSING
    // ════════════════════════════════════════════════════════════

    private func processFinalRoom(_ room: CapturedRoom) {
        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()
        clearScanPreview()

        var wallsBuilt = 0
        for surface in room.walls {
            if buildWall(from: surface, doors: room.doors, windows: room.windows, openings: room.openings) {
                wallsBuilt += 1
            }
        }

        let area = totalArea()
        emit("scanComplete", data: [
            "totalWallArea": area,
            "meshSegments": wallsBuilt,
            "wallsDetected": wallsBuilt
        ])
        emit("boot", data: ["status": "Done: \(wallsBuilt) walls, \(String(format: "%.1f", area)) m²"])
    }

    private func buildWall(
        from surface: CapturedRoom.Surface,
        doors: [CapturedRoom.Surface],
        windows: [CapturedRoom.Surface],
        openings: [CapturedRoom.Surface]
    ) -> Bool {
        let wMeters = CGFloat(surface.dimensions.x)
        let hMeters = CGFloat(surface.dimensions.y)
        guard wMeters > 0.5 && hMeters > 0.5 else { return false }

        let plane = SCNPlane(width: wMeters, height: hMeters)
        plane.cornerRadius = 0

        let maskW = max(64, Int(wMeters * maskPxPerMeter))
        let maskH = max(64, Int(hMeters * maskPxPerMeter))
        let maskSize = CGSize(width: maskW, height: maskH)
        let mask = buildInitialMask(
            wallTransform: surface.transform,
            wallSize: CGSize(width: wMeters, height: hMeters),
            maskSize: maskSize,
            doors: doors, windows: windows, openings: openings
        )

        let mat = buildWallMaterial(mask: mask, wallWidth: wMeters, wallHeight: hMeters)
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        node.simdTransform = surface.transform
        sceneView.scene.rootNode.addChildNode(node)

        walls[surface.identifier] = Wall(
            id: surface.identifier,
            node: node, plane: plane,
            maskImage: mask, maskSize: maskSize,
            wallSize: CGSize(width: wMeters, height: hMeters),
            transform: surface.transform
        )
        return true
    }

    private func buildInitialMask(
        wallTransform: simd_float4x4,
        wallSize: CGSize,
        maskSize: CGSize,
        doors: [CapturedRoom.Surface],
        windows: [CapturedRoom.Surface],
        openings: [CapturedRoom.Surface]
    ) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0; fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: maskSize, format: fmt)
        let invWall = simd_inverse(wallTransform)

        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: maskSize))

            let cutouts = doors + windows + openings
            for cut in cutouts {
                let cutCenter = SIMD3<Float>(cut.transform.columns.3.x,
                                              cut.transform.columns.3.y,
                                              cut.transform.columns.3.z)
                let localH = invWall * SIMD4<Float>(cutCenter.x, cutCenter.y, cutCenter.z, 1.0)
                if abs(localH.z) > 0.30 { continue }
                let cutW = CGFloat(cut.dimensions.x)
                let cutH = CGFloat(cut.dimensions.y)
                let u = (CGFloat(localH.x) + wallSize.width / 2) / wallSize.width
                let v = (CGFloat(localH.y) + wallSize.height / 2) / wallSize.height
                let pxCenter = CGPoint(x: u * maskSize.width, y: (1 - v) * maskSize.height)
                let pxW = cutW / wallSize.width * maskSize.width
                let pxH = cutH / wallSize.height * maskSize.height
                let rect = CGRect(x: pxCenter.x - pxW/2, y: pxCenter.y - pxH/2, width: pxW, height: pxH)
                ctx.cgContext.setBlendMode(.destinationOut)
                ctx.cgContext.setFillColor(UIColor.black.cgColor)
                ctx.cgContext.fill(rect)
            }
        }
    }

    private func totalArea() -> Float {
        var total: Float = 0
        for (_, w) in walls { total += Float(w.wallSize.width * w.wallSize.height) }
        return total
    }

    // ════════════════════════════════════════════════════════════
    // MATERIAL
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

        m.transparent.contents = mask
        m.transparent.wrapS = .clamp; m.transparent.wrapT = .clamp
        m.transparency = isWallpaperApplied ? wallpaperOpacity : wallpaperOpacity * 0.7
        return m
    }

    private func refreshAllWalls() { for (id, _) in walls { refreshWall(id) } }
    private func refreshWall(_ id: UUID) {
        guard let w = walls[id] else { return }
        let mat = buildWallMaterial(mask: w.maskImage, wallWidth: w.wallSize.width, wallHeight: w.wallSize.height)
        w.plane.materials = [mat]
    }

    // ════════════════════════════════════════════════════════════
    // MASK DRAWING
    // ════════════════════════════════════════════════════════════

    private func paintCircle(on mask: UIImage, size: CGSize, center: CGPoint, radius: CGFloat, erase: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0; fmt.opaque = false
        let r = UIGraphicsImageRenderer(size: size, format: fmt)
        return r.image { ctx in
            mask.draw(in: CGRect(origin: .zero, size: size))
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius*2, height: radius*2)
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

    private func fillPolygon(on mask: UIImage, size: CGSize, polygon: [CGPoint], erase: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0; fmt.opaque = false
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
        emit("boot", data: ["status": "Edit mode"])
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
        guard let room = latestCapturedRoom else { return }
        for (id, w) in walls {
            let fresh = buildInitialMask(
                wallTransform: w.transform, wallSize: w.wallSize, maskSize: w.maskSize,
                doors: room.doors, windows: room.windows, openings: room.openings)
            var updated = w; updated.maskImage = fresh
            walls[id] = updated
            refreshWall(id)
        }
        undoStack.removeAll()
        emit("selectionChanged", data: ["area": totalArea()])
        emit("boot", data: ["status": "Reset"])
    }

    // ════════════════════════════════════════════════════════════
    // CURSOR
    // ════════════════════════════════════════════════════════════

    private func createCursor() {
        removeCursor()
        let d = CGFloat(brushRadiusMeters * 2)
        let plane = SCNPlane(width: d, height: d)
        let mat = SCNMaterial()
        mat.diffuse.contents = WallpaperARView.cursorRingImage
        mat.lightingModel = .constant; mat.isDoubleSided = true; mat.blendMode = .alpha
        mat.writesToDepthBuffer = false; mat.readsFromDepthBuffer = false
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.isHidden = true; node.renderingOrder = 500
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
        brushCursorNode?.isHidden = false; brushCursorNode?.position = pos
    }

    // ════════════════════════════════════════════════════════════
    // FIX 1 + 2 HELPERS: world-position → wall UV
    // ════════════════════════════════════════════════════════════

    /// For a given world point, find which wall it's closest to and the UV on that wall.
    /// Returns (wallID, uPixel, vPixel, distanceToWall).
    /// Allows points OUTSIDE the wall extent too — useful for lasso "outside wallpaper".
    private func wallHitFromWorld(_ world: SIMD3<Float>) -> (UUID, CGPoint, Float)? {
        var best: (UUID, CGPoint, Float)? = nil
        for (id, w) in walls {
            let invWall = simd_inverse(w.transform)
            let localH = invWall * SIMD4<Float>(world.x, world.y, world.z, 1.0)
            let perpDist = abs(localH.z)
            // Convert local x/y to mask UV pixel coords (allow outside [0,1])
            let u = (CGFloat(localH.x) + w.wallSize.width / 2) / w.wallSize.width
            let v = (CGFloat(localH.y) + w.wallSize.height / 2) / w.wallSize.height
            let px = CGPoint(x: u * w.maskSize.width, y: (1 - v) * w.maskSize.height)
            if best == nil || perpDist < best!.2 {
                best = (id, px, perpDist)
            }
        }
        return best
    }

    /// Ray-plane intersection against each wall's infinite plane.
    /// Returns the world hit point on whichever wall the ray strikes FIRST (closest t > 0).
    /// FIX 2: this lets lasso tap outside the visible wallpaper plane.
    private func raycastAgainstWallPlanes(screenPoint: CGPoint) -> (UUID, SIMD3<Float>)? {
        guard let frame = sceneView.session.currentFrame else { return nil }
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
        let rayOrigin = SIMD3<Float>(nearW4.x, nearW4.y, nearW4.z)
        let rayEnd = SIMD3<Float>(farW4.x, farW4.y, farW4.z)
        let rayDir = simd_normalize(rayEnd - rayOrigin)

        var bestT: Float = .greatestFiniteMagnitude
        var bestResult: (UUID, SIMD3<Float>)? = nil

        for (id, w) in walls {
            // Wall normal in world space = transform's local Z axis (3rd column)
            let n = SIMD3<Float>(w.transform.columns.2.x, w.transform.columns.2.y, w.transform.columns.2.z)
            let origin = SIMD3<Float>(w.transform.columns.3.x, w.transform.columns.3.y, w.transform.columns.3.z)
            let denom = simd_dot(n, rayDir)
            if abs(denom) < 1e-6 { continue }
            let t = simd_dot(origin - rayOrigin, n) / denom
            if t <= 0 || t >= bestT { continue }
            bestT = t
            let hit = rayOrigin + rayDir * t
            bestResult = (id, hit)
        }
        return bestResult
    }

    // ════════════════════════════════════════════════════════════
    // BRUSH (FIX 1: world-position UV, not hit.textureCoordinates)
    // ════════════════════════════════════════════════════════════

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive else { return }
        let pt = gesture.location(in: sceneView)

        if lassoModeActive {
            handleLassoPan(gesture, at: pt)
            return
        }

        // Brush
        switch gesture.state {
        case .began:
            brushStrokeStarted = false
            lastBrushPanLocation = pt
            applyBrushAt(pt)
        case .changed:
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
        // FIX 1: Use ray-plane raycast → world point → compute UV from world directly.
        // This avoids the texture coordinate tiling distortion bug.
        guard let (wallID, worldHit) = raycastAgainstWallPlanes(screenPoint: screenPoint) else { return }
        guard let (_, pxCenter, perpDist) = wallHitFromWorld(worldHit) else { return }
        // Must be on this wall (sanity)
        if perpDist > 0.10 { return }
        applyBrushAtMaskPixel(wallID: wallID, pxCenter: pxCenter, worldHit: worldHit)
    }

    private func applyBrushAtMaskPixel(wallID: UUID, pxCenter: CGPoint, worldHit: SIMD3<Float>) {
        guard var w = walls[wallID] else { return }
        // Reject taps outside the wall extent (with small margin)
        let margin: CGFloat = 0
        if pxCenter.x < -margin || pxCenter.x > w.maskSize.width + margin ||
           pxCenter.y < -margin || pxCenter.y > w.maskSize.height + margin {
            return
        }

        if !brushStrokeStarted {
            saveUndo(anchorID: wallID, mask: w.maskImage)
            brushStrokeStarted = true
        }

        let pxPerMeterW = w.maskSize.width / w.wallSize.width
        let radiusPx = CGFloat(brushRadiusMeters) * pxPerMeterW

        let newMask = paintCircle(
            on: w.maskImage, size: w.maskSize,
            center: pxCenter, radius: radiusPx,
            erase: (brushMode == .erase))

        w.maskImage = newMask
        walls[wallID] = w
        refreshWall(wallID)

        moveCursor(to: SCNVector3(worldHit.x, worldHit.y, worldHit.z))
    }

    // ════════════════════════════════════════════════════════════
    // LASSO (FIX 2: ray-plane on infinite wall, FIX 4: freehand pen)
    // ════════════════════════════════════════════════════════════

    private func startLassoMode() {
        lassoModeActive = true; lassoClosed = false
        clearLassoPoints()
        emit("boot", data: ["status": lassoFreehandActive ? "Draw to lasso (pen)" : "Tap to lasso"])
        emit("lassoState", data: ["active": true, "closed": false, "count": 0])
    }

    private func endLassoMode() {
        lassoModeActive = false; lassoClosed = false
        lassoFreehandLastSample = nil
        clearLassoPoints()
        emit("lassoState", data: ["active": false, "closed": false, "count": 0])
    }

    private func clearLassoPoints() {
        lassoWorldPoints.removeAll()
        for n in lassoDotNodes { n.removeFromParentNode() }
        for n in lassoLineNodes { n.removeFromParentNode() }
        lassoDotNodes.removeAll(); lassoLineNodes.removeAll()
        lassoClosed = false
        lassoFreehandLastSample = nil
        emit("lassoState", data: ["active": lassoModeActive, "closed": false, "count": 0])
        broadcastLassoScreenPoints()
    }

    // FIX 4: Freehand pen lasso — pan gesture in lasso mode samples continuous curve
    private func handleLassoPan(_ gesture: UIPanGestureRecognizer, at pt: CGPoint) {
        guard lassoFreehandActive else { return }  // tap mode handled separately via lassoAddPoint

        switch gesture.state {
        case .began:
            clearLassoPoints()
            lassoFreehandLastSample = nil
            sampleFreehandPoint(at: pt, isFirst: true)
        case .changed:
            sampleFreehandPoint(at: pt, isFirst: false)
        case .ended, .cancelled:
            // Auto-close the loop on stroke end if we have enough points
            if lassoWorldPoints.count >= 3 {
                lassoClosed = true
                addLassoLine(from: lassoWorldPoints.last!, to: lassoWorldPoints[0], isClosing: true)
                emit("lassoState", data: ["active": true, "closed": true, "count": lassoWorldPoints.count])
                emit("boot", data: ["status": "Loop closed — tap Apply"])
                broadcastLassoScreenPoints()
            }
            lassoFreehandLastSample = nil
        default: break
        }
    }

    private func sampleFreehandPoint(at screenPoint: CGPoint, isFirst: Bool) {
        guard let (_, world) = raycastAgainstWallPlanes(screenPoint: screenPoint) else { return }
        if let last = lassoFreehandLastSample, !isFirst {
            if simd_distance(last, world) < freehandMinSampleDistance { return }
        }
        lassoFreehandLastSample = world
        lassoWorldPoints.append(world)
        addLassoDot(at: world)
        if lassoWorldPoints.count >= 2 {
            addLassoLine(from: lassoWorldPoints[lassoWorldPoints.count - 2], to: world, isClosing: false)
        }
        emit("lassoState", data: ["active": true, "closed": false, "count": lassoWorldPoints.count])
        broadcastLassoScreenPoints()
    }

    // Tap-mode lasso (still works for backwards compatibility)
    private func addLassoPoint(_ screenPoint: CGPoint) {
        guard lassoModeActive, !lassoClosed else { return }

        // FIX 2: ray-plane raycast against wall planes — works anywhere on screen
        guard let (_, pickedWorld) = raycastAgainstWallPlanes(screenPoint: screenPoint) else {
            // Fallback: ARKit's own vertical plane raycast
            if let q = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .vertical),
               let r = sceneView.session.raycast(q).first {
                let alt = SIMD3<Float>(r.worldTransform.columns.3.x, r.worldTransform.columns.3.y, r.worldTransform.columns.3.z)
                processLassoTap(alt)
                return
            }
            emit("boot", data: ["status": "Tap toward a wall"]); return
        }
        processLassoTap(pickedWorld)
    }

    private func processLassoTap(_ pickedWorld: SIMD3<Float>) {
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
        let s = SCNSphere(radius: 0.020)
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
        let cyl = SCNCylinder(radius: 0.005, height: CGFloat(length))
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
        if d > 0.9999 { /* aligned */ }
        else if d < -0.9999 { n.eulerAngles = SCNVector3(Float.pi, 0, 0) }
        else {
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

    private func applyLasso(mode: String) {
        guard lassoWorldPoints.count >= 3 else {
            emit("boot", data: ["status": "Need 3+ points"]); return
        }
        let isErase = (mode == "erase")

        for (anchorID, w) in walls {
            let invWall = simd_inverse(w.transform)
            var uvPoly: [CGPoint] = []
            for wp in lassoWorldPoints {
                let localH = invWall * SIMD4<Float>(wp.x, wp.y, wp.z, 1.0)
                if abs(localH.z) > 0.30 { continue }
                let u = (CGFloat(localH.x) + w.wallSize.width / 2) / w.wallSize.width
                let v = (CGFloat(localH.y) + w.wallSize.height / 2) / w.wallSize.height
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

    // Events
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

// MARK: - RoomCaptureSessionDelegate

extension WallpaperARView: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        // FIX 3: Live wireframe overlays as walls are detected
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.latestCapturedRoom = room
            if self.currentMode == .scanning {
                self.updateScanPreview(room: room)
            }
            self.emit("boot", data: ["status": "Scanning: \(room.walls.count) walls detected"])
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let e = error {
            emit("error", data: ["message": "Scan failed: \(e.localizedDescription)"])
            return
        }
        Task { [weak self] in
            guard let self = self, let builder = self.roomBuilder else { return }
            do {
                let finalRoom = try await builder.capturedRoom(from: data)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.latestCapturedRoom = finalRoom
                    self.processFinalRoom(finalRoom)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.emit("error", data: ["message": "Build failed: \(error.localizedDescription)"])
                }
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension WallpaperARView: ARSessionDelegate, ARSCNViewDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if lassoModeActive && !lassoWorldPoints.isEmpty {
            broadcastLassoScreenPoints()
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
