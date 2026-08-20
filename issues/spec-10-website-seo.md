# Spec 10 — Website SEO foundation: custom domain, crawlability, structured data & performance

Status: ready-for-agent
Phase: post-MVP distribution (marketing website only; no app code is touched)
Depends on: the published website under `website/` and its Pages workflow
(`.github/workflows/pages.yml`). The maintainer configures DNS
(`kallilex.webcommits.info` CNAME record) and the GitHub Pages custom-domain
setting manually; the repo-side changes in this spec assume that domain.

## Problem Statement

From a searcher's perspective: someone looking for an "offline spell checker
for mac" or a "menu bar grammar checker" will never find Kallilex. The site
ranks only for its own name, lives on a `lstoneyy.github.io/kallilex/` subpath
whose domain authority belongs to GitHub, gives crawlers no robots.txt, no
sitemap, and no structured data, ships an incomplete Twitter card with a
square 1024×1024 social image that platforms crop, and autoplays a 24 MB
video on every visit including mobile. Every backlink earned today pays into
GitHub's domain instead of the product's own — and moving later, after links
exist, costs rankings that moving now costs nothing.

## Solution

The site moves to `kallilex.webcommits.info` (CNAME file plus absolute-URL
updates). Crawlers get robots.txt, a sitemap, `SoftwareApplication` and
`FAQPage` JSON-LD, a custom 404, and complete social-card metadata with a
proper 1200×630 image. The landing page gains a small FAQ section and
keyword-sharpened title/headline copy. The demo video is re-encoded to a
fraction of its size. Registration with Google Search Console and Bing stays
a manual maintainer step documented in this spec.

## User Stories

1. As a searcher, I want the site to appear for queries like "offline spell checker mac" and "menu bar writing tool", so that I can discover Kallilex without knowing its name.
2. As a visitor following a shared link, I want a proper large social card with image and description, so that the link looks trustworthy on Slack/X/Mastodon.
3. As a search engine, I want robots.txt, a sitemap, and canonical URLs on one stable domain, so that I can crawl and index the site without guessing.
4. As a search engine, I want `SoftwareApplication` structured data (name, OS, price, license, download URL), so that I can show rich results for the app.
5. As a visitor with a question, I want a short FAQ (permissions, model support, offline behavior), so that I don't have to read the GitHub repo to decide.
6. As a mobile visitor, I want the demo video to weigh a few MB instead of 24, so that the page doesn't burn my data plan and loads fast.
7. As a visitor hitting a dead link, I want a branded 404 page with a way back home, so that I don't land on GitHub's default error page.
8. As the maintainer, I want existing `lstoneyy.github.io/kallilex/` links to keep working, so that early links and the GitHub "About" URL don't break.

## Implementation Decisions

- **Domain migration** (all in `website/`):
  - Add `website/CNAME` containing exactly `kallilex.webcommits.info`. The
    Pages deploy action (`peaceiris/actions-gh-pages@v4`) must carry it into
    the `gh-pages` branch — verify it isn't dropped by `force_orphan`; if the
    action supports `cname:`, prefer that option over a raw file.
  - Replace every absolute `https://lstoneyy.github.io/kallilex/` URL
    (canonical, `og:url`, `og:image`) with
    `https://kallilex.webcommits.info/`. GitHub redirects the old
    `*.github.io` URLs to the custom domain automatically once configured, so
    no redirect work is needed in-repo.
- **robots.txt**: allow all, plus
  `Sitemap: https://kallilex.webcommits.info/sitemap.xml`.
- **sitemap.xml**: exactly one URL — the homepage. `datenschutz.html` and
  `impressum.html` stay `noindex` and stay out of the sitemap.
- **Structured data** in `index.html`, one `<script type="application/ld+json">`
  block per type:
  - `SoftwareApplication`: name, `operatingSystem: "macOS"`,
    `applicationCategory: "UtilitiesApplication"`, description (reuse the
    meta description), `offers` with price `0` / `priceCurrency: "USD"`,
    `license` (Apache-2.0 URL), `downloadUrl` (GitHub releases page),
    `url` (the new domain), `image` (absolute icon/og URL).
  - `FAQPage` mirroring the visible FAQ section 1:1 — no invented Q&As, the
    markup must match on-page text.
