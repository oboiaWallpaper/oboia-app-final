// RoomScanner.swift — DIAGNOSTIC VERSION v2
// Every step reports to status overlay — no Xcode needed
// Replace: ios/Runner/RoomScanner.swift

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
        guard !isScanning else {
            emitBoot("start() skipped — already scanning")
            return
        }

        // Report device info
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        emitBoot("iOS \(iosVersion) | \(deviceModel)")

        // Check RoomPlan support
        let supported = RoomCaptureSession.isSupported
        emitBoot("RoomPlan supported: \(supported)")

        guard supported else {
            emitError("RoomPlan NOT supported on this device")
            return
        }

        isScanning = true
        currentSurfaces = []
        currentObjects = []

        // STEP 1: Pause existing AR session
        if let arView = arView {
            arView.session.pause()
            emitBoot("1/4 Paused old ARSession")
        } else {
            emitBoot("1/4 WARNING: arView is nil!")
        }

        // STEP 2: Create session + set delegate
        let session = RoomCaptureSession()
        session.delegate = self
        roomBuilder = RoomBuilder(options: [])
        self.captureSession = session
        emitBoot("2/4 Session created, delegate set")

        // STEP 3: Give RoomPlan's ARSession to the view (camera feed)
        // DO NOT set arView.session.delegate — that kills RoomPlan
        if let arView = arView {
            arView.session = session.arSession
            arView.automaticallyUpdatesLighting = true
            emitBoot("3/4 RoomPlan session assigned to view")
        }

        // STEP 4: Run
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = false
        session.run(configuration: config)
        emitBoot("4/4 session.run() called — waiting for delegates...")
    }

    // MARK: - Stop Scan

    func stop(completion: @escaping (ScanSnapshot?) -> Void) {
        guard isScanning else { completion(nil); return }
        isScanning = false

        guard let session = captureSession else { completion(nil); return }

        session.stop()
        roomBuilder = nil

        let finalSnapshot = ScanSnapshot(surfaces: currentSurfaces, objects: currentObjects)
        emitBoot("Stopped: \(currentSurfaces.count) surfaces found")
        completion(finalSnapshot)

        self.captureSession = nil
    }

    // MARK: - Exclusion

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

    // MARK: - Process Room

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

        self.currentSurfaces = surfaces
        self.currentObjects = objects
    }

    // MARK: - Emit Helpers

    private func emitBoot(_ message: String) {
        print("🔵 RoomScanner: \(message)")
        eventSink?(["type": "boot", "data": ["status": message]])
    }

    private func emitError(_ message: String) {
        print("❌ RoomScanner: \(message)")
        eventSink?(["type": "error", "data": ["message": message]])
    }

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
        emitBoot("🟢 DELEGATE: didStartWith — SCANNING IS LIVE!")
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let wallCount = room.walls.count
        let doorCount = room.doors.count
        emitBoot("🟢 didUpdate: \(wallCount)w \(doorCount)d")

        let now = CACurrentMediaTime()
        guard now - lastUpdateTime > updateDebounce else { return }
        lastUpdateTime = now
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        emitBoot("🟢 didAdd: \(room.walls.count) walls")
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        emitBoot("🟢 didChange")
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        emitBoot("🟢 didRemove")
        processRoom(room)
        emitUpdate()
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error = error {
            emitError("didEndWith ERROR: \(error.localizedDescription)")
        } else {
            emitBoot("🟢 didEndWith — success")
        }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        emitBoot("💡 \(instruction)")
        eventSink?(["type": "scanInstruction", "data": ["instruction": "\(instruction)"]])
    }
}
