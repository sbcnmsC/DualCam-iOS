import SwiftUI
import UIKit
import ImageIO
import Photos

/// DualCam 私有相机相册：仅浏览拍摄的合成照片、单独预览画中画小窗，以及导出到系统相册。
struct CreativeGalleryView: View {
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var detailItem: SwipeUpCameraAlbumEntry20261027?
    @State private var selectionMode = false
    @State private var selectedForExport: Set<String> = []
    @State private var exportAlert = false
    @State private var exportMessage = ""

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if cam.compositePhotoURLs.isEmpty {
                    emptyState
                } else {
                    photoGrid
                }
                if selectionMode && !selectedForExport.isEmpty {
                    exportSelectionBar
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $detailItem) { item in
            CameraAlbumPhotoDetail(
                photoURLs: cam.compositePhotoURLs,
                initialURL: item.url,
                onExport: { url in exportToSystemPhotos([url]) }
            )
        }
        .alert("导出到系统相册", isPresented: $exportAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("相机相册")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(cam.compositePhotoURLs.count) 张拍摄照片")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 6)
            if selectionMode {
                Button("全选") {
                    selectedForExport = Set(cam.compositePhotoURLs.map(\.path))
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.yellow)
                Button("完成") {
                    selectionMode = false
                    selectedForExport.removeAll()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            } else if !cam.compositePhotoURLs.isEmpty {
                Button("选择") {
                    selectionMode = true
                    selectedForExport.removeAll()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.yellow)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回相机")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.yellow.opacity(0.9))
            Text("还没有拍摄照片")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text("在 DualCam 拍摄的合成照片会显示在这里。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(cam.compositePhotoURLs.enumerated()), id: \.element.path) { index, url in
                    Button {
                        if selectionMode {
                            if selectedForExport.contains(url.path) {
                                selectedForExport.remove(url.path)
                            } else {
                                selectedForExport.insert(url.path)
                            }
                        } else {
                            detailItem = SwipeUpCameraAlbumEntry20261027(url: url)
                        }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            CameraAlbumThumbnail(url: url)
                                .frame(maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(Color.black)
                                .clipped()
                            if selectionMode {
                                Image(systemName: selectedForExport.contains(url.path) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22, weight: .semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(selectedForExport.contains(url.path) ? Color.yellow : Color.white,
                                                     Color.black.opacity(0.45))
                                    .padding(7)
                            } else if index == 0 {
                                Text("最新")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Color.yellow, in: Capsule())
                                    .foregroundStyle(.black)
                                    .padding(7)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 18)
        }
    }

    private var exportSelectionBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(selectedForExport.count) 张")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 4)
            Button {
                exportToSystemPhotos(cam.compositePhotoURLs.filter { selectedForExport.contains($0.path) })
            } label: {
                Label("导出到系统相册", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.yellow, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(red: 0.07, green: 0.07, blue: 0.075))
    }

    private func exportToSystemPhotos(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            exportMessage = "找不到可导出的照片文件。"
            exportAlert = true
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    exportMessage = status == .denied || status == .restricted
                        ? "没有照片图库写入权限。请在系统设置中允许 DualCam 添加照片后重试。"
                        : "未获得照片图库写入权限，照片仍保留在 DualCam 相机相册。"
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
                        : "导出失败：\(error?.localizedDescription ?? "未知错误")。原照片仍保留在 DualCam。"
                    exportAlert = true
                }
            })
        }
    }
}

private struct SwipeUpCameraAlbumEntry20261027: Identifiable {
    let url: URL
    var id: String { url.path }
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

private struct CameraAlbumThumbnail: View {
    let url: URL
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
            image = await GalleryImageLoader.load(url, maxPixel: Self.maxPixel, priority: .utility)
        }
    }
}

private struct CameraAlbumPhotoDetail: View {
    @EnvironmentObject private var cam: CameraManager
    let photoURLs: [URL]
    let initialURL: URL
    let onExport: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var image: UIImage?
    @State private var secondaryImage: UIImage?
    @State private var showingSubwindow = false
    @State private var zoom: CGFloat = 1
    @State private var loadFailed = false