- **Social cards**: switch to `twitter:card: summary_large_image`; add
  `twitter:title`, `twitter:description`, `twitter:image`. Create
  `website/assets/og-card.png` at 1200×630: dark Basalt background, the
  existing icon, wordmark "Kallilex", and the one-line tagline — composed
  from existing assets (e.g. render via ImageMagick/rsvg from `icon.svg`), no
  new artwork invented. `og:image` and `twitter:image` both point at it;
  add `og:image:width`/`og:image:height`. The old square `og-image.png`
  stays for the JSON-LD `image`.
- **404 page**: `website/404.html`, same head pattern as the legal pages
  (`noindex`, icon, dark scheme), one short message and a link to `/`.
- **Legal pages**: add self-referencing canonical links; keep `noindex`.
- **Copy sharpening** (surgical, no redesign):
  - `<title>`: "Kallilex — offline spell check & AI rewriting from the macOS
    menu bar" (keeps brand + adds "spell check"/"offline"; ~60 chars).
  - Meta description / `og:description`: keep, but ensure "spell checker"
    appears as a noun phrase, not only the verb "spell-check".
  - H1 stays the flow line, but the hero subline (line ~54 region) must
    contain "spell checker" and "menu bar" verbatim.
- **FAQ section**: new section before Install with 4–5 items: why the
  Accessibility permission is needed; which providers/models work (any
  OpenAI-compatible endpoint, local or cloud); whether spell check works
  offline (yes, NSSpellChecker, on-device); where text goes (privacy badge
  explanation); is it free (Apache-2.0, no accounts). Content sourced from
  PRD.md and existing page copy only.
- **Video re-encode**: re-encode `website/assets/demo.mp4` with ffmpeg —
  H.264, `crf` in the 28–32 range, width capped at 1600 px, audio stream
  dropped (it plays muted), `+faststart`. Target ≤ 5 MB; pick the highest
  quality that stays under it. Keep the single MP4 source (no WebM variant in
  v1). Poster, `preload="metadata"`, and the existing JS autoplay logic are
  untouched.
- No changes to `main.js` logic, the pages workflow trigger, or the app.

## Testing Decisions

- Validate both JSON-LD blocks with a schema validator (or at minimum
  `jq`-parse the extracted JSON and eyeball required fields) — invalid JSON
  in a `ld+json` block fails silently in browsers.
- `robots.txt` and `sitemap.xml` are plain files: verify the sitemap URL
  matches the new domain and parses as XML.
- Verify every occurrence of `lstoneyy.github.io` is gone from `website/`
  (`grep -r` returns nothing except, at most, historical docs).
- Verify the re-encoded video: file size ≤ 5 MB, plays in a browser, visual
  quality acceptable at the site's display size (maintainer eyeballs the
  before/after).
- After the next Pages deploy (maintainer): confirm
  `https://kallilex.webcommits.info/` serves with HTTPS, `/sitemap.xml` and
  `/robots.txt` resolve, the 404 page appears for a bogus path, and a social
  card debugger (e.g. opengraph.xyz) renders the large card.
- Lighthouse run on the deployed page before merge and after deploy;
  performance score must not regress (it should improve via the video).

## Out of Scope

- Off-page work: Search Console/Bing registration, directory submissions
  (AlternativeTo, Product Hunt, Show HN, awesome-mac), and the Homebrew cask
  (spec-08) — maintainer tasks, listed in Further Notes.
- Analytics of any kind (Plausible etc.) — separate product decision; the
  "no telemetry" positioning extends to the website until decided otherwise.
- A German version of the landing page and hreflang markup.
- Comparison/alternative landing pages ("Kallilex vs …") and a blog/changelog.
- CSS/JS minification and a build step for the website (marginal gain; the
  site stays plain static files).
- Per-OS landing sections ("Kallilex for Linux") — follows the Linux port
  (spec-11) once it ships.

## Further Notes

- Maintainer prerequisites (manual, outside the repo): DNS CNAME record
  `kallilex` → `lstoneyy.github.io` on webcommits.info; GitHub Pages custom
  domain set to `kallilex.webcommits.info` with "Enforce HTTPS" enabled once
  the certificate is issued. The repo changes in this spec are safe to merge
  before DNS is live — the CNAME file is what tells Pages to serve the domain.
- Maintainer follow-ups after deploy: register the property in Google Search
  Console (domain property, verified via DNS) and Bing Webmaster Tools,
  submit the sitemap, request indexing of the homepage; update the GitHub
  repo's About URL to the new domain.
- The GitHub API call in `main.js` (release version fetch) is unrelated to
  SEO and stays as is.
- Source of truth for product claims in FAQ/JSON-LD: PRD.md and README.md —
  no capability may be claimed that the shipped app doesn't have.
