import UIKit

/// The keyboard's own Scratchpad: a `UITextView` with an empty
/// `inputView`, so it can become first responder — with a visible caret
/// and selection, edited through our own `KeyGridView` via
/// `insertText`/`deleteBackward` — without ever summoning another
/// keyboard (ios-15 spike, unknown 8). Identifier `keyboard.scratchpad`.
///
/// iOS 26's scroll edge effects meet and hide the text in a view this
/// short (same spike): all four are hidden, and
/// `contentInsetAdjustmentBehavior = .never` is set as a precaution —
/// insets/offset were already 0 in the spike, but this guards against a
/// future iOS version changing that.
@MainActor
public final class ScratchpadTextView: UITextView {
    /// Fires on every *user* edit (typing, pasting, dictation — anything
    /// that goes through `UITextViewDelegate`). Programmatic updates from
    /// `ScratchpadDocument.setText(_:)` (a run result, Undo) set `.text`
    /// directly and don't call this, since those already come from
    /// `EditorSession.text` and shouldn't be echoed back into it.
    public var onTextChanged: ((String) -> Void)?
    public var onSelectionChanged: (() -> Void)?

    private let placeholderLabel = UILabel()

    public init() {
        super.init(frame: .zero, textContainer: nil)
        accessibilityIdentifier = "keyboard.scratchpad"
        inputView = UIView()
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        delegate = self
        hideScrollEdgeEffects()
        setUpPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = CGRect(
            x: textContainerInset.left + 5,
            y: textContainerInset.top,
            width: max(0, bounds.width - textContainerInset.left - textContainerInset.right - 10),
            height: max(0, bounds.height - textContainerInset.top - textContainerInset.bottom)
        )
    }

    public override var text: String! {
        didSet { updatePlaceholderVisibility() }
    }

    private func setUpPlaceholder() {
        placeholderLabel.text = String(
            localized: "keyboard.scratchpad.placeholder",
            defaultValue: "Select text, type or dictate",
            bundle: .module
        )
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !(text ?? "").isEmpty
    }

    /// Hides every scroll edge effect: in a short text view, the top and
    /// bottom ones meet in the middle and hide the text entirely (ios-15
    /// spike, unknown 8). Left/right are hidden too, as a precaution,
    /// even though this view never scrolls horizontally.
    private func hideScrollEdgeEffects() {
        topEdgeEffect.isHidden = true
        bottomEdgeEffect.isHidden = true
        leftEdgeEffect.isHidden = true
        rightEdgeEffect.isHidden = true
    }
}

extension ScratchpadTextView: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderVisibility()
        onTextChanged?(textView.text)
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        onSelectionChanged?()
    }
}
