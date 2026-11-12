#!/usr/bin/env python3
"""Builds the Daily Briefs intro into one self-contained HTML file for the app bundle.

The app's source folder is an Xcode synchronized group, which copies resources flat into the
bundle, so a folder of assets would collide (two chevron-right.svg files, for example). This
inlines the CSS, the script, the fonts and every asset as data: URLs instead.

    python3 scripts/daily_brief_intro/build.py

Edit the files in src/, then run this. Output: Dayflow/Dayflow/Resources/DailyBriefIntro.html
"""
import base64
import mimetypes
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "src"
REPO = HERE.parent.parent
FONTS = REPO / "Dayflow/Dayflow/Fonts"
OUT = REPO / "Dayflow/Dayflow/Resources/DailyBriefIntro.html"

TYPES = {".svg": "image/svg+xml", ".png": "image/png", ".webp": "image/webp",
         ".jpg": "image/jpeg", ".ttf": "font/ttf"}


def data_url(path: Path) -> str:
    kind = TYPES.get(path.suffix) or mimetypes.guess_type(path.name)[0]
    return f"data:{kind};base64," + base64.b64encode(path.read_bytes()).decode()


def inline_assets(text: str) -> str:
    def swap(match):
        path = SRC / match.group(0)
        if not path.exists():
            raise SystemExit(f"missing asset: {match.group(0)}")
        return data_url(path)
    return re.sub(r"assets/[A-Za-z0-9_./-]+\.(?:svg|png|webp|jpg)", swap, text)


fonts = f"""
@font-face {{ font-family: "Figtree"; font-weight: 300 900; src: url("{data_url(FONTS / "Figtree-VariableFont_wght.ttf")}") format("truetype"); }}
@font-face {{ font-family: "Instrument Serif"; font-weight: 400; src: url("{data_url(FONTS / "InstrumentSerif-Regular.ttf")}") format("truetype"); }}
"""

# Assets the script names at runtime ("assets/pets/clawd/" + id + ".svg"), as a lookup table.
runtime = {f"assets/pets/clawd/{p.name}": data_url(p) for p in sorted((SRC / "assets/pets/clawd").glob("*.svg"))}
runtime_js = "window.INTRO_ASSETS = {" + ",".join(f'"{k}":"{v}"' for k, v in runtime.items()) + "};\n"

html = (SRC / "index.html").read_text()
# Drop the block that only exists so src/ can be opened in a browser.
html = re.sub(r"\s*<!-- dev-only: start.*?<!-- dev-only: end -->", "", html, flags=re.S)
css = fonts + (SRC / "intro.css").read_text()
js = (SRC / "intro.js").read_text()

html = html.replace('<link rel="stylesheet" href="intro.css">', "<style>\n" + css + "\n</style>")
html = html.replace('<script src="intro.js"></script>', "<script>\n" + js + "\n</script>")
assert "<style>" in html and "<script>\n" in html, "template placeholders changed"
html = inline_assets(html)
# (added after inlining, so its "assets/..." keys stay as they are)
html = html.replace("<script>\n", "<script>\n" + runtime_js, 1)

leftover = [a for a in re.findall(r"assets/[^\"')\s]+", html)
            if a not in runtime and a != "assets/pets/clawd/"]
assert not leftover, f"not inlined: {leftover[:5]}"
OUT.write_text(html)
print(f"wrote {OUT.relative_to(REPO)} ({OUT.stat().st_size / 1_000_000:.1f} MB)")
