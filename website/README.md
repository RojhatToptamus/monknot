# Monknot product site

Dependency-free implementation of the approved Monknot website design. The product imagery in
`shots/` is copied unchanged from the supplied design source.

```sh
cd website
npm run check
npm run build
npm run preview
```

The production output is written to `website/dist`. The repository-level `vercel.json` runs the
build and serves that directory, so the repository can be deployed without a custom root-directory
or build setting.
