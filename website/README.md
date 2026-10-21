# Monknot product site

Dependency-free implementation of the approved Monknot website design.

The product shots in `shots/` and `social/monknot-social.jpg` are captured from Monknot in Harbor
light and dark; `scripts/check.mjs` pins each file's hash, so update it with them:

```sh
MONKNOT_WEBSITE_SHOTS_DIR=/tmp/shots swift test --filter WorkspaceUITourTests/testCaptureTheWebsiteImages
MONKNOT_WEBSITE_SHOTS_DIR=/tmp/shots swift test --filter WorkspaceUITourTests/testRecordTheWritingAssistanceDemos
script/make_writing_demo_gif.py /tmp/shots/writing-assistance website/shots/writing-assistance.gif website/shots/writing-assistance-poster.png
script/make_writing_demo_gif.py /tmp/shots/writing-assistance-light website/shots/writing-assistance-light.gif website/shots/writing-assistance-light-poster.png
```

Run them from the repository root with the screen unlocked. The demo uses Apple's on-device model,
so its completion differs from take to take. `macbook-pro.png` and `icon-graphite.png` come from the
supplied design source.

```sh
cd website
npm run check
npm run build
npm run preview
```

The production output is written to `website/dist`. Configure Vercel's Root Directory as
`website`; the `vercel.json` in this directory runs the build and serves `dist` without requiring
access to the rest of the repository.
