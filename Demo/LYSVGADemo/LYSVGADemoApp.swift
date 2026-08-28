import SwiftUI

@main
struct LYSVGADemoApp: App {
    init() {
        DemoSupport.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                SwiftUIDemoView()
                    .tabItem { Label("SwiftUI", systemImage: "swift") }

                UIKitDemoContainer()
                    .tabItem { Label("UIKit", systemImage: "rectangle.on.rectangle") }
            }
        }
    }
}

private struct UIKitDemoContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIKitDemoViewController())
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
