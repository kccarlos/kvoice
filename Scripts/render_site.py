#!/usr/bin/env python3
"""Render the generated parts of site/ (https://kccarlos.github.io/kvoice/).

The English pages are the source. An element with a Chinese version carries
it in data-zh (its inner HTML) or data-zh-<attr> (one attribute, for example
data-zh-content or data-zh-aria-label). This script, standard library only:

- writes the shared header and footer of every page between
  <!-- header:begin/end --> and <!-- footer:begin/end -->;
- writes each page's canonical, hreflang and Open Graph URL lines between
  <!-- seo:begin/end -->, and its structured data (JSON-LD: the apps, the
  breadcrumb, and an FAQPage built from the page's own <details class="faq">
  questions, in the page's language) between <!-- jsonld:begin/end -->;
- writes the Chinese copy of each page under zh/, and sitemap.xml;
- checks what a hand edit can break: links and #anchors that lead nowhere,
  a TestFlight link that differs from TESTFLIGHT_URL in app.js, an
  animated mockup whose markup is not its own finished frame (see app.js),
  a heading inside a mockup (role="img"), and an English FAQ entry with
  Chinese text or stray markup in its structured data;
- fails if the old TestFlight placeholder (REPLACE_ME) appears anywhere in site/.

Usage: python3 Scripts/render_site.py [--check]
  --check  change nothing; exit 1 if a generated file is out of date or a
           check fails.
"""
import html
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
BASE = "https://kccarlos.github.io/kvoice/"
GITHUB_MAC = "https://github.com/kccarlos/kvoice"
GITHUB_IOS = "https://github.com/kccarlos/kvoice-ios"
RELEASES = GITHUB_MAC + "/releases/latest"
AUTHOR = {"@type": "Person", "name": "kccarlos", "url": "https://github.com/kccarlos"}
PLACEHOLDER = "REPLACE_ME"
CJK = re.compile(r"[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]")
# Any attributes of a tag, quoted values included (a data-zh value can hold '>').
ATTRS = r'(?:\s+[\w:-]+(?:="[^"]*")?)*\s*'
# Each page's Open Graph image: (English, Chinese) file under assets/.
OG_IMAGES = {"mac/": ("og-mac-en.jpg", "og-mac-zh.jpg"), "ios/": ("og-ios-en.jpg", "og-ios-zh.jpg")}
OG_DEFAULT = ("og-en.png", "og-zh.png")
# The demo videos on the home page (seconds, from ffprobe; first published 2026-10-20).
VIDEO = {"en": ("assets/demo-en.mp4", "assets/demo-en-poster.webp", 24),
         "zh": ("assets/demo-zh.mp4", "assets/demo-zh-poster.webp", 22)}
VIDEO_UPLOADED = "2026-10-20"
ZH = "zh/"
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

# English page path -> (English name, Chinese name) for the navigation and breadcrumbs.
PAGES = {
    "": ("Home", "首页"),
    "mac/": ("KVoice for Mac", "KVoice Mac 版"),
    "ios/": ("KVoice for iPhone", "KVoice iPhone 版"),
    "privacy/": ("Privacy", "隐私"),
    "support/": ("Support", "支持"),
}

errors = []


def fail(message):
    errors.append(message)


def between(page, name, body, where):
    begin, end = "<!-- %s:begin -->" % name, "<!-- %s:end -->" % name
    head, sep1, rest = page.partition(begin)
    _, sep2, tail = rest.partition(end)
    if not (sep1 and sep2):
        sys.exit("%s: missing %s / %s markers" % (where, begin, end))
    return head + begin + body + end + tail


def attr(name, value):
    return ' %s="%s"' % (name, html.escape(value, quote=True))


def rel(src, dst):
    """Relative link from page path src to page path dst (both like 'zh/mac/')."""
    return "../" * src.count("/") + dst or "./"


