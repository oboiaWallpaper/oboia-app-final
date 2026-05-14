// RoomScanner.swift — FIXED: no ARSession conflict, no delegate stealing
// Drop-in replacement — put in ios/Runner/RoomScanner.swift

import RoomPlan
import ARKit
import SceneKit

struct DetectedSurface: Codable {
    let id: String
    let type: String
    let width: Float
    let height: Float
    let area: Float
    var excluded: Bool = false
}

struct ScanSnapshot: Codable {
    let surfaces: [DetectedSurface]
    let objects: [DetectedObject]
}

struct DetectedObject: Codable {
    let id: String
    let type: String
    var excluded: Bool = false
}

@available(iOS 17.0, *)
final class RoomScanner: NSObject {

    private weak var arView: ARSCNView?
    private var eventSink: ((Any) -> Void)?

    private var captureSession: RoomCaptureSession?
    private var roomBuilder: RoomBuilder?

    private var isScanning = false
    private var lastUpdateTime: TimeInterval = 0
    private let updateDebounce: TimeInterval = 0.5

    private var currentSurfaces: [DetectedSurface] = []
    private var currentObjects: [DetectedObject] = []

    init(arView: ARSCNView?, messenger: FlutterBinaryMessenger?) {
        self.arView = arView
        super.init()
    }

    func setEventSink(_ sink: @escaping (Any) -> Void) {
        eventSink = sink
    }

    // MARK: - Start Scan

    func start() {
        guard !isScanning else { return }

        // ═══════════════════════════════════════════════════════════
        // CRITICAL CHECK: RoomPlan requires LiDAR hardware
        // ═══════════════════════════════════════════════════════════
        guard RoomCaptureSession.isSupported else {
            print("❌ RoomPlan NOT supported on this device")
            eventSink?(["type": "error", "data": ["message": "RoomPlan not supported (LiDAR required)"]])
            return
        }
        print("✅ RoomPlan IS supported on this device")

        isScanning = true
        currentSurfaces = []
        currentObjects = []

        // ═══════════════════════════════════════════════════════════
        // STEP 1: Pause the existing AR session BEFORE creating RoomPlan
        // iOS only allows ONE active ARSession. If we don't pause first,
        // the old session and RoomPlan's internal session fight each other
        // and RoomPlan silently receives zero events.
        // ═══════════════════════════════════════════════════════════
        if let arView = arView {
            arView.session.pause()
            print("✅ Paused existing ARSession")
        }

        // ═══════════════════════════════════════════════════════════
        // STEP 2: Create RoomCaptureSession and set delegate BEFORE run
        // ═══════════════════════════════════════════════════════════
        let session = RoomCaptureSession()
        session.delegate = self
        print("✅ RoomCaptureSession delegate set")

        roomBuilder = RoomBuilder(options: [])
        self.captureSession = session

        // ═══════════════════════════════════════════════════════════
        // STEP 3: Assign RoomPlan's ARSession to the view for camera feed
        //
        // DO NOT set arView.session.delegate = self
        // RoomPlan MUST remain the internal delegate of its own ARSession.
        // Stealing the delegate is what caused zero events.
        // ═══════════════════════════════════════════════════════════
        if let arView = arView {
            arView.session = session.arSession
            // arView.session.delegate = self   ← REMOVED — this was the bug
            arView.automaticallyUpdatesLighting = true
            print("✅ Assigned RoomPlan ARSession to ARSCNView")
        }

        // ═══════════════════════════════════════════════════════════
        // STEP 4: Configure and run
        // ═══════════════════════════════════════════════════════════
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = false
        session.run(configuration: config)
        print("✅ RoomCaptureSession.run() called")

        eventSink?(["type": "boot", "data": ["status": "RoomPlan scan active"]])
    }

    // MARK: - Stop Scan

    func stop(completion: @escaping (ScanSnapshot?) -> Void) {
        guard isScanning else {
            completion(nil)
            return
        }
        isScanning = false

        guard let session = captureSession else {
            completion(nil)
            return
        }

        session.stop()
        print("✅ RoomCaptureSession stopped")

        roomBuilder = nil

        let finalSnapshot = ScanSnapshot(surfaces: currentSurfaces, objects: currentObjects)
        completion(finalSnapshot)

        self.captureSession = nil
        // DO NOT touch arView.session.delegate here
        // The caller (WallpaperARView) will restore its own ARSession
    }

    // MARK: - Surface/Object Exclusion

