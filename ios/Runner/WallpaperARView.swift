// WallpaperARView.swift — v13 + SINGLE-SESSION fix (root cause)
//
// ROOT CAUSE (confirmed via Apple docs/WWDC23 + developer reports): the app ran
// RoomPlan on one session, then called session.run(meshConfig) for the occluder.
// That reconfiguration SHIFTS ARKit's world origin — a documented iOS behavior —
// which slid the wall off the grid (consistent offset). Geometry was always
// correct; only the coordinate frame moved.
//
// FIX: use ONE ARSession for the whole flow. We build an ARWorldTrackingConfig
// with sceneReconstruction(.meshWithClassification) + sceneDepth, run it, and
// hand that session to RoomPlan via RoomCaptureSession(arSession:) (iOS 17+).
// The session is NEVER reconfigured, so the world origin never moves → the wall
// stays exactly where the grid was, AND the occluder mesh comes from the same
// session (re-asserted in didStartWith, per Apple's documented timing).
//
// MEASUREMENT (area-math only, does NOT touch geometry/placement/session):
// charged area now subtracts detected door/window/opening area (you don't paper
// those) and rounds UP to the next 0.1 m² so a seller is never short. The
// position fix above is fully preserved.
//
// FIX: the wallpaper is now built from the LIVE RoomPlan room (the same data the
// on-screen grid is drawn from, which fits the wall) instead of RoomBuilder's
// reprocessed output. RoomBuilder was inflating the wall height (~2.9m) and
// adding phantom sliver walls, which made the wallpaper overflow onto the
// ceiling and adjacent surfaces. Only the room data source changed; all
// placement, mask, paint, lasso, occluder, and pricing logic is untouched.
//
// KEY CHANGES FROM v12:
//   • Replaced manual ray-plane math with sceneView.unprojectPoint() — this
//     matches whatever SceneKit is rendering, so taps/drags land where the
//     user expects regardless of Flutter UiKitView orientation issues.
//   • Added a diagnostic log: timestamped events for every interaction.
//   • New method "getDiagnosticReport" returns the full log + state snapshot
//     to Dart so the user can email it.
//   • Live diagnostic events emitted to Dart so on-screen overlay can show:
//     - walls count, lassoPoints count, lastRayHit, anchors count, etc.
//   • If LiDAR mesh anchors arrive during scan, log them — confirms whether
//     occluder is even possible.

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
    // ★ The last LIVE room from didUpdate — this is what the on-screen grid is
    // drawn from. We build the wallpaper from THIS (the geometry that fits the
    // wall) instead of RoomBuilder's reprocessed output (which inflates the wall
    // and invents phantom slivers).
    private var lastLiveRoom: CapturedRoom?
    private var roomBuilder: RoomBuilder?

    // Scan preview
    private var scanPreviewNodes: [UUID: SCNNode] = [:]

    // Occluder
    private var occluderNodes: [UUID: SCNNode] = [:]
    private var occluderEnabled = true

    // Walls
    private struct Wall {
        let id: UUID
        let node: SCNNode
        let plane: SCNPlane
        var maskImage: UIImage
        var maskSize: CGSize
        var wallSize: CGSize
        var transform: simd_float4x4   // ★ mutable: follows ARKit world re-localization
        var anchorID: UUID?            // ★ ARAnchor that keeps the wall locked to the real surface
        var cutoutArea: Float = 0      // ★ door/window area on this wall (m²), subtracted from price
    }
    // ARAnchor.identifier -> wall surface UUID
    private var wallAnchorIDs: [UUID: UUID] = [:]
    private var walls: [UUID: Wall] = [:]
    private let maskPxPerMeter: CGFloat = 256

    // Brush / Lasso / Wallpaper
    private var brushMode: BrushMode = .erase
    private var brushRadiusMeters: Float = 0.08
    private var editModeActive = false
    private var brushStrokeStarted = false
    private var brushCursorNode: SCNNode?

    private var lassoModeActive = false
    private var lassoWorldPoints: [SIMD3<Float>] = []
    private var lassoDotNodes: [SCNNode] = []
    private var lassoLineNodes: [SCNNode] = []
    private var lassoClosed = false
    private var lastLassoBroadcast: TimeInterval = 0

    private var lassoDragging = false
    private var lassoDragTargetWallID: UUID?
    private let lassoDragMinSpacing: CGFloat = 8

    private var undoStack: [(UUID, UIImage)] = []
    private let maxUndo = 30

    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var wallpaperOpacity: CGFloat = 0.96
    private var wallpaperRollWidth: CGFloat = 0.53
    private var isWallpaperApplied = false

    private var currentWallIndex: Int = 0
    private var panGesture: UIPanGestureRecognizer?
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // ════════════════════════════════════════════════════════════
    // DIAGNOSTIC LOG
    // ════════════════════════════════════════════════════════════
    private var diagLog: [String] = []
    private let diagLogMax = 200
    // ★ Diagnostic kill-switch for the occluder. Now that mesh runs on the single
    // shared session (no reconfiguration), the occluder no longer causes offset,
    // so this is false (occluder ON). Flip to true only to isolate occluder.
    private let DIAG_skipOccluder = false

    // ★ Held so we can re-assert scene depth after RoomPlan's session starts
    // (RoomPlan can drop sceneDepth from frames when it begins; documented).
    private var pendingMeshConfig: ARWorldTrackingConfiguration?

    private var meshAnchorCount = 0
    // ★ Stage 1: LiDAR wall-measurement probe (non-destructive — logs only).
    // World-space vertices classified as .wall, kept per anchor so they refresh
    // and don't grow unbounded. Used to fit the wall plane from real geometry.
    private var wallMeshPointsByAnchor: [UUID: [SIMD3<Float>]] = [:]
    private var lastCameraForward: SIMD3<Float>?
    private var lastCameraPos: SIMD3<Float>?
    private var roomUpdateCount = 0
    private var lastRayHitInfo: String = "none"

    private func diag(_ msg: String) {
        let ts = String(format: "%.3f", CACurrentMediaTime().truncatingRemainder(dividingBy: 100000))
        let line = "[\(ts)] \(msg)"
        diagLog.append(line)
        if diagLog.count > diagLogMax { diagLog.removeFirst(diagLog.count - diagLogMax) }
        emit("diag", data: ["line": line])
    }

    private func diagSnapshot() -> String {
        // Return formatted text (String) so Dart can cast it directly.
        var lines: [String] = []
        lines.append("=== OBOIA DIAGNOSTIC REPORT ===")
        lines.append("timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("STATE")
        lines.append("  wallsCount         = \(walls.count)")
        lines.append("  scanPreviewCount   = \(scanPreviewNodes.count)")
        lines.append("  occluderCount      = \(occluderNodes.count)")
        lines.append("  meshAnchorsSeen    = \(meshAnchorCount)   <-- LiDAR mesh activity")
        lines.append("  roomUpdates        = \(roomUpdateCount)   <-- RoomPlan didUpdate firings")
        lines.append("  lassoPoints        = \(lassoWorldPoints.count)")
        lines.append("  lassoModeActive    = \(lassoModeActive)")
        lines.append("  lassoDragging      = \(lassoDragging)")
        lines.append("  editModeActive     = \(editModeActive)")
        lines.append("  currentMode        = \(currentMode.rawValue)")
        lines.append("  isWallpaperApplied = \(isWallpaperApplied)")
        lines.append("  occluderEnabled    = \(occluderEnabled)")
        lines.append("  lastRayHit         = \(lastRayHitInfo)")
        lines.append("")
        lines.append("WALLS DETAIL")
        if walls.isEmpty {
            lines.append("  (no walls)")
        } else {
            for (i, (_, w)) in walls.enumerated() {
                let pos = w.transform.columns.3
                lines.append("  Wall #\(i): size=\(w.wallSize.width)x\(w.wallSize.height) center=(\(pos.x),\(pos.y),\(pos.z))")
            }
        }
        lines.append("")
        lines.append("LIDAR WALL FIT (Stage 1 probe — measurement only)")
        if let f = fitWallFromMesh() {
            let areaLidar = f.w * f.h
            lines.append("  lidar size = \(String(format: "%.3f", f.w)) x \(String(format: "%.3f", f.h)) m")
            lines.append("  lidar area = \(String(format: "%.3f", areaLidar)) m²  (from \(f.count) wall points)")
            lines.append("  lidar center = (\(String(format: "%.3f", f.center.x)),\(String(format: "%.3f", f.center.y)),\(String(format: "%.3f", f.center.z)))")
            if let w0 = walls.first?.value {
                let areaRP = Float(w0.wallSize.width * w0.wallSize.height)
                lines.append("  roomplan size = \(String(format: "%.3f", Float(w0.wallSize.width))) x \(String(format: "%.3f", Float(w0.wallSize.height))) m  area=\(String(format: "%.3f", areaRP)) m²")
                lines.append("  >>> COMPARE these across repeated scans of the SAME wall: lidar should stay steady, roomplan won't <<<")
            }
        } else {
            let total = wallMeshPointsByAnchor.values.reduce(0) { $0 + $1.count }
            lines.append("  (not enough wall mesh yet — \(total) points; aim camera at wall a moment longer)")
        }
        lines.append("")
        lines.append("LOG TAIL (last 100)")
        for entry in diagLog.suffix(100) {
            lines.append("  \(entry)")
        }
        return lines.joined(separator: "\n")
    }

    // ════════════════════════════════════════════════════════════
    // MATERIALS
    // ════════════════════════════════════════════════════════════

    private static let occluderMat: SCNMaterial = {
        let m = SCNMaterial()
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        sceneView.addGestureRecognizer(pan)
        panGesture = pan

        channel.setMethodCallHandler { [weak self] (call, result) in self?.route(call, result) }
        diag("init() complete")
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
            if let m = call.arguments as? String { brushMode = (m == "paint") ? .paint : .erase; diag("brushMode = \(m)") }
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
        case "lassoStart":
            startLassoMode()
            panGesture?.isEnabled = false  // ★ BUG A FIX: disable Swift pan so Flutter drag works
            diag("lasso START: panGesture disabled")
            result(nil)
        case "lassoEnd":
            endLassoMode()
            panGesture?.isEnabled = true   // re-enable brush pan
            diag("lasso END: panGesture re-enabled")
            result(nil)
        case "lassoAddPoint":
            if let x = args?["x"] as? Double, let y = args?["y"] as? Double {
                addLassoPoint(CGPoint(x: x, y: y))
            }
            result(nil)
        case "lassoClear":   clearLassoPoints(); result(nil)
        case "lassoApply":
            if let mode = args?["mode"] as? String { applyLasso(mode: mode) }
            result(nil)

        case "lassoBeginDrag":
            if let x = args?["x"] as? Double, let y = args?["y"] as? Double {
                beginLassoDrag(CGPoint(x: x, y: y))
            }
            result(nil)
        case "lassoDragPoint":
            if let x = args?["x"] as? Double, let y = args?["y"] as? Double {
                dragLassoTo(CGPoint(x: x, y: y))
            }
            result(nil)
        case "lassoEndDrag":
            endLassoDrag()
            result(nil)

        case "setOccluderEnabled":
            if let on = args?["enabled"] as? Bool {
                occluderEnabled = on
                for (_, n) in occluderNodes { n.isHidden = !on }
                emit("boot", data: ["status": "Occluder: \(on ? "ON" : "OFF") (\(occluderNodes.count) meshes)"])
                diag("setOccluderEnabled=\(on) — \(occluderNodes.count) occluder nodes exist")
            }
            result(nil)

        // ★ NEW: Diagnostic report (Dart calls this 'getDiagnostics')
        case "getDiagnostics":
            result(diagSnapshot())

        // ★ NEW: Capture current AR scene as base64 PNG for wall thumbnail
        case "captureScreenshot":
            let snapshot: UIImage = sceneView.snapshot()
            if let data = snapshot.pngData() {
                let b64 = data.base64EncodedString()
                diag("captureScreenshot ok (\(data.count) bytes)")
                result(b64)
            } else {
                diag("captureScreenshot FAILED — pngData() returned nil")
                result(FlutterError(code: "SNAPSHOT", message: "Could not capture", details: nil))
            }

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
        emit("boot", data: ["status": "AR ready (v13 diag)"])
        diag("bootIdleSession ok")
    }

    private func setARMode(_ mode: String, result: @escaping FlutterResult) {
        if let m = ARViewMode(rawValue: mode) { currentMode = m }
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    private func teardown() {
        roomCaptureSession?.stop(pauseARSession: true)
        roomCaptureSession = nil
        clearScanPreviewNodes()
        clearOccluderNodes()
        sceneView.session.pause()
    }

    // ════════════════════════════════════════════════════════════
    // SCAN
    // ════════════════════════════════════════════════════════════

    private func startScan(result: @escaping FlutterResult) {
        diag(">>> startScan v13 <<<")
        emit("boot", data: ["status": ">>> startScan v13 <<<"])
        guard RoomCaptureSession.isSupported else {
            emit("error", data: ["message": "RoomPlan not supported"])
            result(FlutterError(code: "NOROOMPLAN", message: "Not supported", details: nil))
            return
        }

        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()
        clearScanPreviewNodes()
        clearOccluderNodes()
        undoStack.removeAll()
        latestCapturedRoom = nil
        lastLiveRoom = nil
        isWallpaperApplied = false
        editModeActive = false
        meshAnchorCount = 0
        wallMeshPointsByAnchor.removeAll()
        wallAnchorIDs.removeAll()
        roomUpdateCount = 0
        removeCursor()
        endLassoMode()
        currentMode = .scanning

        let session: RoomCaptureSession
        // ★ ROOT-CAUSE FIX: use ONE ARSession for the whole flow. Previously we
        // ran RoomPlan on its default session, then later called session.run()
        // with a mesh config for the occluder — that reconfiguration shifts
        // ARKit's world origin (documented iOS behaviour), which slid the wall
        // off the grid. Now we build our own ARWorldTrackingConfiguration with
        // sceneReconstruction enabled, hand it to RoomPlan (iOS 17+ custom
        // ARSession), and NEVER reconfigure it. One session, no swap → the world
        // origin never moves → the wall stays exactly where the grid was, and we
        // still get LiDAR mesh for the occluder from the same session.
        let customSession = ARSession()
        let cfg = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            cfg.sceneReconstruction = .meshWithClassification
        }
        cfg.planeDetection = []
        cfg.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            cfg.frameSemantics.insert(.sceneDepth)
        }
        pendingMeshConfig = cfg                       // re-asserted after RoomPlan starts (see didStartWith)
        customSession.run(cfg)
        session = RoomCaptureSession(arSession: customSession)
        session.delegate = self
        roomCaptureSession = session
        roomBuilder = RoomBuilder(options: [.beautifyObjects])

        sceneView.session = customSession
        sceneView.session.delegate = self
        diag("single-session: custom ARSession (mesh+depth) handed to RoomCaptureSession")

        let config = RoomCaptureSession.Configuration()
        session.run(configuration: config)
        diag("session.run() called")
        emit("boot", data: ["status": "Move slowly across walls"])
        result(nil)
    }

    private func stopScan(result: @escaping FlutterResult) {
        guard let session = roomCaptureSession else {
            emit("error", data: ["message": "No scan in progress"]); result(nil); return
        }
        diag("stopScan — session.stop(pauseARSession: false)")
        animateOutScanPreviews()
        session.stop(pauseARSession: false)
        currentMode = .preview
        emit("boot", data: ["status": "Processing room..."])
        result(nil)
    }

    // ════════════════════════════════════════════════════════════
    // LIVE SCAN PREVIEW
    // ════════════════════════════════════════════════════════════

    private func updateScanPreview(from room: CapturedRoom) {
        var alive = Set<UUID>()

        for wall in room.walls {
            alive.insert(wall.identifier)
            upsertScanWireframe(for: wall, color: .white, withFill: true)
        }
        for door in room.doors {
            alive.insert(door.identifier)
            upsertScanWireframe(for: door, color: .systemOrange, withFill: false)
        }
        for win in room.windows {
            alive.insert(win.identifier)
            upsertScanWireframe(for: win, color: .systemCyan, withFill: false)
        }
        for op in room.openings {
            alive.insert(op.identifier)
            upsertScanWireframe(for: op, color: .systemYellow, withFill: false)
        }

        for (id, node) in scanPreviewNodes where !alive.contains(id) {
            node.removeFromParentNode()
            scanPreviewNodes.removeValue(forKey: id)
        }
    }

    /// Generate a procedural grid texture for scan visualization.
    /// Returns a UIImage with a transparent background and bright grid lines.
    private static func makeScanGridTexture(color: UIColor) -> UIImage {
        let size = CGSize(width: 256, height: 256)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0; fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            // Faint background tint
            cg.setFillColor(color.withAlphaComponent(0.08).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Grid lines
            cg.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
            cg.setLineWidth(1.5)
            let step: CGFloat = 32  // grid cell size in pixels
            var x: CGFloat = 0
            while x <= size.width {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            cg.strokePath()
            // Brighter inner grid (cross pattern)
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(0.8)
            x = step / 2
            while x <= size.width {
                cg.move(to: CGPoint(x: x, y: 0))
                cg.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            y = step / 2
            while y <= size.height {
                cg.move(to: CGPoint(x: 0, y: y))
                cg.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            cg.strokePath()
        }
    }

    private static let scanGridTextureCyan: UIImage = makeScanGridTexture(color: UIColor.cyan)
    private static let scanGridTextureWhite: UIImage = makeScanGridTexture(color: UIColor.white)

    private func upsertScanWireframe(
        for surface: CapturedRoom.Surface,
        color: UIColor,
        withFill: Bool
    ) {
        let w = CGFloat(surface.dimensions.x)
        let h = CGFloat(surface.dimensions.y)
        guard w > 0.2, h > 0.2 else { return }

        if let existing = scanPreviewNodes[surface.identifier] {
            // Resize fill and border planes (corner markers stay at fixed size)
            for child in existing.childNodes {
                if let plane = child.geometry as? SCNPlane {
                    // Skip corner markers (they are 10cm × 10cm), only resize big planes
                    if plane.width > 0.5 || plane.height > 0.5 {
                        plane.width = w; plane.height = h
                    }
                }
            }
            existing.simdTransform = surface.transform
            return
        }

        let container = SCNNode()
        container.simdTransform = surface.transform

        // ★ NEW: Use a procedural grid texture for the fill — gives a real "3D scan" feel
        if withFill {
            let fillPlane = SCNPlane(width: w, height: h)
            let fillMat = SCNMaterial()
            // Tile the grid texture so cells are roughly 20cm × 20cm in the world.
            let tilesX = max(1.0, w / 0.20)
            let tilesY = max(1.0, h / 0.20)
            fillMat.diffuse.contents = (color == .white)
                ? WallpaperARView.scanGridTextureWhite
                : WallpaperARView.scanGridTextureCyan
            fillMat.diffuse.wrapS = .repeat; fillMat.diffuse.wrapT = .repeat
            fillMat.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(tilesX), Float(tilesY), 1)
            fillMat.emission.contents = (color == .white)
                ? WallpaperARView.scanGridTextureWhite
                : WallpaperARView.scanGridTextureCyan
            fillMat.emission.wrapS = .repeat; fillMat.emission.wrapT = .repeat
            fillMat.emission.contentsTransform = SCNMatrix4MakeScale(Float(tilesX), Float(tilesY), 1)
            fillMat.lightingModel = .constant
            fillMat.isDoubleSided = true
            fillMat.blendMode = .alpha
            fillMat.writesToDepthBuffer = false
            fillMat.readsFromDepthBuffer = false
            fillPlane.materials = [fillMat]
            let fillNode = SCNNode(geometry: fillPlane)
            fillNode.renderingOrder = 595
            container.addChildNode(fillNode)
        }

        // Thin bright outline border
        let wirePlane = SCNPlane(width: w, height: h)
        let wireMat = SCNMaterial()
        wireMat.fillMode = .lines
        wireMat.diffuse.contents = color
        wireMat.emission.contents = color
        wireMat.lightingModel = .constant
        wireMat.isDoubleSided = true
        wireMat.writesToDepthBuffer = false
        wireMat.readsFromDepthBuffer = false
        wirePlane.materials = [wireMat]
        let wireNode = SCNNode(geometry: wirePlane)
        wireNode.renderingOrder = 600
        container.addChildNode(wireNode)

        // ★ NEW: 4 bright corner markers — gives that "AR CAD scanning" precision feel
        if withFill {
            let cornerSize: CGFloat = 0.10  // 10cm corner brackets
            let positions: [(Float, Float)] = [
                (-Float(w/2 - cornerSize/2),  Float(h/2 - cornerSize/2)),  // top-left
                ( Float(w/2 - cornerSize/2),  Float(h/2 - cornerSize/2)),  // top-right
                (-Float(w/2 - cornerSize/2), -Float(h/2 - cornerSize/2)),  // bottom-left
                ( Float(w/2 - cornerSize/2), -Float(h/2 - cornerSize/2)),  // bottom-right
            ]
            for (cx, cy) in positions {
                let dot = SCNPlane(width: cornerSize, height: cornerSize)
                let dotMat = SCNMaterial()
                dotMat.diffuse.contents = UIColor.cyan
                dotMat.emission.contents = UIColor.cyan
                dotMat.lightingModel = .constant
                dotMat.isDoubleSided = true
                dotMat.writesToDepthBuffer = false
                dotMat.readsFromDepthBuffer = false
                dot.materials = [dotMat]
                let dotNode = SCNNode(geometry: dot)
                dotNode.position = SCNVector3(cx, cy, 0.001)
                dotNode.renderingOrder = 605
                // Pulse the corner markers in sync — feels like beacons
                let p1 = SCNAction.fadeOpacity(to: 0.4, duration: 0.7)
                let p2 = SCNAction.fadeOpacity(to: 1.0, duration: 0.7)
                dotNode.runAction(SCNAction.repeatForever(SCNAction.sequence([p1, p2])))
                container.addChildNode(dotNode)
            }
        }

        sceneView.scene.rootNode.addChildNode(container)
        scanPreviewNodes[surface.identifier] = container

        // Smooth entrance: scale-up + fade-in
        container.scale = SCNVector3(0.1, 0.1, 1.0)
        container.opacity = 0
        let scaleAction = SCNAction.scale(to: 1.0, duration: 0.4)
        scaleAction.timingMode = .easeOut
        let fadeAction = SCNAction.fadeIn(duration: 0.4)
        let entrance = SCNAction.group([scaleAction, fadeAction])

        // Subtle continuous pulse on the whole node
        let pulseUp = SCNAction.fadeOpacity(to: 1.0, duration: 1.2)
        let pulseDown = SCNAction.fadeOpacity(to: 0.75, duration: 1.2)
        let pulse = SCNAction.sequence([pulseUp, pulseDown])
        let pulseForever = SCNAction.repeatForever(pulse)

        container.runAction(SCNAction.sequence([entrance, pulseForever]))
    }

    private func animateOutScanPreviews() {
        // ★ Immediate removal — no fade-out animation.
        // The previous fade-out had a race condition where async actions left
        // grid/corner nodes visible on top of the wallpaper. Instant removal
        // is cleaner and matches the "wallpaper magically appears" intent.
        for (_, node) in scanPreviewNodes {
            // Stop all running actions (pulse, corner pulses) and detach immediately.
            node.removeAllActions()
            for child in node.childNodes {
                child.removeAllActions()
            }
            node.removeFromParentNode()
        }
        scanPreviewNodes.removeAll()
    }

    private func clearScanPreviewNodes() {
        for (_, node) in scanPreviewNodes { node.removeFromParentNode() }
        scanPreviewNodes.removeAll()
    }

    // ════════════════════════════════════════════════════════════
    // OCCLUDER
    // ════════════════════════════════════════════════════════════

    private func buildOccluderGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        let vCount = geo.vertices.count
        let fCount = geo.faces.count
        guard vCount > 0, fCount > 0 else { return nil }

        var verts = [SCNVector3]()
        verts.reserveCapacity(vCount)
        let vS = geo.vertices
        // Also keep world-space positions for wall-plane proximity test.
        var worldVerts = [SIMD3<Float>]()
        worldVerts.reserveCapacity(vCount)
        let anchorTransform = anchor.transform
        for i in 0..<vCount {
            let p = vS.buffer.contents().advanced(by: vS.offset + vS.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            verts.append(SCNVector3(p.x, p.y, p.z))
            // Transform local mesh vertex to world space
            let w4 = anchorTransform * SIMD4<Float>(p.x, p.y, p.z, 1.0)
            worldVerts.append(SIMD3<Float>(w4.x, w4.y, w4.z))
        }

        // Pre-extract wall planes (normal + center) for proximity test.
        // We want to SKIP mesh triangles that lie on or very near a RoomPlan wall —
        // those are the wall itself, and our flat wallpaper plane handles it cleanly.
        var wallPlanes: [(SIMD3<Float>, SIMD3<Float>)] = []  // (normal, center)
        for (_, w) in walls {
            let nrm = SIMD3<Float>(w.transform.columns.2.x, w.transform.columns.2.y, w.transform.columns.2.z)
            let center = SIMD3<Float>(w.transform.columns.3.x, w.transform.columns.3.y, w.transform.columns.3.z)
            wallPlanes.append((nrm, center))
        }
        let wallProximity: Float = 0.08  // 8cm — wider, removes more wall-near fuzz

        var anchorWallPoints: [SIMD3<Float>] = []   // ★ Stage 1: wall verts from this anchor

        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive
        let cOpt = geo.classification
        var idx: [UInt32] = []
        for f in 0..<fCount {
            // ★ Skip walls / floor / ceiling — only OBJECTS in front of walls should occlude
            var skip = false
            if let c = cOpt {
                let cv = c.buffer.contents().advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                if let cls = ARMeshClassification(rawValue: Int(cv)) {
                    switch cls {
                    case .wall, .floor, .ceiling: skip = true
                    default: skip = false  // table, seat, window, door, none → occlude these
                    }
                    // ★ Stage 1: harvest WALL-classified triangle vertices for the
                    // LiDAR plane fit (subsample: first vertex of each wall face).
                    if cls == .wall && ipf == 3 {
                        let p = fEl.buffer.contents().advanced(by: (f * ipf) * bpi)
                        let vIdx: UInt32 = (bpi == 4)
                            ? p.assumingMemoryBound(to: UInt32.self).pointee
                            : UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)
                        if Int(vIdx) < worldVerts.count {
                            anchorWallPoints.append(worldVerts[Int(vIdx)])
                        }
                    }
                }
            }
            if skip { continue }

            // ★ Additionally skip triangles too close to RoomPlan walls — these are
            // mesh artifacts that would jaggedly occlude our clean wallpaper plane
            var nearWall = false
            if !wallPlanes.isEmpty && ipf == 3 {
                // Read all 3 vertex indices for this triangle
                var triVerts: [SIMD3<Float>] = []
                triVerts.reserveCapacity(3)
                for j in 0..<3 {
                    let p = fEl.buffer.contents().advanced(by: (f * ipf + j) * bpi)
                    let vIdx: UInt32
                    if bpi == 4 { vIdx = p.assumingMemoryBound(to: UInt32.self).pointee }
                    else { vIdx = UInt32(p.assumingMemoryBound(to: UInt16.self).pointee) }
                    if Int(vIdx) < worldVerts.count {
                        triVerts.append(worldVerts[Int(vIdx)])
                    }
                }
                // If ALL 3 vertices are within wallProximity of any wall plane, skip
                if triVerts.count == 3 {
                    for (n, c) in wallPlanes {
                        let d0 = abs(simd_dot(triVerts[0] - c, n))
                        let d1 = abs(simd_dot(triVerts[1] - c, n))
                        let d2 = abs(simd_dot(triVerts[2] - c, n))
                        if d0 < wallProximity && d1 < wallProximity && d2 < wallProximity {
                            nearWall = true
                            break
                        }
                    }
                }
            }
            if nearWall { continue }

            for j in 0..<ipf {
                let p = fEl.buffer.contents().advanced(by: (f * ipf + j) * bpi)
                if bpi == 4 { idx.append(p.assumingMemoryBound(to: UInt32.self).pointee) }
                else { idx.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee)) }
            }
        }
        // ★ Stage 1: record this anchor's wall points (replaces prior, bounded).
        // Done BEFORE the occluder early-return, since a pure-wall anchor has no
        // occluder faces but is exactly the geometry we want to measure.
        if !anchorWallPoints.isEmpty {
            wallMeshPointsByAnchor[anchor.identifier] = anchorWallPoints
        }

        guard !idx.isEmpty else { return nil }

        let vertSrc = SCNGeometrySource(vertices: verts)
        let idxData = Data(bytes: idx, count: idx.count * 4)
        let element = SCNGeometryElement(data: idxData, primitiveType: .triangles,
            primitiveCount: idx.count / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [vertSrc], elements: [element])
        g.materials = [WallpaperARView.occluderMat]
        return g
    }

    private func clearOccluderNodes() {
        for (_, n) in occluderNodes { n.removeFromParentNode() }
        occluderNodes.removeAll()
    }

    // ★ Stage 1: fit the wall the camera faces from accumulated LiDAR points.
    // Returns real-world width/height/center, measured from actual geometry
    // (not RoomPlan's estimate). Non-destructive: used for logging/comparison.
    // Orientation comes from the camera (the wall the user points at); size and
    // position come from the mesh points, with percentile clipping to reject
    // stray points from other surfaces.
    private func fitWallFromMesh() -> (w: Float, h: Float, center: SIMD3<Float>, n: SIMD3<Float>, count: Int)? {
        var pts: [SIMD3<Float>] = []
        for (_, arr) in wallMeshPointsByAnchor { pts.append(contentsOf: arr) }
        guard pts.count >= 30, let camF = lastCameraForward else { return nil }

        // Wall normal ≈ horizontalized camera-forward (the surface we face).
        var n = SIMD3<Float>(camF.x, 0, camF.z)
        let nLen = simd_length(n)
        guard nLen > 1e-4 else { return nil }
        n /= nLen

        // Plane frame: up is world-up; right = up × n (horizontal along wall).
        let up = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(up, n)
        let rLen = simd_length(right)
        guard rLen > 1e-4 else { return nil }
        right /= rLen

        // Plane offset along n: median rejects points from other walls.
        let offsets = pts.map { simd_dot($0, n) }.sorted()
        let medOffset = offsets[offsets.count / 2]
        let onPlane = pts.filter { abs(simd_dot($0, n) - medOffset) < 0.12 }
        guard onPlane.count >= 20 else { return nil }

        // Robust 2.5–97.5 percentile spans reject stray cove/adjacent points.
        let us = onPlane.map { simd_dot($0, right) }.sorted()
        let vs = onPlane.map { simd_dot($0, up) }.sorted()
        func pct(_ a: [Float], _ p: Float) -> Float {
            let i = max(0, min(a.count - 1, Int(p * Float(a.count - 1))))
            return a[i]
        }
        let uMin = pct(us, 0.025), uMax = pct(us, 0.975)
        let vMin = pct(vs, 0.025), vMax = pct(vs, 0.975)
        let w = uMax - uMin
        let h = vMax - vMin
        guard w > 0.2, h > 0.2 else { return nil }

        let uC = (uMin + uMax) / 2
        let vC = (vMin + vMax) / 2
        let center = right * uC + up * vC + n * medOffset
        return (w, h, center, n, onPlane.count)
    }

    // ════════════════════════════════════════════════════════════
    // FINAL ROOM PROCESSING
    // ════════════════════════════════════════════════════════════

    private func processFinalRoom(_ room: CapturedRoom) {
        diag("processFinalRoom: \(room.walls.count) walls, \(room.doors.count) doors, \(room.windows.count) windows, \(room.openings.count) openings")

        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()
        // ★ drop stale wall anchors so they don't linger across rebuilds
        if let frame = sceneView.session.currentFrame {
            for a in frame.anchors where wallAnchorIDs[a.identifier] != nil {
                sceneView.session.remove(anchor: a)
            }
        }
        wallAnchorIDs.removeAll()

        var built = 0
        for surface in room.walls {
            if buildWall(from: surface, doors: room.doors, windows: room.windows, openings: room.openings) {
                built += 1
            }
        }

        let area = totalArea()
        diag("Built \(built) walls (total area \(area) m²)")

        // ★ Mesh + depth are ALREADY running on our single shared session (set up
        // in startScan), so the occluder's ARMeshAnchors arrive without any
        // session reconfiguration. We must NOT call session.run() again here —
        // that reconfiguration is exactly what used to shift the world origin and
        // slide the wall off the grid. So: do nothing; the mesh is already coming.
        if DIAG_skipOccluder {
            diag("DIAG_skipOccluder = true — occluder disabled (test mode)")
        } else {
            diag("occluder: mesh already live on shared session — no session swap needed")
        }

        emit("scanComplete", data: [
            "totalWallArea": area,
            "meshSegments": built,
            "wallsDetected": built
        ])
        emit("boot", data: ["status": "Done: \(built) walls, \(String(format: "%.1f", area)) m²"])
    }

    /// Start ARKit world tracking with LiDAR scene reconstruction enabled.
    /// This MUST run AFTER RoomPlan finishes so we don't lose RoomPlan's wall
    /// detection (RoomPlan's session does not produce mesh anchors itself).
    private func startMeshTrackingForOccluder() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            diag("scene reconstruction not supported — no occluder available")
            return
        }
        let cfg = ARWorldTrackingConfiguration()
        cfg.sceneReconstruction = .meshWithClassification
        cfg.planeDetection = []
        cfg.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            cfg.frameSemantics.insert(.sceneDepth)
        }
        // CRITICAL: do NOT reset tracking — that would lose our walls' world position.
        // Just upgrade the configuration in place.
        sceneView.session.run(cfg, options: [])
        diag("startMeshTrackingForOccluder: ran ARWorldTrackingConfiguration with .meshWithClassification (no resetTracking)")
    }

    private func buildWall(
        from surface: CapturedRoom.Surface,
        doors: [CapturedRoom.Surface],
        windows: [CapturedRoom.Surface],
        openings: [CapturedRoom.Surface]
    ) -> Bool {
        let wMeters = CGFloat(surface.dimensions.x)
        let hMeters = CGFloat(surface.dimensions.y)
        guard wMeters > 0.5 && hMeters > 0.5 else {
            diag("Skipped wall \(surface.identifier.uuidString.prefix(8)) too small: \(wMeters)x\(hMeters)")
            return false
        }

        let plane = SCNPlane(width: wMeters, height: hMeters)
        plane.cornerRadius = 0

        let maskW = max(64, Int(wMeters * maskPxPerMeter))
        let maskH = max(64, Int(hMeters * maskPxPerMeter))
        let maskSize = CGSize(width: maskW, height: maskH)
        let mask = buildInitialMask(
            wallTransform: surface.transform,
            wallSize: CGSize(width: wMeters, height: hMeters),
            maskSize: maskSize,
            doors: doors, windows: windows, openings: openings)

        let mat = buildWallMaterial(mask: mask, wallWidth: wMeters, wallHeight: hMeters)
        plane.materials = [mat]

        let node = SCNNode(geometry: plane)
        node.simdTransform = surface.transform
        sceneView.scene.rootNode.addChildNode(node)

        // ★ Sum door/window/opening area that belongs to THIS wall (same matching
        // rule as the mask cutouts), so the charged area excludes what you don't
        // paper. Read-only on already-detected surfaces — does not affect geometry.
        var cutoutArea: Float = 0
        let invWall = simd_inverse(surface.transform)
        for cut in (doors + windows + openings) {
            let c = cut.transform.columns.3
            let lh = invWall * SIMD4<Float>(c.x, c.y, c.z, 1.0)
            if abs(lh.z) > 0.30 { continue }   // not on this wall plane
            cutoutArea += cut.dimensions.x * cut.dimensions.y
        }

        // ★ Anchor the wall to ARKit. When the occluder session re-localizes the
        // world, ARKit adjusts this anchor and we move the wall to match (see
        // session(_:didUpdate:)), so the wallpaper stays locked to the real wall
        // instead of sliding off the grid. The node is still placed at
        // surface.transform here, so if no correction arrives, behaviour is
        // identical to before.
        let anchor = ARAnchor(name: "wall_\(surface.identifier.uuidString)", transform: surface.transform)
        sceneView.session.add(anchor: anchor)
        wallAnchorIDs[anchor.identifier] = surface.identifier

        walls[surface.identifier] = Wall(
            id: surface.identifier,
            node: node,
            plane: plane,
            maskImage: mask,
            maskSize: maskSize,
            wallSize: CGSize(width: wMeters, height: hMeters),
            transform: surface.transform,
            anchorID: anchor.identifier,
            cutoutArea: cutoutArea
        )
        diag("Built wall id=\(surface.identifier.uuidString.prefix(8)) size=\(String(format: "%.2f", wMeters))x\(String(format: "%.2f", hMeters)) cutout=\(String(format: "%.2f", cutoutArea))m²")
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
                let localCenter = SIMD3<Float>(localH.x, localH.y, localH.z)
                if abs(localCenter.z) > 0.30 { continue }

                let cutW = CGFloat(cut.dimensions.x)
                let cutH = CGFloat(cut.dimensions.y)
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
            let gross = Float(w.wallSize.width * w.wallSize.height)
            // Subtract doors/windows (not papered); never let a wall go negative.
            let net = max(0, gross - w.cutoutArea)
            total += net
        }
        // ★ Marketplace-safe: round the charged area UP to the next 0.1 m² so a
        // seller is never short on material. (Pure presentation of the measured
        // value — does not change the wall or its geometry.)
        return (total * 10).rounded(.up) / 10
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
            // ★ Pre-wallpaper: semi-transparent yellow tint so user can see the
            // actual room behind the painted selection area. Used during edit mode
            // before "Apply Wallpaper" is tapped.
            m.lightingModel = .constant
            m.diffuse.contents = UIColor(red: 1, green: 0.83, blue: 0.41, alpha: 0.5)
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

        m.transparency = wallpaperOpacity
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
        diag("enterEditMode (\(walls.count) walls)")
        emit("boot", data: ["status": "Edit mode (\(walls.count) walls)"])
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
    // ★ THE FIX: Use SceneKit's unprojectPoint for raycasts
    //
    // Instead of building a ray manually with frame.camera.projectionMatrix
    // (which may use a different viewport than what SceneKit actually renders),
    // we use sceneView.unprojectPoint() which is GUARANTEED to match the
    // current SceneKit rendering. This fixes lasso/eraser misalignment.
    // ════════════════════════════════════════════════════════════

    /// Cast a ray from camera through screenPoint using SceneKit's own
    /// unproject. Returns ray origin (near plane) and ray direction in world space.
    private func makeRayFromScreen(_ screenPoint: CGPoint) -> (SIMD3<Float>, SIMD3<Float>)? {
        // Sample SceneKit's view at near (z=0) and far (z=1) for the same screen point.
        // unprojectPoint gives us world coordinates that match what SceneKit renders.
        let nearV = sceneView.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 0))
        let farV = sceneView.unprojectPoint(SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 1))
        let near = SIMD3<Float>(Float(nearV.x), Float(nearV.y), Float(nearV.z))
        let far = SIMD3<Float>(Float(farV.x), Float(farV.y), Float(farV.z))
        let dir = far - near
        let dirLen = simd_length(dir)
        guard dirLen > 1e-6 else { return nil }
        return (near, dir / dirLen)
    }

    /// Find the nearest wall hit by a ray cast from this screen point.
    private func nearestWallByRay(_ screenPoint: CGPoint) -> (UUID, SIMD3<Float>)? {
        guard let (rayOrigin, rayDir) = makeRayFromScreen(screenPoint) else {
            lastRayHitInfo = "ray creation failed"
            return nil
        }

        var best: (id: UUID, hit: SIMD3<Float>, dist: Float)? = nil

        for (id, w) in walls {
            let nrm = SIMD3<Float>(w.transform.columns.2.x, w.transform.columns.2.y, w.transform.columns.2.z)
            let center = SIMD3<Float>(w.transform.columns.3.x, w.transform.columns.3.y, w.transform.columns.3.z)
            let denom = simd_dot(nrm, rayDir)
            if abs(denom) < 1e-6 { continue }
            let t = simd_dot(center - rayOrigin, nrm) / denom
            if t <= 0 { continue }
            let hit = rayOrigin + rayDir * t

            let invWall = simd_inverse(w.transform)
            let localH = invWall * SIMD4<Float>(hit.x, hit.y, hit.z, 1.0)
            // ★ FIX: Generous margin so tapping on curtains, TVs, or anything in
            // front of the wall still finds the wall behind. The ray-plane
            // intersection naturally gives us the wall point even if the user
            // tapped on something occluding it.
            let margin: Float = 1.0  // 1 meter beyond the wall edge
            let halfW = Float(w.wallSize.width) / 2 + margin
            let halfH = Float(w.wallSize.height) / 2 + margin
            if abs(localH.x) > halfW || abs(localH.y) > halfH { continue }

            if best == nil || t < best!.dist { best = (id, hit, t) }
        }
        guard let b = best else {
            lastRayHitInfo = "no wall hit (walls=\(walls.count))"
            return nil
        }
        lastRayHitInfo = "hit wall \(b.id.uuidString.prefix(8)) at t=\(String(format: "%.2f", b.dist))"
        return (b.id, b.hit)
    }

    /// Ray-cast onto a SPECIFIC wall.
    private func rayHitOnWall(_ screenPoint: CGPoint, wall w: Wall) -> SIMD3<Float>? {
        guard let (rayOrigin, rayDir) = makeRayFromScreen(screenPoint) else { return nil }
        let nrm = SIMD3<Float>(w.transform.columns.2.x, w.transform.columns.2.y, w.transform.columns.2.z)
        let center = SIMD3<Float>(w.transform.columns.3.x, w.transform.columns.3.y, w.transform.columns.3.z)
        let denom = simd_dot(nrm, rayDir)
        if abs(denom) < 1e-6 { return nil }
        let t = simd_dot(center - rayOrigin, nrm) / denom
        if t <= 0 { return nil }
        return rayOrigin + rayDir * t
    }

    // ════════════════════════════════════════════════════════════
    // BRUSH
    // ════════════════════════════════════════════════════════════

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive else { return }
        guard !lassoModeActive else { return }
        let pt = gesture.location(in: sceneView)

        switch gesture.state {
        case .began:
            brushStrokeStarted = false
            diag("brush.began at (\(Int(pt.x)),\(Int(pt.y)))")
            applyBrushAt(pt)
        case .changed:
            applyBrushAt(pt)
        case .ended, .cancelled:
            brushCursorNode?.isHidden = true
            brushStrokeStarted = false
            emit("selectionChanged", data: ["area": totalArea()])
        default: break
        }
    }

    private func applyBrushAt(_ screenPoint: CGPoint) {
        guard let (wallID, worldHit) = nearestWallByRay(screenPoint) else { return }
        guard var w = walls[wallID] else { return }

        if !brushStrokeStarted {
            saveUndo(anchorID: wallID, mask: w.maskImage)
            brushStrokeStarted = true
        }

        let invWall = simd_inverse(w.transform)
        let localH = invWall * SIMD4<Float>(worldHit.x, worldHit.y, worldHit.z, 1.0)
        let u = (CGFloat(localH.x) + w.wallSize.width / 2) / w.wallSize.width
        let v = (CGFloat(localH.y) + w.wallSize.height / 2) / w.wallSize.height
        let uC = max(0, min(1, u))
        let vC = max(0, min(1, v))
        let px = uC * w.maskSize.width
        let py = (1 - vC) * w.maskSize.height

        let pxPerMeterW = w.maskSize.width / w.wallSize.width
        let radiusPx = CGFloat(brushRadiusMeters) * pxPerMeterW

        let newMask = paintCircle(
            on: w.maskImage, size: w.maskSize,
            center: CGPoint(x: px, y: py),
            radius: radiusPx,
            erase: (brushMode == .erase))

        w.maskImage = newMask
        walls[wallID] = w
        refreshWall(wallID)

        moveCursor(to: SCNVector3(worldHit.x, worldHit.y, worldHit.z))
    }

    // ════════════════════════════════════════════════════════════
    // LASSO
    // ════════════════════════════════════════════════════════════

    private func startLassoMode() {
        lassoModeActive = true; lassoClosed = false
        clearLassoPoints()
        diag("startLassoMode")
        emit("boot", data: ["status": "Lasso — drag to draw a path"])
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
        lassoDragging = false
        lassoDragTargetWallID = nil
        emit("lassoState", data: ["active": lassoModeActive, "closed": false, "count": 0])
        broadcastLassoScreenPoints()
    }

    private func addLassoPoint(_ screenPoint: CGPoint) {
        guard lassoModeActive, !lassoClosed else { return }
        guard let (_, world) = nearestWallByRay(screenPoint) else {
            diag("lasso tap MISS at (\(Int(screenPoint.x)),\(Int(screenPoint.y))) — walls=\(walls.count)")
            emit("boot", data: ["status": "Tap on wall (no hit, walls=\(walls.count))"])
            return
        }
        if lassoWorldPoints.count >= 3 {
            if simd_distance(lassoWorldPoints[0], world) < 0.10 {
                lassoClosed = true
                addLassoLine(from: lassoWorldPoints.last!, to: lassoWorldPoints[0], isClosing: true)
                emit("lassoState", data: ["active": true, "closed": true, "count": lassoWorldPoints.count])
                emit("boot", data: ["status": "Loop closed — tap Apply"])
                broadcastLassoScreenPoints()
                return
            }
        }
        lassoWorldPoints.append(world)
        addLassoDot(at: world)
        if lassoWorldPoints.count >= 2 {
            addLassoLine(from: lassoWorldPoints[lassoWorldPoints.count - 2], to: world, isClosing: false)
        }
        emit("lassoState", data: ["active": true, "closed": false, "count": lassoWorldPoints.count])
        broadcastLassoScreenPoints()
    }

    private func beginLassoDrag(_ screenPoint: CGPoint) {
        guard lassoModeActive else { diag("beginLassoDrag IGNORED: lasso not active"); return }
        guard !lassoClosed else { diag("beginLassoDrag IGNORED: already closed"); return }
        guard let (wallID, world) = nearestWallByRay(screenPoint) else {
            diag("beginLassoDrag MISS at (\(Int(screenPoint.x)),\(Int(screenPoint.y))) walls=\(walls.count) hit=\(lastRayHitInfo)")
            emit("boot", data: ["status": "Start on wall (no hit, walls=\(walls.count))"])
            return
        }
        clearLassoPoints()
        lassoDragging = true
        lassoDragTargetWallID = wallID
        lassoWorldPoints.append(world)
        addLassoDot(at: world)
        diag("beginLassoDrag OK on wall \(wallID.uuidString.prefix(8)) at (\(Int(screenPoint.x)),\(Int(screenPoint.y)))")
        emit("lassoState", data: ["active": true, "closed": false, "count": 1])
        emit("boot", data: ["status": "Drawing... (1 pt)"])
        broadcastLassoScreenPoints()
    }

    private func dragLassoTo(_ screenPoint: CGPoint) {
        guard lassoModeActive, lassoDragging, !lassoClosed else { return }
        guard let wallID = lassoDragTargetWallID, let w = walls[wallID] else { return }
        guard let world = rayHitOnWall(screenPoint, wall: w) else { return }

        if let last = lassoWorldPoints.last {
            let lastSp = sceneView.projectPoint(SCNVector3(last.x, last.y, last.z))
            let dx = CGFloat(lastSp.x) - screenPoint.x
            let dy = CGFloat(lastSp.y) - screenPoint.y
            if sqrt(dx*dx + dy*dy) < lassoDragMinSpacing { return }
        }

        lassoWorldPoints.append(world)
        if lassoWorldPoints.count >= 2 {
            addLassoLine(from: lassoWorldPoints[lassoWorldPoints.count - 2], to: world, isClosing: false)
        }
        broadcastLassoScreenPoints()
    }

    private func endLassoDrag() {
        guard lassoModeActive, lassoDragging else { return }
        lassoDragging = false

        diag("endLassoDrag — collected \(lassoWorldPoints.count) points")
        if lassoWorldPoints.count >= 3 {
            lassoClosed = true
            addLassoLine(from: lassoWorldPoints.last!, to: lassoWorldPoints[0], isClosing: true)
            emit("lassoState", data: ["active": true, "closed": true, "count": lassoWorldPoints.count])
            emit("boot", data: ["status": "Drawn (\(lassoWorldPoints.count) pts) — tap Apply"])
        } else {
            emit("boot", data: ["status": "Need more points (got \(lassoWorldPoints.count))"])
            clearLassoPoints()
        }
        broadcastLassoScreenPoints()
    }

    private func addLassoDot(at world: SIMD3<Float>) {
        let s = SCNSphere(radius: 0.020)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.systemRed
        m.emission.contents = UIColor.systemRed.withAlphaComponent(0.6)
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
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
        m.lightingModel = .constant
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
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

            // ★ MAGICAL APPEARANCE: fade walls from 0 → wallpaperOpacity smoothly
            for (_, w) in self.walls {
                w.node.opacity = 0
            }
            self.refreshAllWalls()
            for (_, w) in self.walls {
                let fadeIn = SCNAction.fadeOpacity(to: 1.0, duration: 0.55)
                fadeIn.timingMode = .easeInEaseOut
                w.node.runAction(fadeIn)
            }

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
    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        // ★ Re-assert our mesh+depth config AFTER RoomPlan starts. RoomPlan can
        // drop sceneDepth/mesh from the shared session when it begins; re-running
        // the SAME config object (options: []) restores it WITHOUT resetting
        // tracking, so the world origin does not move.
        if let cfg = pendingMeshConfig {
            session.arSession.run(cfg, options: [])
            diag("didStartWith: re-asserted mesh+depth config (no reset)")
        }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.roomUpdateCount += 1
            self.latestCapturedRoom = room
            self.lastLiveRoom = room   // ★ remember the live geometry the grid is drawn from
            self.updateScanPreview(from: room)
            let walls = room.walls.count
            self.diag("roomUpdate #\(self.roomUpdateCount): \(walls) walls, \(room.doors.count) doors, \(room.windows.count) wins")
            self.emit("boot", data: ["status": "Scanning: \(walls) walls"])
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let e = error {
            diag("captureSession didEndWith error: \(e.localizedDescription)")
            emit("error", data: ["message": "Scan failed: \(e.localizedDescription)"])
            return
        }
        diag("captureSession didEndWith success — running RoomBuilder")
        Task { [weak self] in
            guard let self = self, let builder = self.roomBuilder else { return }
            do {
                let finalRoom = try await builder.capturedRoom(from: data)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // ★ Prefer the LIVE room (what the grid showed and what fits
                    // the wall). RoomBuilder's finalRoom inflates the wall height
                    // and adds phantom slivers, which is what made the wallpaper
                    // overflow onto the ceiling. Fall back to finalRoom only if
                    // we somehow never captured a live room with walls.
                    let roomToUse: CapturedRoom
                    if let live = self.lastLiveRoom, !live.walls.isEmpty {
                        roomToUse = live
                        self.diag("Using LIVE room (\(live.walls.count) walls) — matches grid, not RoomBuilder")
                    } else {
                        roomToUse = finalRoom
                        self.diag("No live room available — falling back to RoomBuilder (\(finalRoom.walls.count) walls)")
                    }
                    self.latestCapturedRoom = roomToUse
                    self.processFinalRoom(roomToUse)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.diag("RoomBuilder failed: \(error.localizedDescription)")
                    self?.emit("error", data: ["message": "Build failed: \(error.localizedDescription)"])
                }
            }
        }
    }
}