def mac_version():
    """The newest released version in CHANGELOG.md (the Mac app's)."""
    match = re.search(r"^## (\d+\.\d+(?:\.\d+)?)\b", (ROOT / "CHANGELOG.md").read_text(encoding="utf-8"), flags=re.M)
    if not match:
        sys.exit("CHANGELOG.md: no released version heading")
    return match.group(1)


def testflight_url():
    match = re.search(r"const TESTFLIGHT_URL = '([^']+)'", (SITE / "app.js").read_text(encoding="utf-8"))
    if not match:
        sys.exit("app.js: TESTFLIGHT_URL not found")
    return match.group(1)


# ---------------------------------------------------------------- shared chrome

def zh_attr(en, zh):
    return attr("data-zh", zh) if zh != en else ""


def render_header(path):
    r = rel(path, "")
    r = "" if r == "./" else r
    links = []
    for target, (en, zh) in (("mac/", ("Mac", "Mac")), ("ios/", ("iPhone", "iPhone")),
                             ("privacy/", ("Privacy", "隐私")), ("support/", ("Support", "支持"))):
        current = ' aria-current="page"' if target == path else ""
        links.append('<a href="%s%s"%s%s>%s</a>' % (r, target, current, zh_attr(en, zh), en))
    lang = ('<a class="lang" href="%s" hreflang="zh-Hans" lang="zh-Hans" data-zh="English" data-zh-href="%s" '
            'data-zh-hreflang="en" data-zh-lang="en">中文</a>' % (rel(path, ZH + path), rel(ZH + path, path)))
    return (
        '\n<header class="bar"><div class="bar-in">\n'
        '<a class="brand" href="%s"><img src="%sassets/kvoice-mac.svg" alt="" width="30" height="30"><span>KVoice</span></a>\n'
        '<nav class="nav" aria-label="Main"%s>%s</nav>\n%s\n'
        '<a class="gh" href="%s"><svg class="i" aria-hidden="true"><use href="%sassets/icons.svg#github"/></svg><span>GitHub</span></a>\n'
        '</div></header>\n'
        % (rel(path, ""), r, attr("data-zh-aria-label", "主导航"), "".join(links), lang, GITHUB_MAC, r)
    )


def render_footer(path):
    r = rel(path, "")
    r = "" if r == "./" else r

    def li(href, en, zh):
        return '<li><a href="%s"%s>%s</a></li>' % (href, zh_attr(en, zh), en)

    cols = [
        ("KVoice for Mac", "KVoice Mac 版", [
            li(r + "mac/", "Overview and tutorial", "介绍与教程"),
            li(RELEASES, "Download the DMG", "下载 DMG"),
            li(GITHUB_MAC, "Source code on GitHub", "GitHub 源代码"),
            li(GITHUB_MAC + "/issues", "Report a Mac bug", "报告 Mac 版问题"),
        ]),
        ("KVoice for iPhone", "KVoice iPhone 版", [
            li(r + "ios/", "Overview and setup", "介绍与设置"),
            '<li><a href="%s" data-testflight%s>Join the TestFlight beta</a></li>' % (testflight_url(), attr("data-zh", "加入 TestFlight 测试")),
            li(GITHUB_IOS, "Source code on GitHub", "GitHub 源代码"),
            li(GITHUB_IOS + "/issues", "Report an iPhone bug", "报告 iPhone 版问题"),
        ]),
        ("Help", "帮助", [
            li(r + "support/", "Support and FAQ", "支持与常见问题"),
            li(r + "privacy/", "Privacy", "隐私"),
            li(GITHUB_MAC + "/blob/main/Docs/User-Guide.md", "Mac User Guide", "Mac 用户指南（英文）"),
            li(GITHUB_MAC + "/blob/main/CHANGELOG.md", "What's new", "更新记录（英文）"),
        ]),
    ]
    blocks = "".join(
        '<div><p class="foot-h"%s>%s</p><ul>%s</ul></div>' % (zh_attr(en, zh), en, "".join(items)) for en, zh, items in cols)
    return (
        '\n<footer class="foot"><div class="wrap">\n<div class="foot-grid">\n'
        '<div><a class="brand" href="%s"><img src="%sassets/kvoice-mac.svg" alt="" width="30" height="30"><span>KVoice</span></a>\n'
        '<p%s>Speak once. Get finished text, typed where you work. Free and open source dictation for Mac and iPhone.</p></div>\n'
        '%s\n</div>\n'
        '<p class="legal"%s>KVoice is free software under the MIT license. Not affiliated with Apple. Apple, Mac, iPhone, macOS, iOS, Apple Intelligence and TestFlight are trademarks of Apple Inc.</p>\n'
        '</div></footer>\n'
        % (rel(path, ""), r,
           attr("data-zh", "说一次，成稿直接打在你正在用的地方。适用于 Mac 和 iPhone 的免费开源语音输入。"),
           blocks,
           attr("data-zh", "KVoice 是采用 MIT 许可证的自由软件，与 Apple 无关联。Apple、Mac、iPhone、macOS、iOS、Apple 智能和 TestFlight 是 Apple Inc. 的商标。"))
    )