    func toggleSurfaceExclusion(id: String) -> Bool? {
        guard let idx = currentSurfaces.firstIndex(where: { $0.id == id }) else { return nil }
        currentSurfaces[idx].excluded.toggle()
        emitUpdate()
        return currentSurfaces[idx].excluded
    }

    func toggleObjectExclusion(id: String) -> Bool? {
        guard let idx = currentObjects.firstIndex(where: { $0.id == id }) else { return nil }
        currentObjects[idx].excluded.toggle()
        emitUpdate()
        return currentObjects[idx].excluded
    }

    // MARK: - Process Room Data

    private func processRoom(_ capturedRoom: CapturedRoom) {
        var surfaces: [DetectedSurface] = []
        var objects: [DetectedObject] = []

        for wall in capturedRoom.walls {
            let id = wall.identifier.uuidString
            let w = wall.dimensions.x
            let h = wall.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "wall", width: w, height: h, area: w * h))
        }
        for door in capturedRoom.doors {
            let id = door.identifier.uuidString
            let w = door.dimensions.x
            let h = door.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "door", width: w, height: h, area: w * h))
        }
        for window in capturedRoom.windows {
            let id = window.identifier.uuidString
            let w = window.dimensions.x
            let h = window.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "window", width: w, height: h, area: w * h))
        }
        for opening in capturedRoom.openings {
            let id = opening.identifier.uuidString
            let w = opening.dimensions.x
            let h = opening.dimensions.y
            surfaces.append(DetectedSurface(id: id, type: "opening", width: w, height: h, area: w * h))
        }
        for obj in capturedRoom.objects {
            let id = obj.identifier.uuidString
            let category: String
            switch obj.category {
            case .storage: category = "storage"
            case .table: category = "table"
            case .sofa: category = "sofa"
            case .chair: category = "chair"
            case .bed: category = "bed"
            case .television: category = "television"
            case .bathtub: category = "bathtub"
            case .toilet: category = "toilet"
            case .sink: category = "sink"
            case .refrigerator: category = "refrigerator"
            case .stove: category = "stove"
            case .washerDryer: category = "washerDryer"
            case .fireplace: category = "fireplace"
            default: category = "unknown"
            }
            objects.append(DetectedObject(id: id, type: category))
        }

        let wallCount = surfaces.filter { $0.type == "wall" }.count
        let doorCount = surfaces.filter { $0.type == "door" }.count
        let windowCount = surfaces.filter { $0.type == "window" }.count
        print("📐 RoomPlan update: \(wallCount) walls, \(doorCount) doors, \(windowCount) windows, \(objects.count) objects")

        self.currentSurfaces = surfaces
        self.currentObjects = objects
    }

    // MARK: - Emit Updates to Dart

    private func emitUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.emitUpdate() }
            return
        }
        let snapshot = ScanSnapshot(surfaces: currentSurfaces, objects: currentObjects)
        if let jsonData = try? JSONEncoder().encode(snapshot),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            eventSink?(["type": "scanUpdate", "data": ["data": jsonString]])
        }
    }
}

// MARK: - RoomCaptureSessionDelegate

@available(iOS 17.0, *)
extension RoomScanner: RoomCaptureSessionDelegate {

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        print("✅ RoomPlan didStartWith fired — scanning is LIVE")
        eventSink?(["type": "boot", "data": ["status": "RoomPlan scanning live"]])
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        print("📐 RoomPlan didUpdate fired")
        let now = CACurrentMediaTime()
        guard now - lastUpdateTime > updateDebounce else { return }
        lastUpdateTime = now
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        print("📐 RoomPlan didAdd fired")
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        print("📐 RoomPlan didChange fired")
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        print("📐 RoomPlan didRemove fired")
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error = error {
            print("❌ RoomPlan ended with error: \(error.localizedDescription)")
            eventSink?(["type": "scanFailed", "data": ["message": error.localizedDescription]])
        } else {
            print("✅ RoomPlan ended successfully")
            eventSink?(["type": "scanComplete", "data": ["status": "ok"]])
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let instructionStr = "\(instruction)"
        print("💡 RoomPlan instruction: \(instructionStr)")
        eventSink?(["type": "scanInstruction", "data": ["instruction": instructionStr]])
    }
}

// ═══════════════════════════════════════════════════════════
// NOTE: ARSessionDelegate conformance has been REMOVED.
// RoomPlan must be the sole controller of its own ARSession.
// WallpaperARView handles ARSessionDelegate for preview mode.
// ═══════════════════════════════════════════════════════════
