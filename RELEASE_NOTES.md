# Monknot 0.1.10

This release aligns and resizes images and video in Preview, and shows PDF pages dimmed or dark.

## Editing in Preview

- Centers or right-aligns paragraphs, headings, images, video and audio with Shift-Command-E and Shift-Command-R (Shift-Command-L for left), from the format bar, the block menu or the bar over an image. The file gets `<div align="center">` around those blocks, which GitHub shows the same way.
- Resizes an image or video by dragging the handles on its sides; double-clicking a handle returns it to its own size. The width is saved in the alt text, as in `![Chart|480](chart.png)`.

## PDFs

- Shows PDF pages as they are, dimmed, or dark with light text in the theme's colours, from a menu next to zoom in the PDF bar; moving through the menu previews each choice. View › PDF Pages and Settings › Appearance hold the same choice. The file is never changed.

## Sidebar

- Clicking a file, in the file list or in Recents, opens it and keeps keyboard focus in the sidebar, so Command-C, Command-X, Command-V, Command-D and Command-Delete act on the file: Command-V puts a copied image in the note's folder instead of inside the note. Click in the note, or press Command-Down Arrow, to type in it.
- Clicking the empty space below the files also moves keyboard focus to the sidebar and selects nothing, so Command-V puts a copied image or file in the workspace's top folder.

## Writing assistance

- Shows a suggestion's hint below the line in Source when it would run past the edge of the text column, instead of cutting it off.
