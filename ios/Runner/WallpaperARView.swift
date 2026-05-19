// WallpaperARView.swift — v7 ARCHITECTURAL REWRITE
//
// Strategy (IKEA Place / RoomPlan approach):
//
//   1. WALL DETECTION: ARPlaneAnchor (vertical planes) give us perfectly flat wall surfaces
//   2. WALLPAPER RENDER: SCNPlane per wall, textured with wallpaper image — perfectly flat, photorealistic
//   3. CUTTING (brush + lasso): edits a per-wall 2D BITMAP MASK (CGContext drawing) →
//      • Brush = CGContext circle stroke (anti-aliased)
//      • Lasso = CGContext polygon fill (pixel-perfect straight lines)
//      The mask is applied as the wallpaper's transparency channel → razor-sharp edges
//   4. OCCLUSION: ARMeshAnchor (LiDAR mesh) becomes INVISIBLE depth-only occluder so
//      furniture/doors/objects naturally hide wallpaper behind them
//
// This produces:
//   • Flat photorealistic wallpaper (not draped on bumpy mesh)
//   • Pixel-perfect straight edges (mask is a bitmap, not vertex alpha)
//   • Smooth anti-aliased boundaries (CGContext anti-aliasing built in)
//   • Real occlusion from real furniture (mesh becomes invisible depth mask)

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

    // MARK: - Core SceneKit / AR

    private let sceneView: ARSCNView
    private let channel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private var currentMode: ARViewMode = .idle
    private let textureCache = TextureCache.shared
    private let eraserTool = EraserTool()

    // MARK: - Walls (the flat planes that get wallpaper)

    /// One entry per detected wall (vertical ARPlaneAnchor)
    private struct WallState {
        let anchorID: UUID
        let node: SCNNode             // SCNPlane node — the wallpaper surface
        let plane: SCNPlane           // geometry (we keep ref so we can resize)
        var maskImage: UIImage        // current 2D mask bitmap (alpha channel of wallpaper)
        var maskSize: CGSize          // mask resolution in pixels
        var wallSizeMeters: CGSize    // physical wall size (width × height)
    }
    private var walls: [UUID: WallState] = [:]

    /// Pixels per meter for the wall mask. 512 = 5mm per pixel → far finer than human eye.
    private let maskPixelsPerMeter: CGFloat = 512

    // MARK: - LiDAR Occluder Mesh (invisible depth-only)

    private var occluderNodes: [UUID: SCNNode] = [:]
    private var meshFrozen = false

    // MARK: - Brush / Lasso

    private var brushMode: BrushMode = .erase
    private var brushRadiusMeters: Float = 0.08
    private var editModeActive = false
    private var lastBrushPanLocation: CGPoint?
    private var brushStrokeHadUndo = false

    // Undo: stack of (anchorID, maskImage) snapshots
    private var undoStack: [(UUID, UIImage)] = []
    private let maxUndo = 20

    // MARK: - Lasso State

    /// Snapshot UIImageView for lasso freeze (so user sees still frame to draw on)
    private var snapshotImageView: UIImageView?

    // MARK: - Wallpaper Textures

    private var wpAlbedo: UIImage?
    private var wpNormal: UIImage?
    private var wpRoughness: UIImage?
    private var wpAO: UIImage?
    private var isWallpaperApplied = false
    private var wallpaperOpacity: CGFloat = 1.0
    /// Wallpaper roll width in meters (controls tile scale)
    private var wallpaperRollWidth: CGFloat = 0.53

    // MARK: - Other state

    private var currentWallIndex: Int = 0
    private var panGesture: UIPanGestureRecognizer?
    private var eventSink: ((Any) -> Void)?
    private var pendingEvents: [[String: Any]] = []

    // MARK: - Materials

    private lazy var occluderMaterial: SCNMaterial = {
        let m = SCNMaterial()
        // The trick: write to depth buffer, but render nothing visible.
        // Anything behind this node won't be drawn → wallpaper hidden behind real furniture.
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.isDoubleSided = true
        m.lightingModel = .constant
        return m
    }()

    // MARK: - Init

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

    // MARK: - Method channel router

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
            if let s = args?["size"] as? Double { brushRadiusMeters = Float(s) }
            result(nil)
        case "setWallpaperOpacity":
            if let o = args?["opacity"] as? Double {
                wallpaperOpacity = CGFloat(o)
                refreshAllWallpaperMaterials()
                emit("boot", data: ["status": "Opacity: \(Int(o * 100))%"])
            }
            result(nil)
        case "undoCut":      undoLast(); result(nil)
        case "clearAllCuts": resetAllMasks(); result(nil)
        case "applyLasso":
            if let pts = args?["points"] as? [[Double]], let mode = args?["mode"] as? String {
                applyLasso(screenPoints: pts, mode: mode)
            }
            result(nil)
        case "pauseSession":
            enterLassoMode()
            result(nil)
        case "resumeSession":
            exitLassoMode()
            result(nil)
        case "placeWallpaper", "switchWallpaper":
            placeWallpaper(args, result: result)
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
            result(["width": 0.0, "height": 0.0, "sqm": Double(totalWallArea())])
        case "toggleSurfaceExclusion", "toggleObjectExclusion", "setBrushColor":
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - AR Lifecycle

    private func initAR(result: @escaping FlutterResult) {
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        if st == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.runIdle(result: result) }
                    else {
                        self?.emit("error", data: ["message": "Camera denied"])
                        result(FlutterError(code: "CAM", message: "denied", details: nil))
                    }
                }
            }
            return
        }
        guard st == .authorized else {
            emit("error", data: ["message": "Camera denied"])
            result(FlutterError(code: "CAM", message: "denied", details: nil))
            return
        }
        runIdle(result: result)
    }

    private func runIdle(result: @escaping FlutterResult) {
        guard ARWorldTrackingConfiguration.isSupported else {
            emit("error", data: ["message": "ARKit not supported"])
            result(FlutterError(code: "NOAR", message: "no ARKit", details: nil))
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
        if let m = ARViewMode(rawValue: mode) { currentMode = m }
        emit("arModeChanged", data: ["mode": mode])
        result(nil)
    }

    // MARK: - Scan

    private func startScan(result: @escaping FlutterResult) {
        emit("boot", data: ["status": ">>> startScan v7 (plane-based) <<<"])
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            emit("error", data: ["message": "LiDAR not supported"])
            result(FlutterError(code: "NOLIDAR", message: "Need LiDAR", details: nil))
            return
        }
        // Reset everything
        for (_, n) in occluderNodes { n.removeFromParentNode() }
        occluderNodes.removeAll()
        for (_, w) in walls { w.node.removeFromParentNode() }
        walls.removeAll()
        undoStack.removeAll()
        isWallpaperApplied = false
        meshFrozen = false
        editModeActive = false
        exitLassoMode()
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
        // Stop mesh updates, keep tracking
        let plain = ARWorldTrackingConfiguration()
        plain.planeDetection = []
        plain.environmentTexturing = .automatic
        sceneView.session.run(plain, options: [])

        let area = totalWallArea()
        emit("scanComplete", data: ["totalWallArea": area, "meshSegments": walls.count])
        emit("boot", data: ["status": "Done: \(String(format: "%.1f", area)) m² · \(walls.count) walls"])
        result(nil)
    }

    private func totalWallArea() -> Float {
        var total: CGFloat = 0
        for (_, w) in walls {
            // Effective area = wall area × fraction of mask that is opaque
            // (cheap approximation: just count wall area; for exact we'd sample mask pixels)
            total += w.wallSizeMeters.width * w.wallSizeMeters.height
        }
        return Float(total)
    }

    // MARK: - Edit Mode

    private func enterEditMode() {
        editModeActive = true
        isWallpaperApplied = false
        refreshAllWallpaperMaterials()
        emit("boot", data: ["status": "Edit mode — brush or lasso"])
    }

    private func exitEditMode() {
        editModeActive = false
        exitLassoMode()
        refreshAllWallpaperMaterials()
        emit("selectionChanged", data: ["area": totalWallArea()])
    }

    // MARK: - Wall Creation / Update (from ARPlaneAnchor)

    /// Called when ARKit detects a new vertical plane (= wall)
    private func addWall(for anchor: ARPlaneAnchor, parent: SCNNode) {
        guard anchor.alignment == .vertical else { return }

        let widthM = CGFloat(anchor.planeExtent.width)
        let heightM = CGFloat(anchor.planeExtent.height)
        guard widthM > 0.3 && heightM > 0.3 else { return }  // ignore tiny patches

        // Build SCNPlane sized to detected wall
        let plane = SCNPlane(width: widthM, height: heightM)
        plane.cornerRadius = 0

        // Create initial mask: fully opaque (whole wall covered)
        let maskW = max(64, Int(widthM * maskPixelsPerMeter))
        let maskH = max(64, Int(heightM * maskPixelsPerMeter))
        let maskSize = CGSize(width: maskW, height: maskH)
        let mask = createOpaqueMask(size: maskSize)

        // Node
        let node = SCNNode(geometry: plane)
        // ARPlaneAnchor's center is in anchor space, must position relative to anchor
        node.simdPosition = anchor.center
        // ARPlaneAnchor is in anchor's local space — SCNPlane is XY, plane anchor is XZ
        // Rotate plane to lie on XZ (i.e., face along anchor's Y normal which is the wall's outward direction)
        // Actually ARSCNView positions SCNNode at the anchor's transform, and the anchor's local
        // up axis is the plane's normal. SCNPlane defaults to facing +Z, so rotate -90° around X
        // to make it face along the anchor's Y (= wall normal direction).
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        // Material with current wallpaper (or placeholder)
        let mat = buildWallpaperMaterial(maskImage: mask, wallWidthM: widthM, wallHeightM: heightM)
        plane.materials = [mat]

        parent.addChildNode(node)

        let state = WallState(
            anchorID: anchor.identifier,
            node: node,
            plane: plane,
            maskImage: mask,
            maskSize: maskSize,
            wallSizeMeters: CGSize(width: widthM, height: heightM)
        )
        walls[anchor.identifier] = state

        DispatchQueue.main.async { [weak self] in
            self?.emit("boot", data: ["status": "Wall added (\(self?.walls.count ?? 0))"])
        }
    }

    /// Called when ARKit refines an existing wall
    private func updateWall(for anchor: ARPlaneAnchor) {
        guard anchor.alignment == .vertical, !meshFrozen else { return }
        guard var state = walls[anchor.identifier] else { return }

        let newWidthM = CGFloat(anchor.planeExtent.width)
        let newHeightM = CGFloat(anchor.planeExtent.height)
        guard newWidthM > 0.3 && newHeightM > 0.3 else { return }

        // Only update if size changed meaningfully (>5cm)
        let oldW = state.wallSizeMeters.width
        let oldH = state.wallSizeMeters.height
        if abs(newWidthM - oldW) < 0.05 && abs(newHeightM - oldH) < 0.05 {
            // Just update position
            state.node.simdPosition = anchor.center
            walls[anchor.identifier] = state
            return
        }

        // Wall grew — resize plane and resize mask
        state.plane.width = newWidthM
        state.plane.height = newHeightM
        state.node.simdPosition = anchor.center

        let newMaskW = max(64, Int(newWidthM * maskPixelsPerMeter))
        let newMaskH = max(64, Int(newHeightM * maskPixelsPerMeter))
        let newMaskSize = CGSize(width: newMaskW, height: newMaskH)

        // Resize mask: composite old mask centered into a new opaque canvas
        let resizedMask = resizeMaskKeepingContent(
            oldMask: state.maskImage,
            oldWallSize: state.wallSizeMeters,
            newMaskSize: newMaskSize,
            newWallSize: CGSize(width: newWidthM, height: newHeightM)
        )

        state.maskImage = resizedMask
        state.maskSize = newMaskSize
        state.wallSizeMeters = CGSize(width: newWidthM, height: newHeightM)

        // Rebuild material with new size for tiling
        let mat = buildWallpaperMaterial(
            maskImage: resizedMask, wallWidthM: newWidthM, wallHeightM: newHeightM)
        state.plane.materials = [mat]

        walls[anchor.identifier] = state
    }

    private func removeWall(for anchor: ARPlaneAnchor) {
        guard let state = walls[anchor.identifier] else { return }
        state.node.removeFromParentNode()
        walls.removeValue(forKey: anchor.identifier)
    }

    // MARK: - Mask Bitmap Helpers (CGContext-based)

    private func createOpaqueMask(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func resizeMaskKeepingContent(
        oldMask: UIImage,
        oldWallSize: CGSize,
        newMaskSize: CGSize,
        newWallSize: CGSize
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: newMaskSize)
        return renderer.image { ctx in
            // Background = opaque white (new wall area defaults to "covered")
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: newMaskSize))

            // Composite old mask scaled to physical extent it occupied
            // Old wall was oldWallSize meters; new is newWallSize meters
            // Mask coords: same pixel-per-meter on both, so scale by ratio
            let pxPerMeterW = newMaskSize.width / newWallSize.width
            let pxPerMeterH = newMaskSize.height / newWallSize.height
            let drawW = oldWallSize.width * pxPerMeterW
            let drawH = oldWallSize.height * pxPerMeterH
            let drawX = (newMaskSize.width - drawW) / 2.0
            let drawY = (newMaskSize.height - drawH) / 2.0
            oldMask.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }
    }

    /// Paint a circle on a mask. Returns NEW image.
    /// alphaTarget: 1.0 = fully visible (paint), 0.0 = fully erased
    private func paintCircleOnMask(
        _ mask: UIImage, maskSize: CGSize,
        center: CGPoint, radiusPx: CGFloat, alphaTarget: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: maskSize, format: format)
        return renderer.image { ctx in
            // Draw existing mask
            mask.draw(in: CGRect(origin: .zero, size: maskSize))
            // Draw circle (erase or paint)
            let rect = CGRect(
                x: center.x - radiusPx, y: center.y - radiusPx,
                width: radiusPx * 2, height: radiusPx * 2)
            if alphaTarget < 0.5 {
                // ERASE: punch hole with destinationOut
                ctx.cgContext.setBlendMode(.destinationOut)
                ctx.cgContext.setFillColor(UIColor.black.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
            } else {
                // PAINT: fill opaque white
                ctx.cgContext.setBlendMode(.normal)
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: rect)
            }
        }
    }

    /// Fill a polygon on a mask. Returns NEW image.
    private func fillPolygonOnMask(
        _ mask: UIImage, maskSize: CGSize,
        polygon: [CGPoint], alphaTarget: CGFloat
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: maskSize, format: format)
        return renderer.image { ctx in
            mask.draw(in: CGRect(origin: .zero, size: maskSize))
            guard polygon.count >= 3 else { return }
            let path = UIBezierPath()
            path.move(to: polygon[0])
            for i in 1..<polygon.count { path.addLine(to: polygon[i]) }
            path.close()
            if alphaTarget < 0.5 {
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

    // MARK: - Wallpaper Material Builder

    private func buildWallpaperMaterial(maskImage: UIImage, wallWidthM: CGFloat, wallHeightM: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = false
        m.lightingModel = .physicallyBased
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.blendMode = .alpha

        // Tile the wallpaper texture across the wall based on roll width
        // SCNPlane's UV: (0,0) to (1,1) maps to the whole plane.
        // We want texture to tile so that each tile = rollWidth meters wide.
        let tilesX = max(1.0, wallWidthM / wallpaperRollWidth)
        let tilesY = max(1.0, wallHeightM / wallpaperRollWidth)
        let textureTransform = SCNMatrix4MakeScale(Float(tilesX), Float(tilesY), 1)

        if let albedo = wpAlbedo {
            m.diffuse.contents = albedo
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = textureTransform
        } else {
            // Placeholder color so user can see selection
            m.diffuse.contents = UIColor(red: 1.0, green: 0.83, blue: 0.41, alpha: 1.0)
            m.lightingModel = .constant
        }

        if let normal = wpNormal {
            m.normal.contents = normal
            m.normal.wrapS = .repeat
            m.normal.wrapT = .repeat
            m.normal.contentsTransform = textureTransform
            m.normal.intensity = 0.8
        }
        if let rough = wpRoughness {
            m.roughness.contents = rough
            m.roughness.wrapS = .repeat
            m.roughness.wrapT = .repeat
            m.roughness.contentsTransform = textureTransform
        }
        if let ao = wpAO {
            m.ambientOcclusion.contents = ao
            m.ambientOcclusion.wrapS = .repeat
            m.ambientOcclusion.wrapT = .repeat
            m.ambientOcclusion.contentsTransform = textureTransform
        }

        // THE KEY: mask is applied as transparency. The mask itself has razor-sharp edges
        // from CGContext drawing, so the wallpaper boundary is pixel-perfect.
        m.transparent.contents = maskImage
        // Mask is NOT tiled — it stretches exactly to wall extent
        m.transparent.wrapS = .clamp
        m.transparent.wrapT = .clamp

        // Apply global opacity
        m.transparency = (editModeActive && !isWallpaperApplied) ? wallpaperOpacity * 0.5 : wallpaperOpacity

        return m
    }

    private func refreshAllWallpaperMaterials() {
        for (_, state) in walls {
            let mat = buildWallpaperMaterial(
                maskImage: state.maskImage,
                wallWidthM: state.wallSizeMeters.width,
                wallHeightM: state.wallSizeMeters.height)
            state.plane.materials = [mat]
        }
    }

    private func refreshWallMaterial(for anchorID: UUID) {
        guard let state = walls[anchorID] else { return }
        let mat = buildWallpaperMaterial(
            maskImage: state.maskImage,
            wallWidthM: state.wallSizeMeters.width,
            wallHeightM: state.wallSizeMeters.height)
        state.plane.materials = [mat]
    }

    // MARK: - Brush

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard editModeActive else { return }
        guard snapshotImageView == nil else { return }  // disabled while lasso-frozen
        let screenPoint = gesture.location(in: sceneView)

        switch gesture.state {
        case .began:
            brushStrokeHadUndo = false
            lastBrushPanLocation = screenPoint
            applyBrushAt(screenPoint: screenPoint)
        case .changed:
            // Optionally interpolate between last and current to avoid gaps when finger moves fast
            if let last = lastBrushPanLocation {
                let dist = hypot(screenPoint.x - last.x, screenPoint.y - last.y)
                if dist > 4 {
                    let steps = max(1, Int(dist / 4))
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        let interp = CGPoint(
                            x: last.x + (screenPoint.x - last.x) * t,
                            y: last.y + (screenPoint.y - last.y) * t)
                        applyBrushAt(screenPoint: interp)
                    }
                }
            }
            lastBrushPanLocation = screenPoint
        case .ended, .cancelled:
            lastBrushPanLocation = nil
            emit("selectionChanged", data: ["area": totalWallArea()])
        default: break
        }
    }

    private func applyBrushAt(screenPoint: CGPoint) {
        // Raycast from screen point to find which wall + UV
        // Use SceneKit's hitTest against wall nodes
        let opts: [SCNHitTestOption: Any] = [
            .boundingBoxOnly: false,
            .searchMode: SCNHitTestSearchMode.closest.rawValue,
            .ignoreHiddenNodes: false
        ]
        let hits = sceneView.hitTest(screenPoint, options: opts)
        for hit in hits {
            // Walk up parent chain to find wall node
            var cur: SCNNode? = hit.node
            while let n = cur {
                if let anchorID = walls.first(where: { $0.value.node === n })?.key {
                    applyBrushHit(anchorID: anchorID, hit: hit)
                    return
                }
                cur = n.parent
            }
        }
    }

    private func applyBrushHit(anchorID: UUID, hit: SCNHitTestResult) {
        guard var state = walls[anchorID] else { return }

        // Save undo (one snapshot per stroke, when stroke begins)
        if !brushStrokeHadUndo {
            saveUndo(anchorID: anchorID, mask: state.maskImage)
            brushStrokeHadUndo = true
        }

        // hit.textureCoordinates gives UV on the plane (0..1).
        // SCNPlane texCoord: (0,0) bottom-left.
        let uv = hit.textureCoordinates(withMappingChannel: 0)
        let maskW = state.maskSize.width
        let maskH = state.maskSize.height
        // UIImage origin is top-left; UV origin (0,0) is bottom-left of plane → flip Y
        let px = uv.x * maskW
        let py = (1.0 - uv.y) * maskH

        // Brush radius in mask pixels = brushRadiusMeters × pxPerMeter
        let pxPerMeter = maskW / state.wallSizeMeters.width
        let radiusPx = CGFloat(brushRadiusMeters) * pxPerMeter

        let alphaTarget: CGFloat = (brushMode == .erase) ? 0.0 : 1.0
        let newMask = paintCircleOnMask(
            state.maskImage, maskSize: state.maskSize,
            center: CGPoint(x: px, y: py),
            radiusPx: radiusPx,
            alphaTarget: alphaTarget)

        state.maskImage = newMask
        walls[anchorID] = state
        refreshWallMaterial(for: anchorID)
    }

    // MARK: - Lasso (freeze view + polygon fill)

    private func enterLassoMode() {
        let work: () -> Void = { [weak self] in
            guard let self = self else { return }
            // Take snapshot for visual freeze
            let snapshot = self.sceneView.snapshot()
            let imageView = UIImageView(frame: self.sceneView.bounds)
            imageView.image = snapshot
            imageView.contentMode = .scaleAspectFill
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.isUserInteractionEnabled = false
            self.sceneView.addSubview(imageView)
            self.snapshotImageView = imageView
            self.emit("boot", data: ["status": "Lasso frozen ✓"])
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private func exitLassoMode() {
        let work: () -> Void = { [weak self] in
            self?.snapshotImageView?.removeFromSuperview()
            self?.snapshotImageView = nil
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    private func applyLasso(screenPoints: [[Double]], mode: String) {
        guard screenPoints.count >= 3 else { return }
        let polygonScreen = screenPoints.map { CGPoint(x: $0[0], y: $0[1]) }
        let isErase = (mode == "erase")
        let alphaTarget: CGFloat = isErase ? 0.0 : 1.0

        // For each wall, project the polygon screen points to wall UV coords,
        // then fill the mask polygon. Each polygon vertex is projected by raycasting
        // from screen point to find UV intersection with the wall plane.
        //
        // Approach: for each polygon point, raycast against the scene. For each wall,
        // build a UV polygon. If a polygon point doesn't hit a given wall, we still
        // need to handle it — but the simplest robust approach is: for each wall,
        // project EACH world-space corner of the wall to screen and check polygon
        // containment per-pixel. But that's slow.
        //
        // Better: for each wall plane, transform polygon screen points → plane UV
        // by projecting screen ray onto the wall's plane. This handles all polygon
        // points consistently per-wall, even ones that didn't originally hit that wall.
        //
        // We need: world position of polygon point ON the wall's plane.
        // Use: unprojectPoint at depth that lies on the plane.

        guard let frame = sceneView.session.currentFrame else { return }

        for (anchorID, var state) in walls {
            // Get wall transform: anchor transform * node local transform
            // The node is positioned at anchor.center and rotated -90° around X.
            // The world transform of the node gives us the wall plane in world space.
            let nodeWorldTransform = state.node.simdWorldTransform
            // Plane normal = node's local +Z transformed to world
            // After rotation -90° around X, local +Z becomes world's +Y direction in plane frame.
            // Actually SCNNode.simdWorldTransform's columns: 0=right, 1=up, 2=forward
            // Plane normal = column 2 (the local +Z direction in world space)
            let planeNormal = SIMD3<Float>(nodeWorldTransform.columns.2.x,
                                            nodeWorldTransform.columns.2.y,
                                            nodeWorldTransform.columns.2.z)
            let planeOrigin = SIMD3<Float>(nodeWorldTransform.columns.3.x,
                                            nodeWorldTransform.columns.3.y,
                                            nodeWorldTransform.columns.3.z)

            // Project each polygon screen point onto this wall's plane in world space.
            // Then transform that world point into the wall's local UV.
            var uvPolygon: [CGPoint] = []
            uvPolygon.reserveCapacity(polygonScreen.count)
            var anyHit = false
            for sp in polygonScreen {
                guard let (worldPt, hit) = projectScreenOntoPlane(
                    screenPoint: sp,
                    planeOrigin: planeOrigin,
                    planeNormal: planeNormal,
                    frame: frame
                ) else { continue }
                if hit { anyHit = true }
                // Convert world point to plane's local UV
                let worldH = SIMD4<Float>(worldPt.x, worldPt.y, worldPt.z, 1.0)
                let invWorld = simd_inverse(nodeWorldTransform)
                let localPt = invWorld * worldH
                // localPt.x = horizontal across plane (-w/2 to +w/2)
                // localPt.y = vertical (-h/2 to +h/2)
                let wallW = state.wallSizeMeters.width
                let wallH = state.wallSizeMeters.height
                let u = (CGFloat(localPt.x) + wallW / 2) / wallW
                let v = (CGFloat(localPt.y) + wallH / 2) / wallH
                // Convert UV → mask pixel coords (mask Y flipped from UV)
                let px = u * state.maskSize.width
                let py = (1 - v) * state.maskSize.height
                uvPolygon.append(CGPoint(x: px, y: py))
            }
            guard !uvPolygon.isEmpty, anyHit else { continue }

            saveUndo(anchorID: anchorID, mask: state.maskImage)
            let newMask = fillPolygonOnMask(
                state.maskImage,
                maskSize: state.maskSize,
                polygon: uvPolygon,
                alphaTarget: alphaTarget)
            state.maskImage = newMask
            walls[anchorID] = state
            refreshWallMaterial(for: anchorID)
        }

        exitLassoMode()
        emit("selectionChanged", data: ["area": totalWallArea()])
        emit("boot", data: ["status": "Lasso applied ✅"])
    }

    /// Project a screen point onto an arbitrary plane in world space.
    /// Returns the world-space hit point, plus a flag indicating whether the ray genuinely
    /// hit "in front of" the camera (sanity flag).
    private func projectScreenOntoPlane(
        screenPoint: CGPoint,
        planeOrigin: SIMD3<Float>,
        planeNormal: SIMD3<Float>,
        frame: ARFrame
    ) -> (SIMD3<Float>, Bool)? {
        // Get ray from camera through screen point
        let viewportSize = sceneView.bounds.size
        let cameraTransform = frame.camera.transform
        let projMatrix = frame.camera.projectionMatrix(
            for: .portrait, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)

        // NDC point
        let ndcX = Float((screenPoint.x / viewportSize.width) * 2 - 1)
        let ndcY = Float(-((screenPoint.y / viewportSize.height) * 2 - 1))

        // Inverse projection × inverse view to get world ray
        let invProj = simd_inverse(projMatrix)
        let invView = cameraTransform  // camera transform = view inverse

        let nearClip = SIMD4<Float>(ndcX, ndcY, -1, 1)
        let farClip = SIMD4<Float>(ndcX, ndcY, 1, 1)
        let nearView = invProj * nearClip
        let farView = invProj * farClip
        let nearWorld4 = invView * (nearView / nearView.w)
        let farWorld4 = invView * (farView / farView.w)
        let nearWorld = SIMD3<Float>(nearWorld4.x, nearWorld4.y, nearWorld4.z)
        let farWorld = SIMD3<Float>(farWorld4.x, farWorld4.y, farWorld4.z)

        let rayDir = simd_normalize(farWorld - nearWorld)
        let rayOrigin = nearWorld

        // Ray-plane intersection
        let denom = simd_dot(planeNormal, rayDir)
        guard abs(denom) > 1e-6 else { return nil }
        let t = simd_dot(planeOrigin - rayOrigin, planeNormal) / denom
        guard t > 0 else { return (rayOrigin, false) }
        let hitPoint = rayOrigin + rayDir * t
        return (hitPoint, true)
    }

    // MARK: - Undo / Reset

    private func saveUndo(anchorID: UUID, mask: UIImage) {
        undoStack.append((anchorID, mask))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
    }

    private func undoLast() {
        guard let last = undoStack.popLast() else {
            emit("boot", data: ["status": "Nothing to undo"])
            return
        }
        guard var state = walls[last.0] else { return }
        state.maskImage = last.1
        walls[last.0] = state
        refreshWallMaterial(for: last.0)
        emit("boot", data: ["status": "Undo ✅"])
        emit("selectionChanged", data: ["area": totalWallArea()])
    }

    private func resetAllMasks() {
        for (id, var state) in walls {
            state.maskImage = createOpaqueMask(size: state.maskSize)
            walls[id] = state
            refreshWallMaterial(for: id)
        }
        undoStack.removeAll()
        emit("selectionChanged", data: ["area": totalWallArea()])
        emit("boot", data: ["status": "Reset"])
    }

    // MARK: - Place / Clear Wallpaper

    private func placeWallpaper(_ args: [String: Any]?, result: @escaping FlutterResult) {
        guard let args = args, let url = args["albedoUrl"] as? String, !url.isEmpty else {
            emit("wallpaperPlaced", data: ["success": false, "message": "No URL"])
            result(nil)
            return
        }
        let nU = args["normalUrl"] as? String ?? ""
        let rU = args["roughnessUrl"] as? String ?? ""
        let aU = args["aoUrl"] as? String ?? ""
        let wI = args["wallIndex"] as? Int ?? 0
        if let rw = args["rollWidth"] as? Double, rw > 0.1 {
            wallpaperRollWidth = CGFloat(rw)
        }

        emit("boot", data: ["status": "Loading textures..."])
        let g = DispatchGroup()
        var a: UIImage?, n: UIImage?, r: UIImage?, o: UIImage?
        g.enter(); textureCache.loadImage(from: url) { a = $0; g.leave() }
        if !nU.isEmpty { g.enter(); textureCache.loadImage(from: nU) { n = $0; g.leave() } }
        if !rU.isEmpty { g.enter(); textureCache.loadImage(from: rU) { r = $0; g.leave() } }
        if !aU.isEmpty { g.enter(); textureCache.loadImage(from: aU) { o = $0; g.leave() } }

        g.notify(queue: .main) { [weak self] in
            guard let self = self, let albedo = a else {
                self?.emit("wallpaperPlaced", data: ["wallIndex": wI, "success": false])
                result(nil)
                return
            }
            self.wpAlbedo = albedo
            self.wpNormal = n
            self.wpRoughness = r
            self.wpAO = o
            self.isWallpaperApplied = true
            self.editModeActive = false
            self.exitLassoMode()
            self.refreshAllWallpaperMaterials()
            self.emit("wallpaperPlaced", data: [
                "wallIndex": wI,
                "success": true,
                "area": self.totalWallArea()
            ])
            self.emit("boot", data: ["status": "Wallpaper applied ✅"])
            result(nil)
        }
    }

    private func clearWallpaper() {
        isWallpaperApplied = false
        wpAlbedo = nil; wpNormal = nil; wpRoughness = nil; wpAO = nil
        refreshAllWallpaperMaterials()
        emit("wallCleared", data: ["wallIndex": 0])
    }

    // MARK: - Events

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
    func session(_ session: ARSession, didUpdate frame: ARFrame) {}

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical {
            DispatchQueue.main.async { [weak self] in
                self?.addWall(for: plane, parent: node)
            }
        } else if let mesh = anchor as? ARMeshAnchor, !meshFrozen, currentMode == .scanning {
            // LiDAR occluder — invisible, depth-only
            guard let geo = buildOccluderGeometry(from: mesh) else { return }
            let occNode = SCNNode(geometry: geo)
            // Render order: very early, so depth is set before walls render
            occNode.renderingOrder = -100
            node.addChildNode(occNode)
            DispatchQueue.main.async { [weak self] in
                self?.occluderNodes[mesh.identifier] = occNode
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        if let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical {
            DispatchQueue.main.async { [weak self] in
                self?.updateWall(for: plane)
            }
        } else if let mesh = anchor as? ARMeshAnchor, !meshFrozen, currentMode == .scanning {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let n = self.occluderNodes[mesh.identifier],
                      let g = self.buildOccluderGeometry(from: mesh) else { return }
                n.geometry = g
            }
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let plane = anchor as? ARPlaneAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.removeWall(for: plane)
            }
        } else if let mesh = anchor as? ARMeshAnchor {
            DispatchQueue.main.async { [weak self] in
                self?.occluderNodes[mesh.identifier]?.removeFromParentNode()
                self?.occluderNodes.removeValue(forKey: mesh.identifier)
            }
        }
    }

    /// Build a depth-only invisible geometry from a LiDAR mesh anchor.
    /// This will sit in the scene as a depth occluder — wallpaper behind objects gets hidden.
    private func buildOccluderGeometry(from anchor: ARMeshAnchor) -> SCNGeometry? {
        let geo = anchor.geometry
        guard geo.vertices.count > 0, geo.faces.count > 0 else { return nil }
        // We skip wall-classified faces — only non-wall surfaces should occlude
        // (otherwise the wall mesh itself occludes the wallpaper plane).
        let cOpt = geo.classification
        let fEl = geo.faces
        let bpi = fEl.bytesPerIndex
        let ipf = fEl.indexCountPerPrimitive

        // Extract vertices
        let vSrc = geo.vertices
        var verts = [SCNVector3]()
        verts.reserveCapacity(vSrc.count)
        for i in 0..<vSrc.count {
            let p = vSrc.buffer.contents()
                .advanced(by: vSrc.offset + vSrc.stride * i)
                .assumingMemoryBound(to: SIMD3<Float>.self).pointee
            verts.append(SCNVector3(p.x, p.y, p.z))
        }

        // Collect faces that are NOT walls (these become occluders)
        var indices: [UInt32] = []
        for f in 0..<fEl.count {
            var isWall = false
            if let c = cOpt {
                let cv = c.buffer.contents()
                    .advanced(by: c.offset + c.stride * f)
                    .assumingMemoryBound(to: UInt8.self).pointee
                isWall = (ARMeshClassification(rawValue: Int(cv)) == .wall)
            }
            if isWall { continue }  // skip walls — let ARPlaneAnchor handle them
            for j in 0..<ipf {
                let p = fEl.buffer.contents()
                    .advanced(by: (f * ipf + j) * bpi)
                if bpi == 4 {
                    indices.append(p.assumingMemoryBound(to: UInt32.self).pointee)
                } else {
                    indices.append(UInt32(p.assumingMemoryBound(to: UInt16.self).pointee))
                }
            }
        }
        guard !indices.isEmpty else { return nil }

        let vertSrc = SCNGeometrySource(vertices: verts)
        let idxData = Data(bytes: indices, count: indices.count * 4)
        let element = SCNGeometryElement(
            data: idxData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: 4)

        let geom = SCNGeometry(sources: [vertSrc], elements: [element])
        geom.materials = [occluderMaterial]
        return geom
    }
}

// MARK: - UIColor Hex

extension UIColor {
    convenience init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let sc = Scanner(string: s)
        var n: UInt64 = 0
        guard sc.scanHexInt64(&n) else { return nil }
        switch s.count {
        case 8:
            self.init(red: CGFloat((n>>24)&0xff)/255,
                      green: CGFloat((n>>16)&0xff)/255,
                      blue: CGFloat((n>>8)&0xff)/255,
                      alpha: CGFloat(n&0xff)/255)
        case 6:
            self.init(red: CGFloat((n>>16)&0xff)/255,
                      green: CGFloat((n>>8)&0xff)/255,
                      blue: CGFloat(n&0xff)/255,
                      alpha: 1.0)
        default: return nil
        }
    }
}
