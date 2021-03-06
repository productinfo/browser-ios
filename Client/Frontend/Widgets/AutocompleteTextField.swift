/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

// This code is loosely based on https://github.com/Antol/APAutocompleteTextField

import UIKit
import Shared

/// Delegate for the text field events. Since AutocompleteTextField owns the UITextFieldDelegate,
/// callers must use this instead.
protocol AutocompleteTextFieldDelegate: class {
    func autocompleteTextField(_ autocompleteTextField: AutocompleteTextField, didEnterText text: String)
    func autocompleteTextFieldShouldReturn(_ autocompleteTextField: AutocompleteTextField) -> Bool
    func autocompleteTextFieldShouldClear(_ autocompleteTextField: AutocompleteTextField) -> Bool
    func autocompleteTextFieldDidBeginEditing(_ autocompleteTextField: AutocompleteTextField)
}

struct AutocompleteTextFieldUX {
    static let HighlightColor = BraveUX.Blue.withAlphaComponent(0.2)
}

class AutocompleteTextField: UITextField, UITextFieldDelegate {
    var autocompleteDelegate: AutocompleteTextFieldDelegate?

    // AutocompleteTextLabel repersents the actual autocomplete text.
    // The textfields "text" property only contains the entered text, while this label holds the autocomplete text
    // This makes sure that the autocomplete doesnt mess with keyboard suggestions provided by third party keyboards.
    private var autocompleteTextLabel: UILabel?
    private var hideCursor: Bool = false

    var isSelectionActive: Bool {
        return autocompleteTextLabel != nil
    }

    // This variable is a solution to get the right behavior for refocusing
    // the AutocompleteTextField. The initial transition into Overlay Mode
    // doesn't involve the user interacting with AutocompleteTextField.
    // Thus, we update shouldApplyCompletion in touchesBegin() to reflect whether
    // the highlight is active and then the text field is updated accordingly
    // in touchesEnd() (eg. applyCompletion() is called or not)
    fileprivate var notifyTextChanged: (() -> Void)?
    private var lastReplacement: String?

    var highlightColor = AutocompleteTextFieldUX.HighlightColor

