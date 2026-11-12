#!/usr/bin/env python3
# tools/make-html-docs.py: the docs as HTML in docs/html/, one flat
# folder of lower-case names (README.md is index.html, linked as
# ./), linked without .html. The look is docs/html/style.css,
# edited by hand. Needs markdown-it-py; Pygments, if installed,
# colours the code.
import html
import io
import os
import re
import sys

from markdown_it import MarkdownIt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "html")

# SOURCES

# The general docs; single ports' READMEs and notes on third-party
# code stay out. docs/*.md is added below.
# Source -> (page, its name in the menu):
NAMED = {
    "README.md": ("index", "ZDOS"),
    "CONTRIBUTING.md": ("contributing", "CONTRIBUTING"),
    "sdk/README.md": ("sdk", "SDK"),
    "ports/README.md": ("ports", "PORTS"),
}


def sources():
    pages = dict(NAMED)
    for name in sorted(os.listdir(os.path.join(ROOT, "docs"))):
        if name.endswith(".md"):
            pages["docs/" + name] = (name[:-3].lower(), name[:-3])
    return pages


# CODE COLOURS

try:
    from pygments import highlight as pyg_highlight
    from pygments.formatters import HtmlFormatter
    from pygments.lexers import get_lexer_by_name
    from pygments.token import Token
    from pygments.util import ClassNotFound
    COMMAND = Token.Name.Command  # class "n-Command", orange
except ImportError:
    pyg_highlight = None

# A fence's language: any name Pygments knows (sql, go, swift,
# json, yaml, toml, makefile, diff, nasm ...), and these:
LEXERS = {"sh": "bash", "shell": "bash", "zsh": "bash", "cmd": "batch",
          "bat": "batch", "patch": "diff", "asm": "gas", "text": None,
          "txt": None, "plain": None}


# Shell: a command's first word, after these or at a line's start:
STARTS = {"|", "||", "&&", ";", "&", "$(", "(", "`", "then", "do",
          "else", "elif", "if", "while", "until", "!", "{"}
ENDS = {"|", "||", "&&", ";", "&", ")", "`"}
# Words whose next word is the command too:
WRAPPERS = {"sudo", "exec", "time", "env", "nohup", "command"}


def shell_commands(tokens):
    toks = list(tokens)
    at_start, after_cont, skip, in_cmd = True, False, False, False
    assigning = False  # the last word was an assignment's name
    in_value = False  # in its value, up to the next blank
    for i, (t, v) in enumerate(toks):
        word = v.strip()
        nxt = toks[i + 1][1] if i + 1 < len(toks) else " "
        if not word:
            if "\n" in v and not after_cont:
                at_start, skip = True, False
            in_cmd = in_value = False
            yield t, v
            continue
        after_cont = v.endswith("\\")
        if in_value:
            yield t, v
            continue
        if in_cmd and word not in ENDS:
            yield COMMAND, v  # the rest of the command's word:
            in_cmd = not nxt[:1].isspace()
            continue
        in_cmd = False
        if t in Token.Comment:
            # The line's break is in the comment's token:
            if "\n" in v:
                at_start, skip = True, False
            yield t, v
            continue
        # A reserved word only with a blank after it (not if=):
        reserved = t in Token.Keyword and (nxt[:1].isspace() or not nxt)
        if word in ("for", "case", "select") and reserved:
            skip = True  # the next words up to do / in aren't commands
        elif skip and word in ("do", "in") and reserved:
            skip = word == "in"
            at_start = word == "do"
            yield t, v
            continue
        if word in STARTS and (reserved or t not in Token.Keyword) \
                and t not in (Token.Text, Token.Name.Builtin):
            at_start = not skip
            yield t, v
            continue
        if word == "=" and t in Token.Operator:
            # Coloured in NAME=value before a command only, not in
            # an argument (--arch=arm64, dd's if=):
            yield (t if assigning else Token.Text), v
            in_value = assigning and not nxt[:1].isspace()
            assigning = False
            continue
        assigning = False
        if nxt == "=":
            if at_start and not skip and t in Token.Name.Variable:
                assigning = True
                yield t, v  # an assignment: the command follows it
                continue
            if t in (Token.Name.Variable, Token.Keyword):
                yield Token.Text, v  # if= of dd, CC= for configure:
                continue
        if at_start and not skip and t in (Token.Text, Token.Name.Builtin):
            yield COMMAND, v
            at_start = word in WRAPPERS
            in_cmd = not nxt[:1].isspace()
            continue
        if not (t in Token.Operator and word == "=") \
                and t not in Token.Literal:
            at_start = False
        yield t, v


def highlight(code, lang, _attrs):
    key = lang.lower() if lang else ""
    name = LEXERS.get(key, key)
    if pyg_highlight is None or not name:
        return ""  # markdown-it escapes it itself
    try:
        lexer = get_lexer_by_name(name)
    except ClassNotFound:
        return ""  # a language Pygments doesn't know: plain
    formatter = HtmlFormatter(nowrap=True)
    if "bash" not in lexer.aliases:
        return pyg_highlight(code, lexer, formatter)
    out = io.StringIO()
    formatter.format(shell_commands(lexer.get_tokens(code)), out)
    return out.getvalue()


