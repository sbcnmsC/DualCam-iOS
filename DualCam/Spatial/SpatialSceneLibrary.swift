import Foundation
import SwiftUI

struct SpatialSceneRecord: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let createdAt: Date
    let directoryName: String
    let previewFilename: String
    let standardPLYFilename: String?
    let spzFilename: String?
    let frameCount: Int
    let gaussianCount: Int

    var formattedDate: String {
        Self.dateFormatter.string(from: createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Persistent in-app library for generated 3D scenes. Only the compact preview/export files
/// and capture manifest are copied; large RGB/depth training source frames stay in the capture
/// workspace and are not duplicated into the user's saved album.
final class SpatialSceneLibrary: ObservableObject {
    static let shared = SpatialSceneLibrary()

    @Published private(set) var scenes: [SpatialSceneRecord] = []

    private let defaultsKey = "DualCam.SpatialSceneLibrary.v1"
    private let queue = DispatchQueue(label: "dualcam.spatial.library", qos: .utility)
    private let fileManager = FileManager.default

    private init() {
        reload()
    }

    func reload() {
        let loaded: [SpatialSceneRecord]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SpatialSceneRecord].self, from: data) {
            loaded = decoded.filter { record in
                fileManager.fileExists(atPath: sceneDirectory(for: record).appendingPathComponent(record.previewFilename).path)
            }
        } else {
            loaded = []
        }
        scenes = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func previewURL(for record: SpatialSceneRecord) -> URL {
        sceneDirectory(for: record).appendingPathComponent(record.previewFilename)
    }

    func standardPLYURL(for record: SpatialSceneRecord) -> URL? {
        guard let name = record.standardPLYFilename else { return nil }
        let url = sceneDirectory(for: record).appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func spzURL(for record: SpatialSceneRecord) -> URL? {
        guard let name = record.spzFilename else { return nil }
        let url = sceneDirectory(for: record).appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func saveScene(
        previewPLY: URL,
        standardPLY: URL? = nil,
        spz: URL? = nil,
        completion: @escaping (Result<SpatialSceneRecord, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard self.fileManager.fileExists(atPath: previewPLY.path) else {
                    throw SpatialSceneLibraryError.previewMissing
                }

                let documents = try self.fileManager.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let root = documents.appendingPathComponent("DualCam3DScenes", isDirectory: true)
                try self.fileManager.createDirectory(at: root, withIntermediateDirectories: true)

                let identifier = UUID().uuidString
                let folder = root.appendingPathComponent(identifier, isDirectory: true)
                try self.fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

                let previewName = "preview.ply"
                try self.fileManager.copyItem(
                    at: previewPLY,
                    to: folder.appendingPathComponent(previewName)
                )

                var standardName: String?
                if let standardPLY,
                   self.fileManager.fileExists(atPath: standardPLY.path),
                   standardPLY.standardizedFileURL != previewPLY.standardizedFileURL {
                    standardName = "scene.ply"
                    try self.fileManager.copyItem(
                        at: standardPLY,
                        to: folder.appendingPathComponent(standardName!)
                    )
                } else {
                    standardName = previewName
                }

                var spzName: String?
                if let spz, self.fileManager.fileExists(atPath: spz.path) {
                    spzName = "scene.spz"
                    try self.fileManager.copyItem(at: spz, to: folder.appendingPathComponent(spzName!))
                }

                let captureFolder = previewPLY.deletingLastPathComponent()
                let sessionURL = captureFolder.appendingPathComponent("session.json")
                var frameCount = 0
                var gaussianCount = 0
                if self.fileManager.fileExists(atPath: sessionURL.path) {
                    try self.fileManager.copyItem(at: sessionURL, to: folder.appendingPathComponent("session.json"))
                    if let data = try? Data(contentsOf: sessionURL),
                       let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        frameCount = manifest["frameCount"] as? Int ?? 0
                        gaussianCount = manifest["gaussianSeedCount"] as? Int ?? 0
                    }
                }

                let record = SpatialSceneRecord(
                    id: identifier,
                    title: "3D 场景 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
                    createdAt: Date(),
                    directoryName: identifier,
                    previewFilename: previewName,
                    standardPLYFilename: standardName,
                    spzFilename: spzName,
                    frameCount: frameCount,
                    gaussianCount: gaussianCount
                )

                let metadata = try JSONEncoder().encode(record)
                try metadata.write(to: folder.appendingPathComponent("scene.json"), options: .atomic)

                DispatchQueue.main.async {
                    self.scenes.insert(record, at: 0)
                    self.persist()
                    completion(.success(record))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func delete(_ record: SpatialSceneRecord) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: self.sceneDirectory(for: record))
            DispatchQueue.main.async {
                self.scenes.removeAll { $0.id == record.id }
                self.persist()
            }
        }
    }

    private func sceneDirectory(for record: SpatialSceneRecord) -> URL {
        let documents = (try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return documents
            .appendingPathComponent("DualCam3DScenes", isDirectory: true)
            .appendingPathComponent(record.directoryName, isDirectory: true)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(scenes) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private enum SpatialSceneLibraryError: LocalizedError {
        case previewMissing

        var errorDescription: String? {
            "找不到 3D 场景预览文件，请重新采集后再保存。"
        }
    }
}

struct SpatialCaptureResultView: View {
    let previewURL: URL

    @StateObject private var training = GaussianTrainingManager()
    @State private var selectedViewerURL: URL
    @State private var isSaving = false
    @State private var isSaved = false
    @State private var saveError: String?

    init(previewURL: URL) {
        self.previewURL = previewURL
        _selectedViewerURL = State(initialValue: previewURL)
    }

    var body: some View {
        ZStack {
            GaussianSplatViewerScreen(
                url: selectedViewerURL,
                onSave: training.isWorking ? nil : saveToAlbum,
                isSaved: isSaved,
                isSaving: isSaving
            )
            .id(selectedViewerURL)

            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    Menu {
                        Button("快速优化 · 1K") { startTraining(iterations: 1_000) }
                        Button("均衡优化 · 2K") { startTraining(iterations: 2_000) }
                        Button("高质量优化 · 4K") { startTraining(iterations: 4_000) }
                    } label: {
                        Label(
                            training.isWorking ? "正在优化" : "Gaussian 优化",
                            systemImage: training.isWorking ? "cpu" : "sparkles"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(training.isWorking || training.phase == .loading)
                }
                Spacer(minLength: 0)
                if training.isWorking || training.phase == .failed("待处理") {
                    trainingProgressPanel
                } else if case .failed(let message) = training.phase {
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else if training.phase == .finished {
                    Label("Gaussian 优化完成", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 66)
            .padding(.bottom, 164)
        }
        .alert("保存 3D 场景", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .onChange(of: training.previewPLY) { _, newURL in
            guard let newURL else { return }
            selectedViewerURL = newURL
        }
    }

    private var trainingProgressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(training.status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("停止") {
                    training.cancelTraining()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            }
            ProgressView(value: training.progress)
                .tint(.cyan)
            HStack {
                Text("\(training.iteration) / \(training.totalIterations) 步")
                Spacer()
                Text("\(training.availableMemoryMB) MB 可用")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.68))
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func startTraining(iterations: Int) {
        guard !training.isWorking else { return }
        isSaved = false
        training.iterationTarget = iterations
        training.startTraining(datasetURL: previewURL.deletingLastPathComponent())
    }

    private func saveToAlbum() {
        guard !isSaving, !isSaved, !training.isWorking else { return }
        isSaving = true
        SpatialSceneLibrary.shared.saveScene(
            previewPLY: selectedViewerURL,
            standardPLY: training.exportedPLY,
            spz: training.exportedSPZ
        ) { result in
            isSaving = false
            switch result {
            case .success:
                isSaved = true
                HapticFeedback.play(.selection)
            case .failure(let error):
                saveError = error.localizedDescription
            }
        }
    }
}
