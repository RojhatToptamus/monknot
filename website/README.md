# Monknot product site

Dependency-free implementation of the approved Monknot website design. The product imagery in
`shots/` is copied unchanged from the supplied design source.

```sh
cd website
npm run check
npm run build
npm run preview
```

The production output is written to `website/dist`. Configure Vercel's Root Directory as
`website`; the `vercel.json` in this directory runs the build and serves `dist` without requiring
access to the rest of the repository.
