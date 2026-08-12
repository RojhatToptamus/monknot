# Monknot 0.1.3

This release refines Monknot's document interactions, conflict review, clipboard workflows, terminal integration, and PDF tools.

- Makes Markdown links, reference links, wikilinks, and heading destinations behave consistently between source and preview.
- Adds safe link-aware file moves with review, stale-change validation, backlink rewriting, and same-document anchor preservation.
- Replaces the external-change review with a compact, theme-aware unified diff whose blank and long lines remain readable.
- Adds safe multi-hunk merging and Save a Copy while preserving disk revalidation and conflict protections.
- Adds validated Copy Relative Path actions and guarded semantic clipboard import and export.
- Adds Copy Linked Excerpt for exact PDF selections with workspace-root page backlinks.
- Adds native PDF Free Text annotations with editing, formatting, moving, resizing, deletion, undo, save, and external-change protection.
- Makes Add Text Box a one-shot command while Select remains the normal mode for manipulating existing text boxes.
- Improves the PDF Pages, Outline, and Annotations navigator, accessible resizing, workspace scaling, and page/zoom restoration.
- Keeps shared action-button hover feedback stable and consistent with Monknot's other controls.
- Stops intercepting typed question marks; keyboard-shortcut help remains available from the Help menu.
