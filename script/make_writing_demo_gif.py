#!/usr/bin/env python3
"""Builds a writing-assistance GIF and its poster from recorded frames.

WorkspaceUITourTests.testRecordTheWritingAssistanceDemos writes `frame-NNN.png` and `frames.json`
(each frame's delay and the frames where each step shows) into `writing-assistance/` and
`writing-assistance-light/`. Needs Pillow (`python3 -m pip install Pillow`).

    script/make_writing_demo_gif.py FRAMES_DIR website/shots/writing-assistance.gif website/shots/writing-assistance-poster.png
"""

import json
import sys
from pathlib import Path

from PIL import Image


def main(frames_dir: Path, gif_path: Path, poster_path: Path) -> None:
    meta = json.loads((frames_dir / "frames.json").read_text())
    delays, marks = meta["delays"], meta["marks"]
    frames = [Image.open(frames_dir / f"frame-{index:03d}.png").convert("RGB") for index in range(len(delays))]
    last = len(frames) - 1
    writing_tools = min(last, marks["writingTools"] + 15)

    # One palette for every frame, so pixels that do not change stay identical and each frame stores
    # only what changed. It is taken from frames across the demo, with the small saturated details
    # (the window's buttons, Writing Tools' icon) repeated so the palette keeps their colours.
    samples = [frames[0], frames[marks["review"] + 3], frames[marks["completion"] + 3], frames[writing_tools], frames[last]]
    details = [frames[0].crop((0, 0, 120, 60)), frames[writing_tools].crop((60, 0, 360, 60))]
    width, height = frames[0].size
    sheet = Image.new("RGB", (width, height * len(samples) + 60 * 12))
    for index, sample in enumerate(samples):
        sheet.paste(sample, (0, index * height))
    for row in range(12):
        x = 0
        while x < width:
            for detail in details:
                sheet.paste(detail, (x, height * len(samples) + row * 60))
                x += detail.width
    palette = sheet.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    quantized = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]

    # GIF delays are in 10 ms steps.
    durations = [max(20, round(delay / 10) * 10) for delay in delays]
    quantized[0].save(gif_path, save_all=True, append_images=quantized[1:], duration=durations, loop=0, disposal=1)
    # The poster is the repair waiting for review.
    frames[marks["review"] + 5].save(poster_path, optimize=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
