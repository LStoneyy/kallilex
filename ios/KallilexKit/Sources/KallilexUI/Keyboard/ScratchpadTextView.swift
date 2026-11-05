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
    /// Called from `textViewDidBeginEditing` — a tap that places the
    /// caret (or any other way this becomes first responder). Doesn't by
    /// itself imply a mode switch; see
    /// `KallilexKeyboardController.setUpScratchpad`'s use of this (ios-18
    /// bugfix item 8).
    public var onBeginEditing: (() -> Void)?

    private let placeholderLabel = UILabel()

    /// A subtle rounded fill, like a text field on the system keyboard
    /// (ios-18 bugfix item 7) — without this the Scratchpad has no visible
    /// background or border and blends into the keyboard background.
    private static let fillColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .white
    }

    public init() {
        super.init(frame: .zero, textContainer: nil)
        accessibilityIdentifier = "keyboard.scratchpad"
        // Otherwise VoiceOver (and the accessibility audit) has nothing to
        // describe this element with while it's empty: the placeholder
        // shown then is a separate, non-accessible `UILabel` sibling
        // (`placeholderLabel`), not part of this text view's own
        // accessible value. Reuses `EditorView`'s own `editor.label` key.
        accessibilityLabel = String(localized: "editor.label", defaultValue: "Text", bundle: .module)
        inputView = UIView()
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        contentInsetAdjustmentBehavior = .never
        backgroundColor = Self.fillColor
        layer.cornerRadius = 10
        layer.masksToBounds = true
        delegate = self
        disableSystemTextSuggestions()
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

    /// No AutoFill, no system text suggestions, no Writing Tools (ios-18
    /// bugfix item 5): tapping the Scratchpad was showing the system
    /// "Automatisch ausfüllen" (AutoFill) edit-menu callout — this field
    /// has `inputView = UIView()`, so it never gets a real keyboard's own
    /// autocorrection bar to suppress these through, only the text
    /// traits/menu below.
    private func disableSystemTextSuggestions() {
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        textContentType = nil
        if #available(iOS 18.0, *) {
            writingToolsBehavior = .none
        }
    }

    /// Restricts the edit menu to plain text editing (`cut:`/`copy:`/
    /// `paste:`/`select:`/`selectAll:`) — everything else (AutoFill, Look
    /// Up, Translate, Share, …) is dropped, matching
    /// `disableSystemTextSuggestions()`'s intent above.
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(UIResponderStandardEditActions.cut(_:)),
             #selector(UIResponderStandardEditActions.copy(_:)),
             #selector(UIResponderStandardEditActions.paste(_:)),
             #selector(UIResponderStandardEditActions.select(_:)),
             #selector(UIResponderStandardEditActions.selectAll(_:)):
            return super.canPerformAction(action, withSender: sender)
        default:
            return false
        }
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

    public func textViewDidBeginEditing(_ textView: UITextView) {
        onBeginEditing?()
    }
}