def render_seo(path):
    en, zh = BASE + path, BASE + ZH + path
    og_en, og_zh = OG_IMAGES.get(path, OG_DEFAULT)
    lines = [
        '<link rel="canonical" href="%s" data-zh-href="%s">' % (en, zh),
        '<link rel="alternate" hreflang="en" href="%s">' % en,
        '<link rel="alternate" hreflang="zh-Hans" href="%s">' % zh,
        '<link rel="alternate" hreflang="x-default" href="%s">' % en,
        '<meta property="og:url" content="%s" data-zh-content="%s">' % (en, zh),
        '<meta property="og:locale" content="en_US" data-zh-content="zh_CN">',
        '<meta property="og:locale:alternate" content="zh_CN" data-zh-content="en_US">',
        '<meta property="og:image" content="%sassets/%s" data-zh-content="%sassets/%s">' % (BASE, og_en, BASE, og_zh),
        '<meta name="twitter:image" content="%sassets/%s" data-zh-content="%sassets/%s">' % (BASE, og_en, BASE, og_zh),
    ]
    return "\n" + "\n".join(lines) + "\n"


# ---------------------------------------------------------------- structured data

TEXT = {
    "mac_desc": (
        "A Mac dictation app: hold a shortcut, speak, and finished text is typed into any app. On-device speech to text with Whisper and other local models, plus optional AI actions that clean up, write an email, make a TODO list or translate.",
        "Mac 语音输入应用：按住快捷键说话，成稿直接打进任何应用。用 Whisper 等本地模型在本机完成语音转文字，还可选用 AI 操作整理文字、写邮件、列待办或翻译。"),
    "ios_desc": (
        "A private voice-to-text keyboard for iPhone: dictate into any app from the KVoice keyboard, the Action Button, Control Center or Siri. On-device speech recognition and optional AI modes.",
        "iPhone 上的私密语音输入键盘：用 KVoice 键盘、操作按钮、控制中心或 Siri，在任何应用里语音输入。本机语音识别，可选 AI 模式。"),
    "video_desc": (
        "Hold a key and speak, and the words are typed into TextEdit. The same messy sentence becomes a clean transcript, a TODO list or another language, and a spoken request lands in a terminal.",
        "按住快捷键说话，文字打进“文本编辑”；同一段随口说的话，变成整理好的文字、待办清单或另一种语言；口述的需求直接打进终端。"),
    "site_desc": (
        "KVoice: free, open-source dictation for Mac and iPhone. Speak once and get finished text, typed where you work.",
        "KVoice：免费开源的 Mac 与 iPhone 语音输入。说一次，成稿直接打在你正在用的地方。"),
}


def t(key, lang):
    en, zh = TEXT[key]
    return zh if lang == "zh" else en


