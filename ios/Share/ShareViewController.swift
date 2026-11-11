import SwiftUI
import UIKit

/// **Founderizer in the share sheet of every app** (`ShareModel` says what it does). iOS starts this controller in a
/// process of its own when the owner picks Founderizer; it hosts the two SwiftUI pages and ends the request when the
/// hub confirmed the message, or when the owner closes the sheet. A swipe down closes it as the close button does,
/// except while a message is on its way.
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "BrandCanvas")
        let model = ShareModel(
            finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            cancel: { [weak self] in self?.cancel() })
        self.model = model
        let host = UIHostingController(rootView: ShareRoot(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.take(items) }
        observeSending()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (navigationController ?? self).presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { cancel() }

    /// The sheet holds while a message is on its way, so a swipe cannot leave it with no word of how it ended.
    private func observeSending() {
        withObservationTracking { isModalInPresentation = model?.sending == true } onChange: { [weak self] in
            Task { @MainActor in self?.observeSending() }
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
