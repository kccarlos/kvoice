# The KVoice website

The source of <https://kccarlos.github.io/kvoice/>: the home page, the
KVoice for Mac and KVoice for iPhone pages, and the privacy and support
pages, in English and Simplified Chinese. The privacy and support pages are
also the App Store privacy and support URLs.

Plain HTML, CSS and JavaScript. There is no build step, no framework, and
nothing loaded from another site: no CDN, fonts, analytics or trackers.
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) publishes
this folder to GitHub Pages when it changes on `main`, leaving out this
README.

## Files

| Path | What it is |
| --- | --- |
| `index.html`, `mac/`, `ios/`, `privacy/`, `support/` | The English pages. **Edit these.** |
| `zh/` | The Chinese pages. **Generated; never edit by hand.** |
| `styles.css` | All styles. Colours are the apps' own tokens: the Mac app's palette (orange for voice, blue for text, the icon's navy) and iOS system colours for the iPhone mockups, each with a light and a dark value. |
| `app.js` | Copy buttons, scroll reveal, demo videos, and the animated mockups. |
| `assets/` | Icons (`icons.svg` is the symbol sprite), app icons, Open Graph images (`og-en.png` and `og-zh.png` for most pages, `og-mac-*.jpg` and `og-ios-*.jpg` for the Mac and iPhone pages), the demo videos with their posters, and screenshots. |
| `sitemap.xml` | Generated. |
| `404.html`, `robots.txt`, `site.webmanifest`, `favicon.ico` | Hand-written. |

## Editing a page

Every element with Chinese text carries it in `data-zh` (its inner HTML), or
`data-zh-<attribute>` for one attribute, such as `data-zh-content` on a meta
tag or `data-zh-aria-label`:

```html
<p data-zh="说一次，成稿直接打在你正在用的地方。">Speak once. Get finished text, typed where you work.</p>
```

Then regenerate:

```sh
python3 Scripts/render_site.py           # writes zh/, sitemap.xml, the header, footer and SEO lines
python3 Scripts/render_site.py --check   # changes nothing; fails if anything is stale or broken
```

The script (standard library only) also writes each page's shared header and
footer, canonical and `hreflang` links, Open Graph URLs and structured data
(JSON-LD, including an FAQ entry built from each page's
`<details class="faq">` questions; a question the Support page shares with
the Mac or iPhone page is marked up only there). The Mac app's
`softwareVersion` comes from the newest release heading in `../CHANGELOG.md`.
It fails on a link or `#anchor` that leads nowhere, on a mockup whose markup
is not its own finished frame, on a heading (`h1`–`h6`) inside a mockup
(anything with `role="img"`), and on an English FAQ entry whose structured
data holds Chinese text or markup.
The Pages workflow runs `--check` before it publishes, so a stale Chinese
page never goes live.

A comparison table with `class="stack"` turns into one card per row on
phones; give each `<td>` a `data-label` (and `data-zh-data-label`) naming its
column.

The iPhone app's interface is in English, so its mockups keep their English
labels on the Chinese pages too, and the Chinese text explains them. The Mac
app is localized, so its mockups use the app's Chinese wording.

## The TestFlight link

KVoice for iPhone is distributed through a public TestFlight beta at
<https://testflight.apple.com/join/WzN5CnG6>. The link lives in the
`TESTFLIGHT_URL` constant at the top of `app.js` and in the `href` of every
link marked `data-testflight` (which keeps the links working without
JavaScript); the render script copies it into the footer and into the iPhone
app's structured data (`downloadUrl`). To change it, replace the URL
everywhere under `site/` and run `python3 Scripts/render_site.py`. A
`--check` fails while the constant and any link disagree, and if the old
placeholder `REPLACE_ME` ever appears under `site/` again.

## Animated mockups

A mockup that plays has `data-steps` with one duration per step, in
milliseconds. At step *n*, every element inside it whose `data-show` range
includes *n* gets the class `on`, and `data-cls="name@range"` toggles a class
by step. `data-type` types its text, `data-words` reveals spoken words,
`data-clock` counts seconds. Stages play only while on screen and restart
from the first step when they come back.

The markup itself is the finished frame: whatever carries `on` in the HTML
is what visitors see with reduced motion, without JavaScript, or before the
stage plays. `data-final` names that step (the last one by default), and the
render script checks that the HTML matches it.

## Checking a change locally

The site lives under `/kvoice/` on GitHub Pages, and every link is relative,
so serve it from a folder that mounts it at that path:

```sh
mkdir -p /tmp/kvoice-site && ln -sfn "$PWD/site" /tmp/kvoice-site/kvoice
python3 -m http.server 8000 --directory /tmp/kvoice-site
# open http://localhost:8000/kvoice/
```

Look at both languages, light and dark, a phone-sized window, and with
reduced motion turned on.

## Images that are rendered, not drawn by hand

The Open Graph images and the demo video posters are pictures of the site's
own mockups and of the videos. Re-make them when the mockups or videos
change: the posters are a frame of each video (`ffmpeg -ss 8.6 -i
demo-en.mp4 -frames:v 1`, saved as WebP), and the Open Graph images are
1200 x 630 screenshots of a card that uses `styles.css`, saved as JPEG.

## Search engines

GitHub Pages serves this site from a subpath, so search engines do not read
`robots.txt` here (they only read it at the root of a host). Submit
`https://kccarlos.github.io/kvoice/sitemap.xml` in a search console instead.
