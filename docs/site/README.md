# Gosti docs site

The **Gosti documentation site**, published at
<https://metacraft-labs.github.io/gosti/>. It renders the Markdown in
`content/`, the only copy of the user guide, through the
[isonim-docs](https://github.com/metacraft-labs/isonim-docs) static-site
framework, themed by the shared
[Metacraft docs design system](https://github.com/metacraft-labs/codetracer-design-system).

## Self-contained — no sibling checkouts

Unlike the CodeTracer book (which reuses sibling `isonim` / `isonim-docs`
checkouts), this site is a **standalone repo**, so it declares the whole
framework toolchain and source as flake **inputs** in [`flake.nix`](./flake.nix):
`isonim`, `isonim-docs`, `nim-everywhere`, `nim-faststreams`, `nim-stew`, and
`codetracer-design-system`. The dev shell exports each input's Nix store path as
a `GOSTI_DOCS_*` env var; [`config.nims`](./config.nims) reads them and adds the
right `nim --path`, and passes the design-system root on to
[`src/theme_tokens.nim`](./src/theme_tokens.nim) as the `gostiDocsDesignSystem`
compile-time define (that token JSON is `staticRead`, so it must be known at
compile time). When those env vars are unset, `config.nims` falls back to
sibling paths — so a legacy workspace checkout still works too.

## Prerequisites

Every task runs inside **this site's own dev shell** (provides `nim`, `just`,
`node`). With **direnv** it activates on `cd` (see `./.envrc`):

```bash
cd docs/site
just build
```

Without direnv, enter the flake once (or prefix a single recipe):

```bash
nix develop ./docs/site           # this site's self-contained shell
just build
# or:
nix develop ./docs/site -c just build
```

## Build, preview, test

```bash
just build         # static build into ./public/ (what the Pages workflow deploys)
just dev-docs      # http://127.0.0.1:8000 live-reload preview
just open-docs     # open the running server in a browser
just serve-docs    # one-shot SSR preview
just test          # SSG smoke + basePath test
```

## Where things live

| Path | What |
|------|------|
| `content/index.md` | The landing page (hero + start-here cards + popular articles) |
| `content/getting_started/`, `guides/`, `reference/` | The three doc sections (order via each page's `order:` front matter + `sectionOrder` in `src/docs_config.nim`) |
| `src/docs_config.nim` | Site config: title, `basePath` (`/gosti`), header/sidebar chrome, section order |
| `src/theme_tokens.nim` | Loads the shared design system (self-contained via the `gostiDocsDesignSystem` define) |
| `src/{build,dev,ssr,redirects}.nim` | Build/serve entry points |
| `assets/style.css` | The shared docs stylesheet (theme + WebFlow-parity layout) |
| `static/` | Fonts + chrome icons |
| `flake.nix` / `.envrc` | The self-contained dev shell (framework as inputs) |

`content/` is the source Markdown; edit the user guide there.

## Hosting

Served at a GitHub **project** Pages subpath, so `src/docs_config.nim` sets
`basePath = "/gosti"` (the framework prefixes every internal root-relative
URL) and `baseUrl` carries the same subpath for canonical/sitemap URLs.
Deployment is `.github/workflows/docs-pages.yml` (build via this flake → upload
`public/` → `actions/deploy-pages`).