# ANCHORS AND LINKS

def slug(text, seen):
    # GitHub's: lower case, punctuation dropped, spaces to dashes;
    # a repeated one gets -1, -2 ...:
    s = re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")
    base, n = s, 0
    while s in seen:
        n += 1
        s = f"{base}-{n}"
    seen.add(s)
    return s


def plain(inline):
    return "".join(t.content for t in (inline.children or [])
                   if t.type in ("text", "code_inline"))


def add_ids(tokens):
    seen = set()
    for i, t in enumerate(tokens):
        if t.type == "heading_open":
            t.attrSet("id", slug(plain(tokens[i + 1]), seen))
    return seen


def href_of(page):
    return "./" if page == "index" else page


def fix_link(href, src, pages, missing):
    # (href, page): a doc's page (no .html), an outside or # link as
    # it is (page None), or None: a file of the source tree, shown
    # as text only.
    if re.match(r"^[a-z][a-z0-9+.-]*:", href, re.I):
        return href, None
    if href.startswith("#"):
        return href, pages[src][0]
    path, _, frag = href.partition("#")
    target = os.path.normpath(os.path.join(os.path.dirname(src), path))
    target = target.replace(os.sep, "/")
    if target in pages:
        page = pages[target][0]
        return href_of(page) + ("#" + frag if frag else ""), page
    if not os.path.exists(os.path.join(ROOT, target)):
        missing.append(f"{src}: {href}")
    return None


def fix_links(tokens, src, pages, missing, wanted):
    for t in tokens:
        kids = t.children or []
        open_links = []
        for c in kids:
            if c.type == "link_open":
                new = fix_link(c.attrGet("href") or "", src, pages, missing)
                open_links.append(new)
                if new is None:
                    c.type, c.tag, c.attrs = "text", "", {}
                    continue
                href, page = new
                c.attrSet("href", href)
                frag = href.partition("#")[2]
                if frag and page:
                    wanted.append((src, page, frag))
            elif c.type == "link_close" and open_links:
                if open_links.pop() is None:
                    c.type, c.tag = "text", ""
            elif open_links and open_links[-1] is not None:
                # A doc's name shown without .md:
                if c.type in ("text", "code_inline"):
                    c.content = re.sub(r"\.md\b", "", c.content)


# PAGES

TASK = re.compile(r"<li>(<p>)?\[([ xX])\] ")
FONTS = ("https://fonts.googleapis.com/css2?family=Comfortaa:wght@300..700"
         "&family=IBM+Plex+Mono:ital,wght@0,100;0,200;0,300;0,400;0,500;"
         "0,600;0,700;1,100;1,200;1,300;1,400;1,500;1,600;1,700"
         "&family=Inconsolata:wght@200..900&display=swap")
STYLE = f"""
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="{FONTS}" rel="stylesheet">
<link rel="stylesheet" href="style.css">"""



def render(md, src, pages, missing, wanted):
    text = open(os.path.join(ROOT, src), encoding="utf-8").read()
    env = {}
    tokens = md.parse(text, env)
    ids = add_ids(tokens)
    fix_links(tokens, src, pages, missing, wanted)
    body = md.renderer.render(tokens, md.options, env)
    body = TASK.sub(lambda m: "<li>" + (m.group(1) or "")
                    + ("☑ " if m.group(2) != " " else "☐ "), body)
    first = next((plain(tokens[i + 1]) for i, t in enumerate(tokens)
                  if t.type == "heading_open" and t.tag == "h1"), src)
    return first, body, ids


def nav(pages):
    links = [f'<a href="{href_of(p)}">{html.escape(label)}</a>'
             for p, label in pages.values()]
    return "<nav>" + "\n".join(links) + "</nav>"


def main():
    pages = sources()
    md = MarkdownIt("commonmark", {"html": True,
                                   "highlight": highlight})
    md.enable(["table", "strikethrough"])
    os.makedirs(OUT, exist_ok=True)
    missing, wanted, done, titles, ids = [], [], {}, {}, {}
    for src, (out, _) in pages.items():
        titles[src], done[src], ids[out] = render(md, src, pages,
                                                   missing, wanted)
    menu = nav(pages)
    for src, (out, _) in pages.items():
        page = (f'<!doctype html>\n<html lang="en">\n<head>\n'
                f'<meta charset="utf-8">\n<meta name="viewport" '
                f'content="width=device-width, initial-scale=1">\n'
                f"<title>{html.escape(titles[src])}</title>{STYLE}\n"
                f"</head>\n<body>\n{menu}\n{done[src]}</body>\n</html>\n")
        with open(os.path.join(OUT, out + ".html"), "w",
                  encoding="utf-8") as f:
            f.write(page)
    if not os.path.exists(os.path.join(OUT, "style.css")):
        print("docs/html/style.css is missing: the pages have no style")
    print(f"{len(pages)} pages in {os.path.relpath(OUT, ROOT)}/"
          + ("" if pyg_highlight else " (no Pygments: code not coloured)"))
    # Links that lead nowhere:
    for m in missing:
        print("no such file:", m)
    for src, page, frag in wanted:
        if frag not in ids.get(page, set()):
            print(f"no such anchor: {src} -> {page}#{frag}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
