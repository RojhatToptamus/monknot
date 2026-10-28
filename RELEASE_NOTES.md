# Monknot 0.1.10

This release aligns and resizes images and video in Preview, and shows PDF pages dimmed or dark.

## Editing in Preview

- Centers or right-aligns paragraphs, headings, images, video and audio with Shift-Command-E and Shift-Command-R (Shift-Command-L for left), from the format bar, the block menu or the bar over an image. The file gets `<div align="center">` around those blocks, which GitHub shows the same way.
- Resizes an image or video by dragging the handles on its sides; double-clicking a handle returns it to its own size. The width is saved in the alt text, as in `![Chart|480](chart.png)`.

## PDFs

- Shows PDF pages as they are, dimmed, or dark with light text in the theme's colours, from a menu next to zoom in the PDF bar; moving through the menu previews each choice. View › PDF Pages and Settings › Appearance hold the same choice. The file is never changed.

## Writing assistance

- Shows a suggestion's hint below the line in Source when it would run past the edge of the text column, instead of cutting it off.
