import SwiftUI
import UIKit
import Photos

/// Private, app-owned creative workspace. It intentionally does not query or write to Photos.
struct CreativeGalleryView: View {
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var tab: WorkspaceTab = .library
    @State private var selectedURL: URL?
    @State private var selectedForBatch: Set<String> = []
    @State private var selectionMode = false
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var showingDeleteConfirm = false
    @State private var compareFilter: String?
    @State private var detailItem: GalleryDetailItem?
    @State private var exportAlert = false
    @State private var exportMessage = ""

    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.065).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                tabBar
                Group {
                    switch tab {
                    case .library: library
                    case .compare: compare
                    case .settings: settings
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingShare) {
            GalleryShareSheet(items: shareItems)
                .ignoresSafeArea()
        }
        .sheet(item: $detailItem) { item in
            PhotoDetailSheet(url: item.url, onShare: { share([item.url]) }, onExport: { exportToSystemPhotos([item.url]) }, onDelete: {
                cam.deleteCompositePhoto(item.url)
                detailItem = nil
            })
            .presentationBackground(.black)
        }
        .alert("系统照片图库", isPresented: $exportAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportMessage)
        }
        .confirmationDialog("删除所选作品？", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("删除 \(selectedForBatch.count) 张", role: .destructive) { deleteSelected() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将从 DualCam 内部归档中移除，无法撤销。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DUALCAM STUDIO")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(Color.yellow.opacity(0.9))
                Text(title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("\(cam.compositePhotoURLs.count) 件作品 · 仅存储于本机 App")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private var title: String {
        switch tab {
        case .library: return "作品库"
        case .compare: return "滤镜对比"
        case .settings: return "拍摄参数"
        }
    }

    private var tabBar: some View {
        HStack(spacing: 5) {
            tabButton(.library, label: "作品", icon: "square.grid.2x2")
            tabButton(.compare, label: "对比", icon: "slider.horizontal.3")
            tabButton(.settings, label: "参数", icon: "camera.aperture")
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.06)))
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private func tabButton(_ value: WorkspaceTab, label: String, icon: String) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { tab = value } } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tab == value ? .black : .white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                if tab == value {
                    RoundedRectangle(cornerRadius: 11).fill(Color.yellow)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var library: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近创作")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if selectionMode {
                    Button("全选") { selectedForBatch = Set(cam.compositePhotoURLs.map(\.path)) }
                        .font(.system(size: 12, weight: .semibold))
                    Button("取消") { selectionMode = false; selectedForBatch.removeAll() }
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Button("选择") { selectionMode = true }
                        .font(.system(size: 12, weight: .semibold))
                        .disabled(cam.compositePhotoURLs.isEmpty)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            if cam.compositePhotoURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "camera.macro")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Color.yellow.opacity(0.85))
                    Text("开始你的第一组双摄创作")
                        .font(.system(size: 16, weight: .semibold))
                    Text("拍摄的合成照片会自动保存在 DualCam 内部，不会写入系统照片图库。")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.48))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 270)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(Array(cam.compositePhotoURLs.enumerated()), id: \.element.path) { index, url in
                            Button {
                                if selectionMode {
                                    if selectedForBatch.contains(url.path) { selectedForBatch.remove(url.path) }
                                    else { selectedForBatch.insert(url.path) }
                                } else {
                                    detailItem = GalleryDetailItem(url: url)
                                }
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    GalleryThumbnail(url: url)
                                        .aspectRatio(0.78, contentMode: .fill)
                                        .frame(maxWidth: .infinity)
                                        .clipped()
                                    if selectionMode {
                                        Image(systemName: selectedForBatch.contains(url.path) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22, weight: .semibold))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(selectedForBatch.contains(url.path) ? Color.yellow : Color.white, Color.black.opacity(0.45))
                                            .padding(7)
                                    } else if index == 0 {
                                        Text("NEW")
                                            .font(.system(size: 8, weight: .black))
                                            .tracking(1)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(Color.yellow, in: Capsule())
                                            .foregroundStyle(.black)
                                            .padding(7)
                                    }
                                }
                                .overlay(alignment: .bottomLeading) {
                                    LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
                                        .frame(height: 34)
                                        .allowsHitTesting(false)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.bottom, 20)
                }
            }

            if selectionMode && !selectedForBatch.isEmpty {
                HStack(spacing: 12) {
                    Text("\(selectedForBatch.count) 已选择")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { shareSelected() } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    Button { exportToSystemPhotos(cam.compositePhotoURLs.filter { selectedForBatch.contains($0.path) }) } label: {
                        Label("导出到系统相册", systemImage: "photo.badge.arrow.down")
                    }
                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(14)
                .background(Color.white.opacity(0.07))
            }
        }
    }

    private var compare: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeading("创作对比", subtitle: "选择一张作品，再查看当前可用的滤镜预览")
                if cam.compositePhotoURLs.isEmpty {
                    emptyHint("先拍摄一张合成照片，才能开始对比。")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 9) {
                            ForEach(cam.compositePhotoURLs, id: \.path) { url in
                                Button { selectedURL = url } label: {
                                    GalleryThumbnail(url: url)
                                        .frame(width: 70, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke((selectedURL ?? cam.compositePhotoURLs.first) == url ? Color.yellow : Color.clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let url = selectedURL ?? cam.compositePhotoURLs.first {
                        GalleryLargePreview(url: url)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        Text("原始合成作品")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    sectionHeading("滤镜预览", subtitle: "预览来自当前相机参数面板；切换此处不会修改已保存的原图")
                    if cam.filterThumbs.isEmpty {
                        emptyHint("打开相机的参数面板并进入滤镜区域后，这里会出现可比较的预览。")
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(cam.filterThumbs.keys.sorted(), id: \.self) { key in
                                if let image = cam.filterThumbs[key] {
                                    Button { compareFilter = key } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Image(uiImage: image)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(height: 105)
                                                .frame(maxWidth: .infinity)
                                                .clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                            HStack {
                                                Text(key).lineLimit(1)
                                                Spacer(minLength: 0)
                                                if compareFilter == key { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.yellow) }
                                            }
                                            .font(.system(size: 11, weight: .medium))
                                        }
                                        .padding(7)
                                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("当前拍摄配置", subtitle: "只读快照，不会在相册里擅自改动相机实时参数")
                parameterRow("输出画幅", value: String(describing: cam.cfg.aspect))
                parameterRow("输出分辨率", value: String(describing: cam.cfg.resolution))
                parameterRow("目标帧率", value: "\(cam.cfg.fps) FPS")
                parameterRow("实际帧率", value: "\(cam.effectiveFPS) FPS")
                parameterRow("合成布局", value: String(describing: cam.cfg.layout))
                parameterRow("输出模式", value: cam.cfg.outputMode.rawValue)
                Toggle("防抖", isOn: $cam.cfg.stabilization)
                    .tint(.yellow)
                    .font(.system(size: 13, weight: .medium))
                Toggle("网格线", isOn: $cam.cfg.showGrid)
                    .tint(.yellow)
                    .font(.system(size: 13, weight: .medium))
                Toggle("实况照片", isOn: $cam.cfg.livePhoto)
                    .tint(.yellow)
                    .font(.system(size: 13, weight: .medium))
                Toggle("交换主副画面", isOn: $cam.cfg.swapped)
                    .tint(.yellow)
                    .font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("画中画尺寸")
                        Spacer()
                        Text(String(format: "%.0f%%", Double(cam.cfg.pipWidth * 100)))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Slider(value: $cam.cfg.pipWidth, in: 0.16...0.9)
                        .tint(.yellow)
                }
                .font(.system(size: 12, weight: .medium))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("上下分屏比例")
                        Spacer()
                        Text(String(format: "%.0f%% / %.0f%%", Double(cam.cfg.splitRatio * 100), Double((1 - cam.cfg.splitRatio) * 100)))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Slider(value: $cam.cfg.splitRatio, in: 0.25...0.75)
                        .tint(.yellow)
                }
                .font(.system(size: 12, weight: .medium))
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.yellow)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本机私有归档")
                            .font(.system(size: 13, weight: .semibold))
                        Text("作品只保存在 DualCam 的 Documents 目录。分享或导出时，才会交给系统分享面板。")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(18)
        }
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 18, weight: .bold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
        }
    }

    private func parameterRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func shareSelected() {
        let urls = cam.compositePhotoURLs.filter { selectedForBatch.contains($0.path) }
        share(urls)
    }

    private func share(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        shareItems = existing
        showingShare = true
    }

    /// Explicit export: captures remain app-private unless the user chooses this action.
    private func exportToSystemPhotos(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            exportMessage = "找不到可导出的照片文件。"
            exportAlert = true
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    exportMessage = status == .denied || status == .restricted
                        ? "没有照片图库写入权限。请在系统设置中允许 DualCam 添加照片后重试。"
                        : "未获得照片图库写入权限，照片仍保留在 DualCam 内部。"
                    exportAlert = true
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for url in existing {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: url, options: nil)
                }
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    exportMessage = success
                        ? "已将 \(existing.count) 张照片导出到系统照片图库。"
                        : "导出失败：\(error?.localizedDescription ?? "未知错误")。原照片仍保留在 DualCam 内部。"
                    exportAlert = true
                }
            })
        }
    }

    private func deleteSelected() {
        let offsets = IndexSet(cam.compositePhotoURLs.indices.filter { selectedForBatch.contains(cam.compositePhotoURLs[$0].path) })
        cam.deleteCompositePhotos(at: offsets)
        selectedForBatch.removeAll()
        selectionMode = false
    }
}

