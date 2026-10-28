# Inkwell

Personal, open-source iPad note-taking app: handwritten notebooks, a PDF/EPUB reader, and both side by side with links between them.

## Features

- **Library**: notebooks, PDFs and EPUBs in one grid. Import from Files, rename, change cover and delete from the context menu.
- **Notebooks**: paged, zoomable PencilKit canvas. Swipe left/right to turn pages (one finger, or two when finger drawing is on). Tapping `+` on the last page adds a new one.
  - **Paper**: blank, ruled (normal/narrow/wide/with margin), double line, handwriting, grid, fine grid, dotted, Cornell and music, on white, cream, yellow or dark paper. Set per page or for the whole notebook; new pages copy the page before them.
  - **Page sizes**: A3, A4, A5, A6, B5, Letter, Legal, Executive, Tabloid, Square, 16:9, 4:3, Index Card and Phone, portrait or landscape, per page or for the whole notebook. Paper sizes keep their real proportions, so A5 holds fewer lines than A4.
  - **PDF pages in notebooks**: insert a PDF's pages into a notebook, optionally interleaved with blank paper after each page, and write on them.
  - **Images**: insert photos onto a page; they sit under the ink so you can write on them.
  - **Typed text with Markdown**: headings, bold, italic, strikethrough, code, bullets, checklists, quotes and links, with a formatting bar and live preview.
  - **Links on handwriting or text**: drag a box over writing (or use "Link This Text" on a text box) and point it at a PDF page, chapter or web address. The pencil still writes over linked areas.
  - **Move & Resize mode**: drag images, text and links around, pinch to resize, tap for edit or delete.
  - **Covers**: colour, pattern in any colour (optionally over a photo), or your own photo. Everything on the cover moves like story stickers: drag, pinch and twist the title, stickers or photo, with snap guides for centring and levelling. Add your own stickers: any emoji or text you type, or photos with the subject cut out automatically. The title can be typed (style and font), handwritten with the Pencil, or left off. No cover shows the first page instead.
- **Remembers where you left off**: the page or chapter, side notes, annotate mode and divider position, per document or notebook.
- **Focus mode**: the expand button hides the title bar, pane bars and status bar. The small button in the corner brings them back.
- **Reader**: open a PDF or EPUB on its own. The pencil menu (top right) gives you:
  - **Annotate PDF**: write straight on the pages (Pencil draws, fingers scroll).
  - **Notes on the Side**: opens a companion notebook beside the document, with a draggable divider.
  - **Export Annotated PDF**: a copy with your ink burned in.
- **Links**: with notes on the side, the link button in the notes bar pins a chip to the current PDF page, the PDF chapter (from the outline) or the EPUB chapter. Tapping a chip jumps the reader there (and opens the document if it's closed). The reader's bar shows which note pages link to the page you're on. Long-press a chip to remove it.
- **Pens**: fountain, ball and brush pens, pencil, highlighter, eraser (whole strokes or pixels) and lasso. Each pen keeps its own four colours (pick a custom one to replace the selected swatch) and its own size, set with a slider in 0.1pt steps.
- **Hold to draw shapes**: pause at the end of a stroke and it snaps into a line, angle, triangle, rectangle, polygon, circle or ellipse while the pencil is still down; keep dragging to resize it. Loops that overshoot or fall short of their start still count as closed, and smooth loops become circles. Pencil Pro gives a tap when it snaps.
- **Editable geometry**: snapped and inserted shapes stay editable. Tap one with a finger for corner handles and an inspector: type a triangle's angles (the other two stay in proportion), make it equilateral, isosceles or right-angled, make polygons regular or squares square, ellipses round, set a line's length and angle, and show side lengths (cm) and angles on the page.
- **Graphs**: insert a graph and type functions of x (2x^2 - 3, sin(x)/x, e^-x, sqrt(x)...). Several curves in different colours, numbered axes, asymptotes drawn as breaks, a "Fit y" button and equal scaling. Drag to move, corner handle to resize.
- **Physics**: insert a projectile, drag its start and velocity arrow, and it draws the trajectory with range, peak height and flight time. Set speed, angle, launch height, scale and gravity (Earth, Moon, Mars, Jupiter or custom).
- **Toolbar**: a thin floating strip that fades while you write and comes back when you pause. Fold it into a pill with the chevron or a Pencil Pro squeeze, move it to the bottom, or undock to Apple's tool picker from its `...` menu (redock from the pencil menu).
- **Pencil and touch**:
  - Pencil double-tap follows your system setting (switch to eraser, previous tool, or show the strip).
  - Two-finger tap to undo, three-finger tap to redo.
  - **Scribble to erase**: zigzag over ink or text boxes and they're deleted (undoable).
  - **Live math**: write something like `12 × 4 + 3 =` and the answer appears after the `=`. It updates when you change the numbers and disappears when you erase the `=`.
  - **Handwriting to text**: tap the viewfinder button, drag a box over your handwriting, and it becomes a text box (undoable). Tap a text box to copy, edit or delete it.
  - Pinch to zoom, finger drawing on/off from the tool picker.

- **Book Mode**: the book button turns pages with a real page curl, for notes and PDFs, as a two-page spread when the pane is wider than tall. Drag to fold the page and hold it, flick or drag past halfway to turn, let go early to drop it back. Fingers turn pages, the Pencil writes.
- **Hide either side**: with notes beside a document, the PDF and Notes buttons show or hide each side.
- **One top bar**: back, title, the reader's page and outline, the notebook's tools and page controls, and dedicated Annotate and Notes buttons. It collapses to icons when space is tight.
- **Look**: warm paper tones, and an accent colour (plum, rose, ink, forest, amber or mono) plus light/dark/system from the palette button in the library.

## Building (no Mac needed)

1. Push this folder to a GitHub repo. GitHub Actions builds it on a macOS runner (`.github/workflows/build.yml`).
2. Download the `Inkwell-ipa` artifact from the run.
3. Install it with **LiveContainer** (unsigned is fine) or **Sideloadly** (free Apple ID, re-sign every 7 days).

Requires iPadOS 18+. The Xcode project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

## Data

Everything lives in the app's Documents folder (`library.json` plus `Items/<id>/`), which you can see in the Files app for backups. Under LiveContainer it lives inside LiveContainer's own container.

## Known gaps

- Ink on EPUB pages (EPUBs get side notes and chapter links, not on-page annotation).
- iCloud sync (it needs a paid developer account).
- Moving text boxes and link chips after placing them.
