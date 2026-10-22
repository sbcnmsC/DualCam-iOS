import AVKit
import Photos
import SwiftUI
import UIKit

/// In-app photo library opened from the camera's bottom-left album button.
struct PhotoLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PhotoLibrarySelection?
    @State private var isLoading = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var hasReadAccess: Bool {
        authorization == .authorized || authorization == .limited
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasReadAccess {
                    if isLoading && assets.isEmpty {
                        ProgressView("正在读取相册…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if assets.isEmpty {
                        ContentUnavailableView(
                            "相册里还没有照片",
                            systemImage: "photo.on.rectangle.angled",
                            description: Text("DualCam 保存到系统照片图库的照片和视频会显示在这里。")
                        )
                    } else {
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 2) {
                                ForEach(assets, id: \.localIdentifier) { asset in
                                    Button {
                                        selectedAsset = PhotoLibrarySelection(asset: asset)
                                    } label: {
                                        PhotoAssetThumbnail(asset: asset)
                                            .aspectRatio(1, contentMode: .fit)
                                            .frame(maxWidth: .infinity)
                                            .clipped()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(asset.mediaType == .video ? "查看视频" : "查看照片")
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 2)
                        }
                        .background(Color.black)
                        .refreshable { loadAssets() }
                    }
                } else if authorization == .notDetermined {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在请求照片图库权限")
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { requestReadAccess() }
                } else {
                    ContentUnavailableView {
                        Label("需要相册访问权限", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text("允许 DualCam 读取照片图库后，才能在应用内查看已保存的照片和视频。")
                    } actions: {
                        Button("打开系统设置") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black)
            .navigationTitle("相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                if hasReadAccess {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            loadAssets()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("刷新相册")
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: $selectedAsset) { selection in
                PhotoAssetViewer(asset: selection.asset)
                    .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .onAppear { refreshAuthorization() }
    }

    private func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if hasReadAccess {
            loadAssets()
        } else if authorization == .notDetermined {
            requestReadAccess()
        }
    }

    private func requestReadAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                authorization = status
                if status == .authorized || status == .limited {
                    loadAssets()
                }
            }
        }
    }

    private func loadAssets() {
        guard hasReadAccess else { return }
        isLoading = true
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 300
        let result = PHAsset.fetchAssets(with: options)
        var fetched: [PHAsset] = []
        fetched.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched
        isLoading = false
    }
}

private struct PhotoLibrarySelection: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }

    init(asset: PHAsset) {
        self.asset = asset
    }
}

private struct PhotoAssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Color.white.opacity(0.06)
                        .overlay {
                            Image(systemName: asset.mediaType == .video ? "video" : "photo")
                                .foregroundStyle(.white.opacity(0.45))
                        }
                }

                if asset.mediaType == .video {
                    Label(videoDuration(asset.duration), systemImage: "play.fill")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.72), in: Capsule())
                        .padding(5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black)
        }
        .onAppear(perform: loadThumbnail)
    }

    private func loadThumbnail() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: 360, height: 360)
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async { image = result }
        }
    }

    private func videoDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PhotoAssetViewer: View {
    @Environment(\.dismiss) private var dismiss
    let asset: PHAsset

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if asset.mediaType == .video {
                    if let player {
                        VideoPlayer(player: player)
                            .ignoresSafeArea(edges: .bottom)
                    } else if isLoading {
                        ProgressView("正在加载视频…")
                    } else {
                        ContentUnavailableView("无法播放视频", systemImage: "video.slash")
                    }
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView("正在加载照片…")
                } else {
                    ContentUnavailableView("无法加载照片", systemImage: "photo")
                }
            }
            .navigationTitle(asset.mediaType == .video ? "视频" : "照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: loadAsset)
        .onDisappear { player?.pause() }
    }

    private func loadAsset() {
        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                DispatchQueue.main.async {
                    player = item.map { AVPlayer(playerItem: $0) }
                    isLoading = false
                    player?.play()
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 2400, height: 2400),
                contentMode: .aspectFit,
                options: options
            ) { result, _ in
                guard let result else { return }
                DispatchQueue.main.async {
                    image = result
                    isLoading = false
                }
            }
        }
    }
}
