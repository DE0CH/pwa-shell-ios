import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct Composer: View {
    @Environment(AppModel.self) private var model
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            if !model.pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pending) { a in
                            ZStack(alignment: .topTrailing) {
                                if let t = a.thumbnail, let ui = UIImage(data: t) {
                                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    VStack(spacing: 2) {
                                        Image(systemName: "doc")
                                        Text(a.name).font(.caption2).lineLimit(2)
                                    }
                                    .frame(width: 64, height: 64).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                                }
                                Button { model.pending.removeAll { $0.id == a.id } } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .offset(x: 6, y: -6)
                                .accessibilityLabel(L("composer.remove", a.name))
                            }
                            .accessibilityIdentifier("pending-attachment")
                        }
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
            }
            GlassGroup {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { showPhotos = true } label: { Label(L("composer.photos"), systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label(L("composer.camera"), systemImage: "camera") }
                    }
                    Button { showFiles = true } label: { Label(L("composer.files"), systemImage: "folder") }
                } label: {
                    Image(systemName: "paperclip").font(.title3).frame(width: 36, height: 36)
                        .glassCircle()
                }
                .accessibilityLabel(L("composer.attach"))
                .accessibilityIdentifier("attach-button")

                TextField(L("composer.placeholder", Config.appName), text: $model.draft, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassField()
                    .onChange(of: model.draft) { _, _ in model.draftChanged() }
                    .accessibilityIdentifier("composer-input")

                if model.isBusy {
                    Button { model.stop() } label: { ActionSymbol(glass: "stop.fill", plain: "stop.circle.fill") }
                        .glassAction()
                        .accessibilityLabel(L("button.stop"))
                } else if model.sending {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    Button { model.send() } label: { ActionSymbol(glass: "arrow.up", plain: "arrow.up.circle.fill") }
                        .glassAction()
                        .disabled(!model.canSend)
                        .accessibilityLabel(L("button.send"))
                        .accessibilityIdentifier("send-button")
                }
            }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { for item in items { if let a = await Attachments.from(item) { model.pending.append(a) } } }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let image, let a = Attachments.from(image) { model.pending.append(a) }
                showCamera = false
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls { if let a = Attachments.from(u) { model.pending.append(a) } }
        }
    }
}

enum Attachments {
    static let maxBytes = 30 * 1024 * 1024

    static func thumbnail(_ data: Data) -> Data? {
        guard let ui = UIImage(data: data), let t = ui.preparingThumbnail(of: CGSize(width: 240, height: 240)) else { return nil }
        return t.jpegData(compressionQuality: 0.7)
    }

    static func from(_ item: PhotosPickerItem) async -> PendingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self), data.count <= maxBytes else { return nil }
        let type = item.supportedContentTypes.first ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"
        let name = "IMG_\(Int(Date().timeIntervalSince1970 * 1000) % 100000).\(ext)"
        return PendingAttachment(name: name, data: data, mimeType: type.preferredMIMEType ?? "image/jpeg",
                                 thumbnail: type.conforms(to: .image) ? thumbnail(data) : nil)
    }

    static func from(_ image: UIImage) -> PendingAttachment? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return PendingAttachment(name: "Photo_\(Int(Date().timeIntervalSince1970)).jpg", data: data, mimeType: "image/jpeg",
                                 thumbnail: thumbnail(data))
    }

    static func from(_ url: URL) -> PendingAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return PendingAttachment(name: url.lastPathComponent, data: data, mimeType: type.preferredMIMEType ?? "application/octet-stream",
                                 thumbnail: type.conforms(to: .image) ? thumbnail(data) : nil)
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

// MARK: - Liquid Glass (iOS 26, as Messages' composer); earlier iOS keeps the plain field on the bar

/// Lets the composer's glass shapes blend into each other.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 8) { content } } else { content }
    }
}

extension View {
    /// The text field: a glass capsule-like shape.
    @ViewBuilder func glassField() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            background(.background, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
        }
    }

    /// The attach button: a glass circle.
    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular.interactive(), in: Circle()) } else { self }
    }

    /// Send and Stop: the system's prominent glass button, a circle.
    @ViewBuilder func glassAction() -> some View {
        if #available(iOS 26.0, *) { buttonStyle(.glassProminent).buttonBorderShape(.circle) } else { self }
    }

    /// The composer's backdrop: none on iOS 26 (the glass floats over the transcript), else the bar.
    @ViewBuilder func composerBackdrop() -> some View {
        if #available(iOS 26.0, *) { self } else { background(.bar) }
    }
}

/// Send / Stop's symbol: bare inside the iOS 26 glass button, the filled circle before it.
struct ActionSymbol: View {
    var glass: String
    var plain: String
    var body: some View {
        if #available(iOS 26.0, *) {
            Image(systemName: glass).font(.body.weight(.semibold)).frame(width: 22, height: 22)
        } else {
            Image(systemName: plain).font(.title)
        }
    }
}