def mac_app(lang, url):
    return {
        "@type": "SoftwareApplication",
        "name": "KVoice",
        "alternateName": "KVoice for Mac",
        "url": url,
        "description": t("mac_desc", lang),
        "applicationCategory": "UtilitiesApplication",
        "applicationSubCategory": "Dictation",
        "operatingSystem": "macOS 15 or later",
        "processorRequirements": "Apple silicon",
        "softwareRequirements": "macOS 15 or later on a Mac with Apple silicon",
        "downloadUrl": RELEASES,
        "installUrl": RELEASES,
        "image": BASE + "assets/kvoice-mac-256.png",
        "screenshot": [BASE + "assets/kvoice-1-dictate.webp", BASE + "assets/kvoice-2-ai-actions.webp"],
        "softwareVersion": mac_version(),
        "author": AUTHOR,
        "inLanguage": ["en", "zh-Hans"],
        "isAccessibleForFree": True,
        "license": "https://opensource.org/licenses/MIT",
        "codeRepository": GITHUB_MAC,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    }


def ios_app(lang, url):
    app = {
        "@type": "MobileApplication",
        "name": "KVoice Dictation",
        "alternateName": "KVoice for iPhone",
        "url": url,
        "description": t("ios_desc", lang),
        "applicationCategory": "ProductivityApplication",
        "applicationSubCategory": "Dictation keyboard",
        "operatingSystem": "iOS 26 or later",
        "image": BASE + "assets/kvoice-ios-256.png",
        "author": AUTHOR,
        "inLanguage": "en",
        "isAccessibleForFree": True,
        "license": "https://opensource.org/licenses/MIT",
        "codeRepository": GITHUB_IOS,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    }
    app["downloadUrl"] = testflight_url()
    return app


def video(lang):
    src, poster, seconds = VIDEO[lang]
    return {
        "@type": "VideoObject",
        "name": "演示：Mac 上的 KVoice" if lang == "zh" else "KVoice on a Mac: demo",
        "description": t("video_desc", lang),
        "thumbnailUrl": BASE + poster,
        "contentUrl": BASE + src,
        "uploadDate": VIDEO_UPLOADED,
        "duration": "PT%dS" % seconds,
        "inLanguage": "zh-Hans" if lang == "zh" else "en",
    }


def breadcrumb(path, lang):
    prefix = BASE + (ZH if lang == "zh" else "")
    items = [("", PAGES[""])]
    if path:
        items.append((path, PAGES[path]))
    return {
        "@type": "BreadcrumbList",
        "itemListElement": [
            {"@type": "ListItem", "position": i + 1, "name": names[1] if lang == "zh" else names[0], "item": prefix + p}
            for i, (p, names) in enumerate(items)
        ],
    }


BLOCK_TAGS = r"</?(?:p|div|li|ol|ul|br|h[1-6]|table|tr|td|th)\b[^>]*>"


def plain(fragment):
    """Text of an HTML fragment: block tags become spaces, inline tags vanish."""
    text = re.sub(BLOCK_TAGS, " ", fragment)
    text = re.sub(r"<[^>]+>", "", text)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def faq_items(page):
    items = []
    for block in re.findall(r'<details class="faq"' + ATTRS + r'>(.*?)</details>', page, flags=re.S):
        question = re.search(r"<summary" + ATTRS + r">(.*?)</summary>", block, flags=re.S)
        answer = re.search(r'<div class="a"' + ATTRS + r'>(.*)</div>', block, flags=re.S)
        if question and answer:
            items.append({"@type": "Question", "name": plain(question.group(1)),
                          "acceptedAnswer": {"@type": "Answer", "text": plain(answer.group(1))}})
    return items


def check_faq(path, items):
    for item in items:
        for text in (item["name"], item["acceptedAnswer"]["text"]):
            if CJK.search(text) or '">' in text or "<" in text:
                fail("%sindex.html: FAQ structured data is not plain English: %r" % (path, text[:80]))