// MARK: - ARSessionDelegate / ARSCNViewDelegate

extension WallpaperARView: ARSessionDelegate, ARSCNViewDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ★ Stage 1: track camera orientation to pick the wall the user faces.
        let t = frame.camera.transform
        lastCameraForward = -SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        lastCameraPos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if lassoModeActive && !lassoWorldPoints.isEmpty {
            broadcastLassoScreenPoints()
        }
    }

    // ★ When the occluder session re-localizes the world, ARKit updates our wall
    // anchors. Snap the wall node + stored transform to the corrected position so
    // the wallpaper stays glued to the real wall (fixes the "shifted off the grid"
    // mismatch). Paint/lasso/raycast use w.transform, so keeping it in sync keeps
    // them aligned too.
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        if DIAG_skipOccluder { return }   // ★ keep wall purely static during the test
        for anchor in anchors {
            guard let wallID = wallAnchorIDs[anchor.identifier],
                  var w = walls[wallID] else { continue }
            w.node.simdTransform = anchor.transform
            w.transform = anchor.transform
            walls[wallID] = w
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let ma = anchor as? ARMeshAnchor {
            meshAnchorCount += 1
            diag("ARMeshAnchor added (total \(meshAnchorCount))")
            guard let geo = buildOccluderGeometry(from: ma) else { return }
            let occ = SCNNode(geometry: geo)
            occ.renderingOrder = -100
            occ.isHidden = !occluderEnabled
            node.addChildNode(occ)
            DispatchQueue.main.async { [weak self] in
                self?.occluderNodes[ma.identifier] = occ
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let occ = self.occluderNodes[ma.identifier],
                  let g = self.buildOccluderGeometry(from: ma) else { return }
            occ.geometry = g
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let ma = anchor as? ARMeshAnchor else { return }
        DispatchQueue.main.async { [weak self] in
            self?.occluderNodes[ma.identifier]?.removeFromParentNode()
            self?.occluderNodes.removeValue(forKey: ma.identifier)
            self?.wallMeshPointsByAnchor.removeValue(forKey: ma.identifier)
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
