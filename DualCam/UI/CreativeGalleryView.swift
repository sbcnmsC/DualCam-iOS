import SwiftUI
import UIKit
import ImageIO
import Photos

/// App-owned archive of composite photos. Browsing it never queries the Photos library; the
/// camera also saves each composite to Photos when it is taken, and "导出" copies it there again.
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
        .fullScreenCover(item: $detailItem) { item in
            PhotoDetailSheet(
                url: item.url,
                pipRegion: cam.archivedPiPRegion(for: item.url),
                secondaryPreviewURL: cam.archivedSecondaryPreviewURL(for: item.url),
                onShare: { share([item.url]) },
                onExport: { exportToSystemPhotos([item.url]) },
                onDelete: {
                    cam.deleteCompositePhoto(item.url)
                    detailItem = nil
                }
            )
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
                Text("\(cam.compositePhotoURLs.count) 件作品 · DualCam 本机归档")
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
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
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
                    Text("拍摄的合成照片会归档在 DualCam 内部，同时保存到系统照片图库。")
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
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fit)
                                        .background(Color.black)
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
                    .fixedSize()
                    Button { exportToSystemPhotos(cam.compositePhotoURLs.filter { selectedForBatch.contains($0.path) }) } label: {
                        Label("导出", systemImage: "photo.badge.arrow.down")
                    }
                    .fixedSize()
                    .accessibilityLabel("导出到系统相册")
                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .fixedSize()
                    .accessibilityLabel("删除所选作品")
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
                sectionHeading("当前拍摄配置", subtitle: "上方为当前参数；下面的开关和滑块会直接改动相机的实时设置")
                parameterRow("输出画幅", value: cam.cfg.aspect.rawValue)
                parameterRow("输出分辨率", value: cam.cfg.resolution.rawValue)
                parameterRow("目标帧率", value: "\(cam.cfg.fps) FPS")
                parameterRow("实际帧率", value: "\(cam.effectiveFPS) FPS")
                parameterRow("合成布局", value: cam.cfg.layout.rawValue)
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
                        Text("合成照片在系统照片图库之外，另存一份在 DualCam 的 Documents 目录（不计入 iCloud 备份，最多保留 300 张）。在这里删除只影响这份归档。")
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
            // Same rule as the camera's own save path, which also accepts .limited.
            guard status == .authorized || status == .limited else {
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

/// Decodes archive photos at the size they are shown. `UIImage(contentsOfFile:)` inflates the whole
/// 12–48 MP JPEG (up to ~190 MB of bitmap) for a thumbnail a few hundred pixels wide, and a grid
/// shows a dozen of them at once. ImageIO decodes straight to the target size instead.
private enum GalleryImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func load(_ url: URL, maxPixel: Int, priority: TaskPriority) async -> UIImage? {
        let cacheKey = key(url, maxPixel)
        if let hit = cache.object(forKey: cacheKey) { return hit }
        // Cells that scrolled away before their turn never start decoding.
        if Task.isCancelled { return nil }
        let path = url.path
        let image = await Task.detached(priority: priority) { downsample(path: path, maxPixel: maxPixel) }.value
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: cacheKey, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }

    private static func downsample(path: String, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct GalleryThumbnail: View {
    let url: URL
    /// Pixels on the long edge: a 3-column cell is ~130 pt, ~400 px on a 3x screen.
    private static let maxPixel = 420
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .task(id: url) {
            if let hit = GalleryImageLoader.cached(url, maxPixel: Self.maxPixel) {
                image = hit
                return
            }
            image = await GalleryImageLoader.load(url, maxPixel: Self.maxPixel, priority: .utility)
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
            image = await GalleryImageLoader.load(url, maxPixel: 1600, priority: .userInitiated)
        }
    }
}

private struct PhotoDetailSheet: View {
    let url: URL
    let pipRegion: CGRect?
    let secondaryPreviewURL: URL?
    let onShare: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var secondaryImage: UIImage?
    @State private var showingSubwindow = false
    @State private var zoom: CGFloat = 1
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if showingSubwindow {
                        showingSubwindow = false
                        zoom = 1
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: showingSubwindow ? "chevron.left" : "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingSubwindow ? "返回合成照片" : "关闭预览")
                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(showingSubwindow ? "小窗单独预览" : "合成照片")
                        .font(.system(size: 15, weight: .semibold))
                    Text(showingSubwindow ? "副摄画面" : "点小窗即可分开预览")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                }
                Spacer(minLength: 0)
                Menu {
                    Button(action: onShare) { Label("分享合成照片", systemImage: "square.and.arrow.up") }
                    Button(action: onExport) { Label("导出到系统照片", systemImage: "photo.badge.arrow.down") }
                    Button(role: .destructive, action: onDelete) { Label("删除作品", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)

            GeometryReader { geo in
                ZStack {
                    Color.black
                    if showingSubwindow, let secondaryImage {
                        Image(uiImage: secondaryImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: geo.size.width * zoom, height: geo.size.height * zoom)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let image {
                        let fitted = fittedSize(image.size, in: geo.size)
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .allowsHitTesting(false)

                        if !showingSubwindow, zoom <= 1.05, let pipRegion {
                            let hitRect = displayRect(for: pipRegion, fittedSize: fitted, containerSize: geo.size)
                            Button(action: showSecondaryPreview) {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.clear)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(Color.yellow, lineWidth: 2)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 10, weight: .black))
                                            .foregroundStyle(.black)
                                            .frame(width: 22, height: 22)
                                            .background(Circle().fill(Color.yellow))
                                            .offset(x: 5, y: 5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .frame(width: max(hitRect.width, 36), height: max(hitRect.height, 36))
                            .position(x: hitRect.midX, y: hitRect.midY)
                            .accessibilityLabel("点按小窗，单独预览副摄画面")
                        }
                    } else if loadFailed {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 30))
                            Text("无法读取这张照片").font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.65))
                    } else {
                        ProgressView().tint(.yellow)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in zoom = min(max(value, 1), 5) }
                        .onEnded { _ in if zoom < 1.05 { zoom = 1 } }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Image(systemName: showingSubwindow ? "rectangle.on.rectangle" : "hand.tap")
                    .foregroundStyle(Color.yellow)
                Text(showingSubwindow
                     ? "正在单独预览小窗画面"
                     : (pipRegion == nil ? "双摄合成作品" : "轻点黄色框内的小窗，单独查看副摄"))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
                if showingSubwindow {
                    Button("返回合成") {
                        showingSubwindow = false
                        zoom = 1
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.yellow)
                    .fixedSize()
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task {
            // 4096 px keeps pinch-zoom sharp without decoding a full 48 MP bitmap.
            let loadedMain = await GalleryImageLoader.load(url, maxPixel: 4096, priority: .userInitiated)
            image = loadedMain
            loadFailed = loadedMain == nil
            if let secondaryPreviewURL {
                secondaryImage = await GalleryImageLoader.load(secondaryPreviewURL, maxPixel: 4096, priority: .userInitiated)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func fittedSize(_ imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func displayRect(for normalized: CGRect, fittedSize: CGSize, containerSize: CGSize) -> CGRect {
        CGRect(
            x: (containerSize.width - fittedSize.width) / 2 + normalized.minX * fittedSize.width,
            y: (containerSize.height - fittedSize.height) / 2 + normalized.minY * fittedSize.height,
            width: normalized.width * fittedSize.width,
            height: normalized.height * fittedSize.height
        )
    }

    private func showSecondaryPreview() {
        if secondaryImage != nil {
            showingSubwindow = true
            zoom = 1
            return
        }
        guard let image, let pipRegion, let cropped = crop(image, normalized: pipRegion) else { return }
        secondaryImage = cropped
        showingSubwindow = true
        zoom = 1
    }

    /// Older saved photos have no source companion, so crop the inset as a fallback.
    private func crop(_ image: UIImage, normalized: CGRect) -> UIImage? {
        // Draw at scale 1 (the renderer's default is the screen scale, which would allocate a bitmap
        // 9x the photo's pixel count) and skip the redraw entirely when the image is already upright.
        let upright: UIImage
        if image.imageOrientation == .up {
            upright = image
        } else {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            upright = UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }
        guard let cgImage = upright.cgImage else { return nil }
        let bounded = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounded.isNull, bounded.width > 0, bounded.height > 0 else { return nil }
        let cropRect = CGRect(
            x: bounded.minX * CGFloat(cgImage.width),
            y: bounded.minY * CGFloat(cgImage.height),
            width: bounded.width * CGFloat(cgImage.width),
            height: bounded.height * CGFloat(cgImage.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard cropRect.width > 1, cropRect.height > 1,
              let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: upright.scale, orientation: .up)
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