# Questions also answered on the Mac or iPhone page are marked up there only.
FAQ_OWNERS = {"support/": ("mac/", "ios/")}


def duplicate_faqs(path):
    """Positions of this page's FAQ entries whose English question another page owns."""
    owners = FAQ_OWNERS.get(path, ())
    if not owners:
        return set()
    taken = {q["name"] for p in owners for q in faq_items((SITE / p / "index.html").read_text(encoding="utf-8"))}
    mine = faq_items((SITE / path / "index.html").read_text(encoding="utf-8"))
    return {i for i, q in enumerate(mine) if q["name"] in taken}


def render_jsonld(path, lang, page):
    url = BASE + (ZH if lang == "zh" else "") + path
    graph = []
    if path == "":
        graph.append({"@type": "WebSite", "name": "KVoice", "url": BASE + (ZH if lang == "zh" else ""),
                      "description": t("site_desc", lang), "inLanguage": "zh-Hans" if lang == "zh" else "en"})
        graph.append({"@type": "Organization", "name": "KVoice", "url": BASE,
                      "logo": BASE + "assets/icon-512.png", "sameAs": [GITHUB_MAC, GITHUB_IOS]})
        graph.append(mac_app(lang, BASE + (ZH if lang == "zh" else "") + "mac/"))
        graph.append(ios_app(lang, BASE + (ZH if lang == "zh" else "") + "ios/"))
        graph.append(video(lang))
    elif path == "mac/":
        graph.append(mac_app(lang, url))
    elif path == "ios/":
        graph.append(ios_app(lang, url))
    if path:
        graph.append(breadcrumb(path, lang))
    faqs = faq_items(page)
    if lang == "en":
        check_faq(path, faqs)
    skip = duplicate_faqs(path)
    faqs = [q for i, q in enumerate(faqs) if i not in skip]
    if faqs:
        graph.append({"@type": "FAQPage", "mainEntity": faqs})
    data = {"@context": "https://schema.org", "@graph": graph}
    body = json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")
    return '\n<script type="application/ld+json">\n%s\n</script>\n' % body


def render_sitemap():
    urls = []
    for path in PAGES:
        alts = "".join('\n    <xhtml:link rel="alternate" hreflang="%s" href="%s"/>' % (lang, url)
                       for lang, url in (("en", BASE + path), ("zh-Hans", BASE + ZH + path), ("x-default", BASE + path)))
        for loc in (BASE + path, BASE + ZH + path):
            urls.append("  <url>\n    <loc>%s</loc>%s\n  </url>" % (loc, alts))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(urls) + "\n</urlset>\n")


# ---------------------------------------------------------------- Chinese pages

LINK_ATTRS = ("href", "src", "poster")


def is_file_link(url):
    """A relative link to a file (styles.css, ../assets/x.png), not to a page or an anchor."""
    if not url or url[0] in "#/" or re.match(r"[a-z][a-z0-9+.-]*:", url):
        return False
    return "." in url.split("?")[0].split("#")[0].rsplit("/", 1)[-1]


