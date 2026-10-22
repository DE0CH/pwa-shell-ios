import SwiftUI

@main
struct ShellApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.token == nil { SignInView() } else { MainView() }
    }
}

/// The brand logo (build input), else the app icon.
struct LogoImage: View {
    var size: CGFloat
    var body: some View {
        if let ui = UIImage(named: "Logo") ?? UIImage(named: "ShellIcon") {
            Image(uiImage: ui).resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            LogoImage(size: 88)
            Text(Config.appName).font(.largeTitle.bold())
            Text(L("signin.message")).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let e = model.signInError { Text(e).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center) }
            Button {
                model.startSignIn()
            } label: {
                Text(L("signin.button")).frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(model.signingIn)
            .accessibilityIdentifier("signin-button")
            if model.signingIn { ProgressView() }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 520)
    }
}
