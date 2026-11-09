import SwiftUI
import UIKit

/// 大图浏览：左右滑动切换、双指/双击缩放，底部显示识别信息与匹配原因
struct PhotoDetailView: View {
    let route: DetailRoute
    @Environment(AppModel.self) private var app
    @State private var currentID: String?
    @State private var showInfo = false
    @State private var showOverlay = true
    @State private var ids: [String] = []

    init(route: DetailRoute) {
        self.route = route
        _currentID = State(initialValue: route.id)
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    ZoomableImage(id: id)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showOverlay.toggle() } }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if showOverlay, let id = currentID {
                DetailOverlay(id: id) { showInfo = true }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let id = currentID {
                PhotoInfoSheet(id: id)
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            if ids.isEmpty { ids = app.ids(for: route.context) }
        }
    }

    private var title: String {
        guard let id = currentID else { return "" }
        let index = (ids.firstIndex(of: id) ?? 0) + 1
        return "\(index) / \(ids.count)"
    }
}

/// 底部浮层：日期、来源、匹配原因、主要标签
private struct DetailOverlay: View {
    let id: String
    var onMore: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let _ = app.engine.revision
        let record = app.engine.record(for: id)
        let meta = app.engine.meta(for: id)
        let hit = app.search.hit(for: id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(ImageID.source(of: id) == .imported ? "导入的图片" : "相册",
                      systemImage: ImageID.source(of: id) == .imported ? "square.and.arrow.down" : "photo")
                if let date = meta?.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                Button("详情", action: onMore).font(.footnote.weight(.semibold))
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))

            if let hit, !hit.reasons.isEmpty {
                Text("匹配：" + hit.reasons.joined(separator: "；"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let record {
                if record.flags.contains(.analysisFailed) {
                    Text("这张图片暂时无法分析（原图可能只在 iCloud，本机没有可用的预览图）").font(.footnote).foregroundStyle(.orange)
                } else {
                    let names = LabelSummary.topNames(record, limit: 6)
                    if !names.isEmpty {
                        Text(names.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                    }
                }
            } else {
                Text("尚未建立索引").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

enum LabelSummary {
    /// 去重后的中文标签名（带置信度），用于展示
    static func topNames(_ record: ImageRecord, limit: Int, minConfidence: Float = 0.3) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for l in record.labels where l.confidence >= minConfidence {
            let name = LabelDictionary.shared.displayName(for: l.id)
            guard seen.insert(name).inserted else { continue }
            out.append("\(name) \(Int((l.confidence * 100).rounded()))%")
            if out.count >= limit { break }
        }
        return out
    }
}

/// 完整识别信息
private struct PhotoInfoSheet: View {
    let id: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let record = app.engine.record(for: id)
        let meta = app.engine.meta(for: id)
        NavigationStack {
            List {
                Section("基本信息") {
                    row("来源", ImageID.source(of: id) == .imported ? "App 内导入" : "系统相册")
                    if let name = meta?.fileName { row("文件名", name) }
                    if let d = meta?.creationDate { row("时间", d.formatted(date: .long, time: .shortened)) }
                    if let r = record, r.faceCount > 0 { row("人脸", "\(r.faceCount) 张") }
                    if let r = record, r.flags.contains(.hasQRCode) { row("二维码", "有") }
                    if let r = record, !r.flags.unavailableAnalysisNames.isEmpty {
                        row("没跑成的识别", r.flags.unavailableAnalysisNames.joined(separator: "、"))
                    }
                    let tags = metaTags(meta)
                    if !tags.isEmpty { row("类型", tags.joined(separator: "、")) }
                }
                if let hit = app.search.hit(for: id), !hit.reasons.isEmpty {
                    Section("为什么匹配") {
                        ForEach(hit.reasons, id: \.self) { Text($0) }
                    }
                }
                if let r = record, !r.labels.isEmpty {
                    Section("识别到的内容（Apple Vision，本机）") {
                        ForEach(LabelSummary.topNames(r, limit: 20, minConfidence: 0.15), id: \.self) { Text($0) }
                    }
                }
                if let r = record, !r.ocrText.isEmpty {
                    Section("图中文字") {
                        Text(r.ocrText).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("图片信息")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }
    }

    private func metaTags(_ m: ImageMeta?) -> [String] {
        guard let m else { return [] }
        var t: [String] = []
        if m.isScreenshot { t.append("截图") }
        if m.isFavorite { t.append("个人收藏") }
        if m.isSelfie { t.append("自拍") }
        if m.isPanorama { t.append("全景") }
        if m.isLivePhoto { t.append("实况") }
        if m.isPortrait { t.append("人像模式") }
        return t
    }
}

/// 单张大图（异步加载）
private struct ZoomableImage: View {
    let id: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableScrollView(image: image)
            } else if failed {
                Label("图片加载失败", systemImage: "exclamationmark.triangle").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: id) {
            image = await ImageLoader.shared.fullImage(for: id)
            failed = image == nil
        }
    }
}

/// UIScrollView 实现的双指缩放 + 双击放大
private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