private enum WorkspaceTab {
    case library, compare, settings
}

private struct GalleryThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.white.opacity(0.07))
                    .overlay(Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)))
            }
        }
        .task(id: url) {
            let path = url.path
            let decoded = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value
            await MainActor.run { image = decoded }
        }
    }
}

private struct GalleryLargePreview: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                ProgressView().tint(.yellow)
            }
        }
        .task(id: url) {
            let path = url.path
            let decoded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: path) }.value
            await MainActor.run { image = decoded }
        }
    }
}

private struct PhotoDetailSheet: View {
    let url: URL
    let onShare: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                    Spacer()
                    Text("作品预览").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Menu {
                        Button(action: onShare) { Label("分享", systemImage: "square.and.arrow.up") }
                        Button(action: onExport) { Label("导出到系统相册", systemImage: "photo.badge.arrow.down") }
                        Button(role: .destructive, action: onDelete) { Label("删除作品", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 40, height: 40)
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                GeometryReader { geo in
                    if let image {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        }
                        .gesture(MagnificationGesture().onChanged { zoom = min(max($0, 1), 5) })
                    } else {
                        ProgressView().tint(.yellow).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .task {
            let path = url.path
            image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: path) }.value
        }
        .preferredColorScheme(.dark)
    }
}

private struct GalleryShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


private struct GalleryDetailItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
