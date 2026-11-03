import SwiftUI
import UIKit
import KallilexKit

/// Principal class for the Share Extension. No storyboard; hosts a SwiftUI
/// view through `UIHostingController`.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let itemCount = extensionContext?.inputItems.count ?? 0

        let rootView = ShareView(
            itemCount: itemCount,
            onClose: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )

        let hosting = UIHostingController(rootView: rootView)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }
}

private struct ShareView: View {
    let itemCount: Int
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Hello from Kallilex")
                .font(.headline)
            Text("Received \(itemCount) input item(s).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Close", action: onClose)
                .accessibilityIdentifier("kallilex.kit.\(KallilexKit.name)")
        }
        .padding()
    }
}