class Chinese(HTMLParser):
    """Copies a page one directory deeper, with its data-zh content swapped in."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.out = []
        self.skip = 0  # depth inside an element whose content was replaced

    def tag(self, tag, attrs, close):
        values = dict(attrs)
        if not any(k.startswith("data-zh") or (k in LINK_ATTRS and is_file_link(v or "")) for k, v in attrs):
            return self.get_starttag_text()
        parts = []
        for k, v in attrs:
            if k.startswith("data-zh"):
                continue
            if "data-zh-" + k in values:
                v = values["data-zh-" + k]
            if k in LINK_ATTRS and is_file_link(v or ""):
                v = "../" + v
            parts.append(" " + k if v is None else attr(k, v))
        return "<%s%s%s>" % (tag, "".join(parts), " /" if close else "")

    def handle_starttag(self, tag, attrs):
        if self.skip:
            if tag not in VOID:
                self.skip += 1
            return
        self.out.append(self.tag(tag, attrs, False))
        zh = dict(attrs).get("data-zh")
        if zh is not None and tag not in VOID:
            self.out.append(zh if tag in ("script", "title") else convert(zh))
            self.skip = 1

    def handle_startendtag(self, tag, attrs):
        if not self.skip:
            self.out.append(self.tag(tag, attrs, True))

    def handle_endtag(self, tag):
        if self.skip:
            self.skip -= 1
            if self.skip:
                return
        self.out.append("</%s>" % tag)

    def emit(self, text):
        if not self.skip:
            self.out.append(text)

    def handle_data(self, data):
        self.emit(data)

    def handle_entityref(self, name):
        self.emit("&%s;" % name)

    def handle_charref(self, name):
        self.emit("&#%s;" % name)

    def handle_comment(self, data):
        self.emit("<!--%s-->" % data)

    def handle_decl(self, decl):
        self.emit("<!%s>" % decl)


def convert(markup):
    parser = Chinese()
    parser.feed(markup)
    parser.close()
    return "".join(parser.out)


# ---------------------------------------------------------------- checks

class Scan(HTMLParser):
    """Collects ids, links, TestFlight links and the mockup frames of a page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids, self.links, self.testflight, self.problems = set(), [], [], []
        self.stack = []  # (tag, opens a stage, opens a mockup)
        self.stages = []
        self.mockups = 0  # depth inside role="img"

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            if a["id"] in self.ids:
                self.problems.append("duplicate id %r" % a["id"])
            self.ids.add(a["id"])
        for k in LINK_ATTRS:
            if a.get(k):
                self.links.append(a[k])
        if "data-testflight" in a:
            self.testflight.append(a.get("href", ""))
        classes = (a.get("class") or "").split()
        if self.mockups and re.fullmatch(r"h[1-6]", tag):
            self.problems.append("<%s> inside a mockup (role=img): use a <div> or <b>, not a heading" % tag)
        stage = self.stages[-1] if self.stages else None
        if "data-steps" in a:
            if stage:
                self.problems.append("nested stage %r" % a.get("id"))
            count = len(a["data-steps"].split(","))
            final = int(a.get("data-final", count - 1))
            variant = (a.get("data-variants") or "").split(",")[0] or None
            stage = {"count": count, "final": final, "variant": variant, "name": a.get("id") or a.get("aria-label", "")[:40]}
            self.stages.append(stage)
        if stage and "data-show" in a:
            steps = steps_of(a["data-show"], stage["count"])
            v = a.get("data-variant")
            want = stage["final"] in steps and (not v or not stage["variant"] or stage["variant"] in v.split())
            if want != ("on" in classes):
                self.problems.append("stage %s: <%s data-show=%r%s> should %shave class on (finished frame = step %d)"
                                     % (stage["name"], tag, a["data-show"], " data-variant=%r" % v if v else "",
                                        "" if want else "not ", stage["final"]))
        if stage and "data-cls" in a:
            for rule in a["data-cls"].split(";"):
                cls, at = rule.split("@")
                want = stage["final"] in steps_of(at, stage["count"])
                if want != (cls.strip() in classes):
                    self.problems.append("stage %s: <%s data-cls=%r> should %shave class %s"
                                         % (stage["name"], tag, a["data-cls"], "" if want else "not ", cls.strip()))
        if tag not in VOID:
            img = a.get("role") == "img"
            self.mockups += img
            self.stack.append((tag, "data-steps" in a, img))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack:
            self.stack.pop()

    def handle_endtag(self, tag):
        while self.stack:
            open_tag, is_stage, img = self.stack.pop()
            if is_stage:
                self.stages.pop()
            self.mockups -= img
            if open_tag == tag:
                break


def steps_of(text, count):
    steps = set()
    for part in text.split(","):
        part = part.strip()
        if part == "*":
            steps.update(range(count))
            continue
        a, _, b = part.partition("-")
        steps.update(range(int(a), int(b or a) + 1))
    return steps


