// WallpaperARView.swift — v11 (RoomPlan-based)
//
// Architecture: Apple's RoomPlan framework detects walls as parametric rectangles
// (clean corners, ruler-straight edges, ML-trained). We render wallpaper as flat
// SCNPlanes from RoomPlan's CapturedRoom data. Brush and lasso edit a 2D bitmap
// mask per wall — pixel-perfect edges by CGContext drawing.
//
// Requires:
//   - iOS 16.0 or later
//   - LiDAR-equipped device
//   - `import RoomPlan` (add RoomPlan.framework in Xcode → Target → Frameworks)
//
// Replace: ios/Runner/WallpaperARView.swift
//
// Dart-side API unchanged: setARMode, startScan, stopScan, enterCutMode/exitCutMode,
// setBrushMode, setBrushSize, setWallpaperOpacity, lassoStart/End/AddPoint/Clear/Apply,
// placeWallpaper, undoCut, clearAllCuts.

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

    // ════════════════════════════════════════════════════════════
    // ROOMPLAN STATE
    // ════════════════════════════════════════════════════════════

    private var roomCaptureSession: RoomCaptureSession?
    private var latestCapturedRoom: CapturedRoom?
    private var roomBuilder: RoomBuilder?

    // ════════════════════════════════════════════════════════════
    // WALL STATE — built after stopScan from CapturedRoom
    // ════════════════════════════════════════════════════════════

    private struct Wall {
        let id: UUID                   // CapturedRoom.Surface.identifier
        let node: SCNNode              // SCNPlane node positioned by transform
        let plane: SCNPlane
        var maskImage: UIImage         // alpha mask (white = visible wallpaper)
        var maskSize: CGSize           // pixels
        var wallSize: CGSize           // meters (width × height)
        let transform: simd_float4x4   // world transform from CapturedRoom
    }
    private var walls: [UUID: Wall] = [:]
    private let maskPxPerMeter: CGFloat = 256

    // ════════════════════════════════════════════════════════════
    // BRUSH / LASSO / WALLPAPER STATE
    // ════════════════════════════════════════════════════════════

    private var brushMode: BrushMode = .erase
    private var brushRadiusMeters: Float = 0.08
    private var editModeActive = false
    private var lastBrushPanLocation: CGPoint?
    private var brushStrokeStarted = false
    private var brushCursorNode: SCNNode?

    private var lassoModeActive = false
    private var lassoWorldPoints: [SIMD3<Float>] = []
    private var lassoDotNodes: [SCNNode] = []
    private var lassoLineNodes: [SCNNode] = []
    private var lassoClosed = false
    private var lastLassoBroadcast: TimeInterval = 0

    private var undoStack: [(UUID, UIImage)] = []
    private let maxUndo = 30

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
    // ROUTER (Dart-side API unchanged)
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
        // Plain AR session until user taps Start Scan
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"]); return
        }
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = []
        sceneView.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        currentMode = .idle
        emit("boot", data: ["status": "AR ready (v11 RoomPlan)"])
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
    // SCAN — RoomCaptureSession with custom ARSCNView
    // ════════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan v11 RoomPlan <<<"])

        // RoomPlan availability check
        guard RoomCaptureSession.isSupported else {
            emit("error", data: ["message": "RoomPlan not supported (need LiDAR + iOS 16+)"])
            result(FlutterError(code: "NOROOMPLAN", message: "Not supported", details: nil))
            return
        }

        // Clear ALL prior state
        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()
        undoStack.removeAll()
        latestCapturedRoom = nil
        isWallpaperApplied = false
        editModeActive = false
        removeCursor()
        endLassoMode()
        currentMode = .scanning

        // Build RoomCaptureSession bound to our ARSCNView's ARSession
        let session = RoomCaptureSession()
        session.delegate = self
        roomCaptureSession = session
        roomBuilder = RoomBuilder(options: [.beautifyObjects])

        // CRITICAL: assign RoomPlan's ARSession to our ARSCNView so we still
        // own the visualization while RoomPlan does wall detection
        sceneView.session = session.arSession
        sceneView.session.delegate = self

        // Run scan
        let config = RoomCaptureSession.Configuration()
        session.run(configuration: config)
        emit("boot", data: ["status": "Scanning — move slowly across walls"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        guard let session = roomCaptureSession else {
            emit("error", data: ["message": "No scan in progress"])
            result(nil); return
        }
        // KEY: pauseARSession: false so AR tracking continues. Wallpaper stays anchored.
        session.stop(pauseARSession: false)
        currentMode = .preview
        emit("boot", data: ["status": "Processing room..."])
        // Walls get built in captureSession(_:didEndWith:error:) delegate below
        result(nil)
    }

    /// Process final CapturedRoom — build flat SCNPlanes for each wall
    private func processFinalRoom(_ room: CapturedRoom) {
        // Clear any walls left from a previous scan (shouldn't happen, but defensive)
        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()

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

    /// Build a flat wallpaper plane from a CapturedRoom.Surface (wall).
    /// Door/window/opening rectangles that lie on this wall get pre-cut from the mask.
    private func buildWall(
        from surface: CapturedRoom.Surface,
        doors: [CapturedRoom.Surface],
        windows: [CapturedRoom.Surface],
        openings: [CapturedRoom.Surface]
    ) -> Bool {
        let wMeters = CGFloat(surface.dimensions.x)
        let hMeters = CGFloat(surface.dimensions.y)
        guard wMeters > 0.5 && hMeters > 0.5 else { return false }

        // SCNPlane sized to wall
        let plane = SCNPlane(width: wMeters, height: hMeters)
        plane.cornerRadius = 0

        // Build initial mask: opaque + cut holes for doors/windows/openings on this wall
        let maskW = max(64, Int(wMeters * maskPxPerMeter))
        let maskH = max(64, Int(hMeters * maskPxPerMeter))
        let maskSize = CGSize(width: maskW, height: maskH)
        let mask = buildInitialMask(
            wallTransform: surface.transform,
            wallSize: CGSize(width: wMeters, height: hMeters),
            maskSize: maskSize,
            doors: doors,
            windows: windows,
            openings: openings
        )

        // Material
        let mat = buildWallMaterial(mask: mask, wallWidth: wMeters, wallHeight: hMeters)
        plane.materials = [mat]

        // Node positioned by surface.transform
        let node = SCNNode(geometry: plane)
        // CapturedRoom.Surface convention: transform.column[0]=right (X axis along width),
        // column[1]=up (Y axis along height), column[2]=normal, column[3]=position.
        // SCNPlane default orientation: width along X, height along Y, normal +Z.
        // This matches the surface convention exactly → apply transform directly.
        node.simdTransform = surface.transform

        sceneView.scene.rootNode.addChildNode(node)

        walls[surface.identifier] = Wall(
            id: surface.identifier,
            node: node,
            plane: plane,
            maskImage: mask,
            maskSize: maskSize,
            wallSize: CGSize(width: wMeters, height: hMeters),
            transform: surface.transform
        )
        return true
    }

    /// Initial mask: white (opaque) everywhere, with door/window rectangles cut out.
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
            // Opaque background
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: maskSize))

            // Cut holes for each door/window/opening that lies on this wall
            let cutouts = doors + windows + openings
            for cut in cutouts {
                let cutCenter = SIMD3<Float>(cut.transform.columns.3.x,
                                              cut.transform.columns.3.y,
                                              cut.transform.columns.3.z)
                // Transform cut center into wall's local space
                let localH = invWall * SIMD4<Float>(cutCenter.x, cutCenter.y, cutCenter.z, 1.0)
                let localCenter = SIMD3<Float>(localH.x, localH.y, localH.z)
                // Skip cuts not roughly on this wall (more than 30cm off the plane)
                if abs(localCenter.z) > 0.30 { continue }

                let cutW = CGFloat(cut.dimensions.x)
                let cutH = CGFloat(cut.dimensions.y)
                // Convert to mask pixels (UV: local origin at center of wall)
                let u = (CGFloat(localCenter.x) + wallSize.width / 2) / wallSize.width
                let v = (CGFloat(localCenter.y) + wallSize.height / 2) / wallSize.height
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
        for (_, w) in walls {
            total += Float(w.wallSize.width * w.wallSize.height)
        }
        return total
    }

    // ════════════════════════════════════════════════════════════
    // WALLPAPER MATERIAL
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

        // Mask = transparency channel (clamp, not tile)
        m.transparent.contents = mask
        m.transparent.wrapS = .clamp; m.transparent.wrapT = .clamp

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
    // MASK BITMAP DRAWING
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
        // Rebuild initial masks from CapturedRoom (re-cut doors/windows)
        guard let room = latestCapturedRoom else { return }
        for (id, w) in walls {
            let fresh = buildInitialMask(
                wallTransform: w.transform,
                wallSize: w.wallSize,
                maskSize: w.maskSize,
                doors: room.doors, windows: room.windows, openings: room.openings)
            var updated = w
            updated.maskImage = fresh
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
    // BRUSH
    // ════════════════════════════════════════════════════════════

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive, !lassoModeActive else { return }
        let pt = gesture.location(in: sceneView)

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
        let opts: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: false
        ]
        let hits = sceneView.hitTest(screenPoint, options: opts)
        for hit in hits {
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
        let px = uv.x * maskW
        let py = (1 - uv.y) * maskH

        let pxPerMeterW = maskW / w.wallSize.width
        let radiusPx = CGFloat(brushRadiusMeters) * pxPerMeterW

        let newMask = paintCircle(
            on: w.maskImage, size: w.maskSize,
            center: CGPoint(x: px, y: py),
            radius: radiusPx,
            erase: (brushMode == .erase))

        w.maskImage = newMask
        walls[anchorID] = w
        refreshWall(anchorID)

        moveCursor(to: hit.worldCoordinates)
    }

    // ════════════════════════════════════════════════════════════
    // LASSO
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

        // Strategy 1: SCNHitTest against wallpaper planes
        var world: SIMD3<Float>?
        let opts: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: false
        ]
        let hits = sceneView.hitTest(screenPoint, options: opts)
        for hit in hits {
            var cur: SCNNode? = hit.node
            while let n = cur {
                if walls.values.contains(where: { $0.node === n }) {
                    world = SIMD3<Float>(Float(hit.worldCoordinates.x),
                                         Float(hit.worldCoordinates.y),
                                         Float(hit.worldCoordinates.z))
                    break
                }
                cur = n.parent
            }
            if world != nil { break }
        }
        // Strategy 2: ARKit vertical plane raycast (fallback)
        if world == nil {
            if let q = sceneView.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .vertical),
               let r = sceneView.session.raycast(q).first {
                world = SIMD3<Float>(r.worldTransform.columns.3.x, r.worldTransform.columns.3.y, r.worldTransform.columns.3.z)
            }
        }
        guard let pickedWorld = world else {
            emit("boot", data: ["status": "Tap on wall"]); return
        }

        // Close-loop check
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
            // Project each lasso world point into this wall's local 2D, build a polygon in mask pixels
            var uvPoly: [CGPoint] = []
            for wp in lassoWorldPoints {
                let localH = invWall * SIMD4<Float>(wp.x, wp.y, wp.z, 1.0)
                // If too far off the wall plane (>30cm), skip — point belongs to another wall
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

// MARK: - RoomCaptureSessionDelegate

extension WallpaperARView: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        // Live updates during scan — keep track of latest detected room
        DispatchQueue.main.async { [weak self] in
            self?.latestCapturedRoom = room
            let walls = room.walls.count
            self?.emit("boot", data: ["status": "Scanning: \(walls) walls"])
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let e = error {
            emit("error", data: ["message": "Scan failed: \(e.localizedDescription)"])
            return
        }
        // Process final room data with RoomBuilder for highest quality
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

// MARK: - ARSessionDelegate / ARSCNViewDelegate

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