    override var text: String? {
        didSet {
            super.text = text
            self.textDidChange(self)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }

    fileprivate func commonInit() {
        super.delegate = self
        super.addTarget(self, action: #selector(AutocompleteTextField.textDidChange(_:)), for: UIControlEvents.editingChanged)
        notifyTextChanged = debounce(0.1, action: {
            if self.isEditing {
                self.autocompleteDelegate?.autocompleteTextField(self, didEnterText: self.normalizeString(self.text ?? ""))
            }
        })
    }

    override var keyCommands: [UIKeyCommand]? {
        return [
            UIKeyCommand(input: UIKeyInputLeftArrow, modifierFlags: .init(rawValue: 0), action: #selector(self.handleKeyCommand(sender:))),
            UIKeyCommand(input: UIKeyInputRightArrow, modifierFlags: .init(rawValue: 0), action: #selector(self.handleKeyCommand(sender:)))
        ]
    }

    @objc func handleKeyCommand(sender: UIKeyCommand) {
        switch sender.input {
        case UIKeyInputLeftArrow:
            if isSelectionActive {
                applyCompletion()

                // Set the current position to the beginning of the text.
                selectedTextRange = placeCursor(at: beginningOfDocument)
            } else if let range = selectedTextRange {
                if range.start == beginningOfDocument {
                    return
                }

                guard let cursorPosition = position(from: range.start, offset: -1) else {
                    return
                }

                selectedTextRange = placeCursor(at: cursorPosition)
            }
        case UIKeyInputRightArrow:
            if isSelectionActive {
                applyCompletion()

                // Set the current position to the end of the text.
                selectedTextRange = placeCursor(at: endOfDocument)
            } else if let range = selectedTextRange {
                if range.end == endOfDocument {
                    return
                }

                guard let cursorPosition = position(from: range.end, offset: 1) else {
                    return
                }

                selectedTextRange = placeCursor(at: cursorPosition)
            }
        default:
            return
        }
    }

    func highlightAll() {
        let text = self.text
        self.text = ""
        setAutocompleteSuggestion(text ?? "")
        selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
    }

    fileprivate func normalizeString(_ string: String) -> String {
        return string.lowercased().stringByTrimmingLeadingCharactersInSet(CharacterSet.whitespaces)
    }

    /// Commits the completion by setting the text and removing the highlight.
    fileprivate func applyCompletion() {

        // Clear the current completion, then set the text without the attributed style.
        let text = (self.text ?? "") + (self.autocompleteTextLabel?.text ?? "")
        removeCompletion()
        self.text = text
        hideCursor = false
        // Move the cursor to the end of the completion.
        selectedTextRange = placeCursor(at: endOfDocument)
    }

    fileprivate func placeCursor(at location: UITextPosition) -> UITextRange? {
        return textRange(from: location, to: location)
    }

    /// Removes the autocomplete-highlighted
    fileprivate func removeCompletion() {
        autocompleteTextLabel?.removeFromSuperview()
        autocompleteTextLabel = nil
    }

    // `shouldChangeCharactersInRange` is called before the text changes, and textDidChange is called after.
    // Since the text has changed, remove the completion here, and textDidChange will fire the callback to
    // get the new autocompletion.
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        lastReplacement = string
        return true
    }

    func setAutocompleteSuggestion(_ suggestion: String?) {
        let normalized = normalizeString(self.text ?? "")

        guard let suggestion = suggestion, isEditing && markedTextRange == nil else {
            hideCursor = false
            return
        }

        if !suggestion.startsWith(normalized) || normalized.count >= suggestion.count {
            hideCursor = false
            return
        }

        let suggestionText = suggestion.substring(from: suggestion.index(suggestion.startIndex, offsetBy: normalized.count))
        let autocompleteText = NSMutableAttributedString(string: suggestionText)
        autocompleteText.addAttribute(NSAttributedStringKey.backgroundColor, value: highlightColor, range: NSRange(location: 0, length: suggestionText.count))
        autocompleteTextLabel?.removeFromSuperview() // should be nil. But just in case
        autocompleteTextLabel = createAutocompleteLabel(with: autocompleteText)
        if let label = autocompleteTextLabel {
            addSubview(label)
            hideCursor = true
            forceResetCursor()
        }
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        return hideCursor ? CGRect.zero : super.caretRect(for: position)
    }

    private func createAutocompleteLabel(with text: NSAttributedString) -> UILabel {
        let label = UILabel()
        var frame = self.bounds
        label.attributedText = text
        label.font = self.font
        label.accessibilityIdentifier = "autocomplete"
        label.backgroundColor = self.backgroundColor

        let enteredTextSize = self.attributedText?.boundingRect(with: self.frame.size, options: NSStringDrawingOptions.usesLineFragmentOrigin, context: nil)
        frame.origin.x = (enteredTextSize?.width.rounded() ?? 0)
        frame.size.width = self.frame.size.width - frame.origin.x
        frame.size.height = self.frame.size.height - 1
        label.frame = frame
        return label
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        autocompleteDelegate?.autocompleteTextFieldDidBeginEditing(self)
    }

    func textFieldShouldEndEditing(_ textField: UITextField) -> Bool {
        applyCompletion()
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        applyCompletion()
        return autocompleteDelegate?.autocompleteTextFieldShouldReturn(self) ?? true
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        removeCompletion()
        return autocompleteDelegate?.autocompleteTextFieldShouldClear(self) ?? true
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        // Clear the autocompletion if any provisionally inserted text has been
        // entered (e.g., a partial composition from a Japanese keyboard).
        removeCompletion()
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    @objc func textDidChange(_ textField: UITextField) {
        hideCursor = autocompleteTextLabel != nil
        removeCompletion()

        let isAtEnd = selectedTextRange?.start == endOfDocument
        let isEmpty = lastReplacement?.isEmpty ?? true
        if !isEmpty && isAtEnd && markedTextRange == nil {
            notifyTextChanged?()
        } else {
            hideCursor = false
        }
    }

    // Reset the cursor to the end of the text field.
    // This forces `caretRect(for position: UITextPosition)` to be called which will decide if we should show the cursor
    // This exists because ` caretRect(for position: UITextPosition)` is not called after we apply an autocompletion.
    private func forceResetCursor() {
        selectedTextRange = nil
        selectedTextRange = placeCursor(at: endOfDocument)
    }

    override func deleteBackward() {
        lastReplacement = nil
        hideCursor = false
        if isSelectionActive {
            removeCompletion()
            forceResetCursor()
        } else {
            super.deleteBackward()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        applyCompletion()
        super.touchesBegan(touches, with: event)
    }

}