def check_pages(files):
    scans = {}
    for where, content in files.items():
        if where.suffix != ".html":
            continue
        scan = Scan()
        scan.feed(content)
        scans[where] = scan
        name = where.relative_to(SITE)
        for problem in scan.problems:
            fail("%s: %s" % (name, problem))
        for href in scan.testflight:
            if href != testflight_url():
                fail("%s: a data-testflight link is %r, but app.js says %r" % (name, href, testflight_url()))
        if "data-zh" in content and name.parts[0] == "zh":
            fail("%s: data-zh is left in the Chinese page (unbalanced tags?)" % name)
        for block in re.findall(r'<script type="application/ld\+json">(.*?)</script>', content, flags=re.S):
            try:
                json.loads(block)
            except ValueError as error:
                fail("%s: JSON-LD does not parse: %s" % (name, error))
    for where, scan in scans.items():
        name = where.relative_to(SITE)
        for link in scan.links:
            if re.match(r"[a-z][a-z0-9+.-]*:", link) or link.startswith("//"):
                continue
            path, _, fragment = link.partition("#")
            path = path.split("?")[0]
            if path.startswith("/"):
                continue  # only the 404 page uses root links, under its <base>
            target = (where.parent / path).resolve() if path else where
            if target.is_dir() or path.endswith("/") or path in ("", ".", ".."):
                target = target / "index.html" if path else target
            if target != where and not target.exists() and target not in files:
                fail("%s: link %r leads nowhere" % (name, link))
                continue
            if fragment and target.suffix == ".html":
                ids = scans[target].ids if target in scans else set()
                if fragment not in ids:
                    fail("%s: link %r: no id %r there" % (name, link, fragment))


# ---------------------------------------------------------------- everything

def outputs():
    """Every generated file: path -> content."""
    files = {}
    for path in PAGES:
        where = SITE / path / "index.html"
        page = where.read_text(encoding="utf-8")
        page = between(page, "header", render_header(path), where)
        page = between(page, "footer", render_footer(path), where)
        page = between(page, "seo", render_seo(path), where)
        page = between(page, "jsonld", "", where)
        zh = convert(page)
        files[where] = between(page, "jsonld", render_jsonld(path, "en", page), where)
        files[SITE / ZH / path / "index.html"] = between(zh, "jsonld", render_jsonld(path, "zh", zh), where)
    files[SITE / "sitemap.xml"] = render_sitemap()
    return files


def main():
    args = sys.argv[1:]
    if args not in ([], ["--check"]):
        sys.exit("usage: python3 Scripts/render_site.py [--check]")
    check = args == ["--check"]
    files = outputs()
    for extra in (SITE / "404.html",):
        files.setdefault(extra, extra.read_text(encoding="utf-8"))
    check_pages(files)
    for where in sorted(set(files) | {p for p in SITE.rglob("*") if p.suffix in (".html", ".js", ".xml", ".txt", ".webmanifest")}):
        content = files.get(where) or where.read_text(encoding="utf-8")
        if PLACEHOLDER in content:
            fail("%s: the TestFlight placeholder %s is back; use the real link" % (where.relative_to(SITE), PLACEHOLDER))
    stale = []
    for where, content in files.items():
        if not where.exists() or where.read_text(encoding="utf-8") != content:
            stale.append(str(where.relative_to(ROOT)))
            if not check:
                where.parent.mkdir(parents=True, exist_ok=True)
                where.write_text(content, encoding="utf-8")
    for message in errors:
        print("render_site: " + message, file=sys.stderr)
    if check and stale:
        print("render_site: out of date: %s. Run python3 Scripts/render_site.py and commit." % ", ".join(stale), file=sys.stderr)
    if errors or (check and stale):
        sys.exit(1)
    print("render_site: %s (%d pages)" % ("up to date" if check else "written", len(PAGES) * 2))


main()
