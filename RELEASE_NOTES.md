# Monknot 0.1.5

This release adds one private writing-assistance flow for Markdown and plain text. It keeps corrections clear, local, and easy to reverse.

## Writing assistance

- Shows Apple spelling and grammar corrections beside the affected text.
- Combines related corrections into one sentence preview when the complete result is safe.
- Uses private on-device models for bounded English sentence repair on supported Macs.
- Adds private on-device autocomplete on supported Macs.
- Opens a focused review for broad changes and safe alternatives before Monknot replaces text.

## Correction feedback

- Uses the current theme accent for previews, correction shimmer, persistent highlights, and ghost text.
- Keeps each accepted correction highlighted with an undo hint until the user continues editing.
- Restores the complete correction with Delete or Command-Z and returns the caret without selecting restored words.
- Highlights the surviving word after a deletion-only correction.
- Supports light and dark themes, Increase Contrast, Reduce Motion, and immediate theme changes.

## Safety and compatibility

- Protects Markdown syntax, links, code, names, numbers, identifiers, and quote boundaries.
- Keeps Apple text assistance available when Monknot cannot show a safe correction.
- Runs on Apple silicon with macOS 14 or later.