    init(photoURLs: [URL], initialURL: URL, onExport: @escaping (URL) -> Void) {
        self.photoURLs = photoURLs
        self.initialURL = initialURL
        self.onExport = onExport
        _currentIndex = State(initialValue: max(0, photoURLs.firstIndex(of: initialURL) ?? 0))
    }

    private var currentURL: URL {
        photoURLs[min(max(currentIndex, 0), photoURLs.count - 1)]
    }

    private var currentPiPRegion: CGRect? {
        cam.archivedPiPRegion(for: currentURL)
    }

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
                .accessibilityLabel(showingSubwindow ? "返回合成照片" : "返回相机相册")

                Spacer(minLength: 0)
                VStack(spacing: 2) {
                    Text(showingSubwindow ? "副摄画面" : "合成照片")
                        .font(.system(size: 15, weight: .semibold))
                    Text(showingSubwindow
                         ? "小窗单独预览"
                         : "\(currentIndex + 1) / \(photoURLs.count) · 左右滑动切换")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                Button {
                    onExport(currentURL)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.yellow))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("导出到系统相册")
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

                        if !showingSubwindow, zoom <= 1.05, let pipRegion = currentPiPRegion {
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

                    if photoURLs.count > 1 && !showingSubwindow {
                        HStack {
                            if currentIndex > 0 {
                                edgeButton(systemName: "chevron.left") { movePhoto(by: -1) }
                            } else {
                                Color.clear.frame(width: 34)
                            }
                            Spacer(minLength: 0)
                            if currentIndex < photoURLs.count - 1 {
                                edgeButton(systemName: "chevron.right") { movePhoto(by: 1) }
                            } else {
                                Color.clear.frame(width: 34)
                            }
                        }
                        .padding(.horizontal, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 35, coordinateSpace: .local)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            guard abs(dx) >= 58, abs(dx) > abs(dy) * 1.25 else { return }
                            // Swipe left moves to the next older photo; swipe right moves to newer.
                            movePhoto(by: dx < 0 ? 1 : -1)
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in zoom = min(max(value, 1), 5) }
                        .onEnded { _ in if zoom < 1.05 { zoom = 1 } }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Image(systemName: showingSubwindow ? "rectangle.on.rectangle" : "hand.draw")
                    .foregroundStyle(Color.yellow)
                Text(showingSubwindow
                     ? "正在单独预览副摄画面"
                     : (currentPiPRegion == nil ? "左右滑动切换照片" : "左右滑动切换 · 点小窗单独预览"))
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
        .task(id: currentURL) {
            image = nil
            secondaryImage = nil
            loadFailed = false
            zoom = 1
            showingSubwindow = false

            let requestedURL = currentURL
            let secondaryURL = cam.archivedSecondaryPreviewURL(for: requestedURL)
            let loadedMain = await GalleryImageLoader.load(requestedURL, maxPixel: 4096, priority: .userInitiated)
            guard !Task.isCancelled else { return }
            image = loadedMain
            loadFailed = loadedMain == nil
            if let secondaryURL {
                let loadedSecondary = await GalleryImageLoader.load(secondaryURL, maxPixel: 4096, priority: .userInitiated)
                guard !Task.isCancelled else { return }
                secondaryImage = loadedSecondary
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func edgeButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 34, height: 62)
                .background(Color.black.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func movePhoto(by offset: Int) {
        let next = currentIndex + offset
        guard photoURLs.indices.contains(next) else { return }
        currentIndex = next
        image = nil
        secondaryImage = nil
        loadFailed = false
        showingSubwindow = false
        zoom = 1
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
        guard let image, let pipRegion = currentPiPRegion,
              let cropped = crop(image, normalized: pipRegion) else { return }
        secondaryImage = cropped
        showingSubwindow = true
        zoom = 1
    }

    private func crop(_ image: UIImage, normalized: CGRect) -> UIImage? {
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

