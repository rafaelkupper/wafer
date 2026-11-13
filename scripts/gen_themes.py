#!/usr/bin/env python3
"""Generate Wafer theme JSON files from compact per-theme color specs.

Derived fields follow the same structural patterns as the built-in Dark/Light
palettes in Sources/WaferCore/ReaderThemePalette.swift.
"""
import json
import os
import re
import sys
import unicodedata

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO_ROOT, "Sources", "WaferApp", "Resources", "Themes")
EXAMPLE = os.path.expanduser("~/Library/Application Support/Wafer/Themes/Example.json")

W, B = "#FFFFFF", "#000000"
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"


def _rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _hex(rgb):
    return "#%02X%02X%02X" % tuple(max(0, min(255, round(c))) for c in rgb)


def mix(c1, c2, t):
    """c1 blended toward c2 by t (t=1 -> c2)."""
    a, b = _rgb(c1), _rgb(c2)
    return _hex(tuple(a[i] * (1 - t) + b[i] * t for i in range(3)))


def lighten(c, t):
    return mix(c, W, t)


def darken(c, t):
    return mix(c, B, t)


def col(h, a=1):
    return {"hex": h.upper(), "alpha": a}


def build(s):
    dark = s["dark"]
    ov = W if dark else B  # overlay base for hovers/fills
    bg, panel, inline = s["bg"], s["panel"], s["inline"]
    sidebar, sidebar_sel = s["sidebar"], s["sidebar_sel"]
    text, heading, minor, sec = s["text"], s["heading"], s["minor"], s["secondary"]
    link, rule, kbd = s["link"], s["rule"], s["kbd_border"]
    accent, caution = s["accent"], s["caution"]
    syn = s["syn"]
    bright = minor if dark else heading

    if dark:
        callout_bg = col(W, 0.04)
        callout = lambda c, ba, ga: (col(c, ba), col(c, ga))
        note_b, note_g = callout(s["note"], 0.9, 0.11)
        tip_b, tip_g = callout(s["tip"], 0.9, 0.11)
        imp_b, imp_g = callout(s["imp"], 0.92, 0.11)
        warn_b, warn_g = callout(s["warn"], 0.94, 0.12)
        caut_b, caut_g = callout(caution, 0.94, 0.12)
    else:
        callout_bg = col(panel, 0.75)
        tint = lambda c: mix(c, W, 0.85)
        note_b, note_g = col(s["note"], 0.72), col(tint(s["note"]), 0.68)
        tip_b, tip_g = col(s["tip"], 0.72), col(tint(s["tip"]), 0.68)
        imp_b, imp_g = col(s["imp"], 0.72), col(tint(s["imp"]), 0.68)
        warn_b, warn_g = col(s["warn"], 0.74), col(tint(s["warn"]), 0.7)
        caut_b, caut_g = col(caution, 0.74), col(tint(caution), 0.72)

    # Mermaid inner palette
    if dark:
        main_bkg = darken(panel, 0.15)
        m = {
            "theme": "base",
            "background": bg,
            "primaryColor": panel,
            "primaryTextColor": heading,
            "primaryBorderColor": kbd,
            "lineColor": heading,
            "secondaryColor": bg,
            "secondaryTextColor": heading,
            "tertiaryColor": sidebar,
            "tertiaryTextColor": heading,
            "mainBkg": main_bkg,
            "nodeBorder": lighten(kbd, 0.2),
            "nodeTextColor": bright,
            "titleColor": bright,
            "edgeLabelBackground": main_bkg,
            "erEdgeLabelBackground": main_bkg,
            "attributeBackgroundColorOdd": lighten(main_bkg, 0.06),
            "attributeBackgroundColorEven": main_bkg,
            "sectionBkgColor": main_bkg,
            "sectionBkgColor2": lighten(main_bkg, 0.06),
            "altSectionBkgColor": lighten(main_bkg, 0.03),
            "taskBkgColor": mix(accent, bg, 0.65),
            "taskBorderColor": mix(accent, bg, 0.3),
            "activeTaskBkgColor": mix(accent, bg, 0.5),
            "activeTaskBorderColor": lighten(mix(accent, bg, 0.3), 0.25),
            "doneTaskBkgColor": lighten(bg, 0.08),
            "doneTaskBorderColor": kbd,
            "critBkgColor": mix(caution, bg, 0.6),
            "critBorderColor": lighten(caution, 0.3),
            "taskTextColor": bright,
            "taskTextLightColor": bright,
            "taskTextDarkColor": bright,
            "taskTextOutsideColor": heading,
            "taskTextClickableColor": bright,
            "vertLineColor": heading,
            "gridColor": kbd,
            "todayLineColor": accent,
            "textColor": text,
            "fontFamily": FONT,
        }
    else:
        m = {
            "theme": "base",
            "background": bg,
            "primaryColor": panel,
            "primaryTextColor": heading,
            "primaryBorderColor": kbd,
            "lineColor": sec,
            "secondaryColor": bg,
            "secondaryTextColor": heading,
            "tertiaryColor": sidebar,
            "tertiaryTextColor": heading,
            "mainBkg": bg,
            "nodeBorder": kbd,
            "nodeTextColor": heading,
            "titleColor": heading,
            "edgeLabelBackground": bg,
            "erEdgeLabelBackground": bg,
            "attributeBackgroundColorOdd": panel,
            "attributeBackgroundColorEven": bg,
            "sectionBkgColor": bg,
            "sectionBkgColor2": panel,
            "altSectionBkgColor": darken(panel, 0.03),
            "taskBkgColor": mix(accent, W, 0.85),
            "taskBorderColor": kbd,
            "activeTaskBkgColor": mix(accent, W, 0.88),
            "activeTaskBorderColor": accent,
            "doneTaskBkgColor": mix(sec, W, 0.88),
            "doneTaskBorderColor": kbd,
            "critBkgColor": mix(caution, W, 0.9),
            "critBorderColor": caution,
            "taskTextColor": heading,
            "taskTextLightColor": heading,
            "taskTextDarkColor": heading,
            "taskTextOutsideColor": sec,
            "taskTextClickableColor": heading,
            "vertLineColor": sec,
            "gridColor": rule,
            "todayLineColor": accent,
            "textColor": text,
            "fontFamily": FONT,
        }

    p = {
        "name": s["name"],
        "appearanceIsDark": dark,
        "backgroundHex": bg,
        "textHex": text,
        "headingHex": heading,
        "minorHeadingHex": minor,
        "secondaryTextHex": sec,
        "linkHex": link,
        "linkHoverHex": s["link_hover"],
        "ruleHex": rule,
        "codeBlockBackgroundHex": panel,
        "inlineCodeBackgroundHex": inline,
        "selectionHex": s["sel_bg"],
        "selectionTextHex": s["sel_text"],
        "kbdTextHex": minor if dark else heading,
        "kbdBorderHex": kbd,
        "kbdShadow": col(B, 0.22 if dark else 0.12),
        "calloutBackground": callout_bg,
        "calloutNoteBorder": note_b,
        "calloutNoteBackground": note_g,
        "calloutTipBorder": tip_b,
        "calloutTipBackground": tip_g,
        "calloutImportantBorder": imp_b,
        "calloutImportantBackground": imp_g,
        "calloutWarningBorder": warn_b,
        "calloutWarningBackground": warn_g,
        "calloutCautionBorder": caut_b,
        "calloutCautionBackground": caut_g,
        "symbolLinkTextHex": link,
        "symbolLinkBorder": col(link, 0.14 if dark else 0.18),
        "inlineChipBorder": col(W, 0.08) if dark else col(sec, 0.14),
        "inlineChipBackground": col(W, 0.055) if dark else col(panel, 0.96),
        "sidebarBackgroundHex": sidebar,
        "sidebarSelectionHex": sidebar_sel,
        "sidebarHover": col(ov, 0.028 if dark else 0.04),
        "sidebarChromeFill": col(ov, 0.024 if dark else 0.035),
        "sidebarChromeBorder": col(ov, 0.035 if dark else 0.08),
        "sidebarChromeSelectedFill": col(ov, 0.065 if dark else 0.09),
        "sidebarChromeHoverFill": col(ov, 0.04 if dark else 0.055),
        "sidebarPrimaryText": col(heading, 0.96),
        "sidebarSecondaryText": col(sec, 0.92),
        "titlebarPrimaryText": col(heading, 0.72),
        "findBarBackground": col(lighten(bg, 0.14), 0.94) if dark else col(mix(bg, W, 0.6), 0.96),
        "findBarBorder": col(W, 0.08) if dark else col(text, 0.12),
        "statisticsLabel": col(heading, 0.98),
        "statisticsIcon": col(text if dark else sec, 0.9),
        "statisticsIconButton": col(text if dark else sec, 0.92),
        "statisticsPillRestingBackground": col(ov, 0.045 if dark else 0.035),
        "statisticsPillHoverBackground": col(ov, 0.08 if dark else 0.07),
        "statisticsPillHoverBorder": col(ov, 0.14 if dark else 0.13),
        "statisticsIconButtonRestingBackground": col(ov, 0.03 if dark else 0.035),
        "statisticsIconButtonHoverBackground": col(ov, 0.07),
        "statisticsIconButtonActiveBackground": col(ov, 0.12),
        "statisticsIconButtonHoverBorder": col(ov, 0.12 if dark else 0.13),
        "mermaidContainerBackground": col(panel, 0.78 if dark else 0.86),
        "mermaidContainerBorder": col(heading, 0.12) if dark else col(rule, 0.95),
        "mermaidGridStroke": col(heading, 0.34) if dark else col(rule, 0.95),
        "mermaidControlTextHex": bright,
        "mermaidControlBackground": col(sidebar_sel, 0.92) if dark else col(W, 0.94),
        "mermaidControlBorder": col(heading, 0.26) if dark else col(kbd, 0.35),
        "mermaidControlHoverBackgroundHex": sidebar_sel if dark else panel,
        "mermaidControlHoverBorder": col(bright, 0.58) if dark else col(sec, 0.48),
        "mermaidErrorTextHex": lighten(caution, 0.35) if dark else darken(caution, 0.15),
        "mermaidSourceBackground": col(B, 0.14) if dark else col(panel, 1),
        "diagramInspectorBackdrop": col(darken(bg, 0.35), 0.86) if dark else col(panel, 0.92),
        "diagramInspectorTextHex": bright,
        "diagramInspectorToolbarBackground": col(sidebar, 0.94) if dark else col(W, 0.96),
        "diagramInspectorToolbarBorder": col(heading, 0.14) if dark else col(rule, 1),
        "diagramInspectorButtonTextHex": bright,
        "diagramInspectorButtonBackgroundHex": panel,
        "diagramInspectorButtonBorder": col(heading, 0.18) if dark else col(rule, 1),
        "diagramInspectorButtonHoverBackgroundHex": bg if dark else darken(panel, 0.05),
        "diagramInspectorButtonHoverBorder": col(bright, 0.52) if dark else col(kbd, 0.75),
        "diagramInspectorViewportBackgroundHex": panel if dark else bg,
        "diagramInspectorViewportBorder": col(heading, 0.14) if dark else col(rule, 1),
        "diagramInspectorViewportFocusOutline": col(bright, 0.54) if dark else col(link, 0.5),
        "syntaxVariableHex": syn["var"],
        "syntaxKeywordHex": syn["kw"],
        "syntaxStringHex": syn["str"],
        "syntaxCommentHex": syn["com"],
        "syntaxNumberHex": syn["num"],
        "syntaxAtomHex": syn["atom"],
        "syntaxSecondaryVariableHex": syn["secvar"],
        "syntaxDefinitionHex": syn["defn"],
        "syntaxPositiveHex": syn["pos"],
        "syntaxNegativeHex": syn["neg"],
        "tab": {
            "barBackground": col(sidebar),
            "barBorder": col(ov, 0.06 if dark else 0.08),
            "restingFill": col(ov, 0.02),
            "hoverFill": col(ov, 0.06 if dark else 0.055),
            "selectedFill": col(bg),
            "selectedText": col(heading, 0.96),
            "unselectedText": col(sec, 0.92),
            "closeIcon": col(sec, 0.92),
            "closeHoverFill": col(ov, 0.1 if dark else 0.08),
            "insertionIndicator": col(accent, 0.9 if dark else 0.85),
        },
        "mermaid": m,
    }
    return p


THEMES = [
    # ------------------------------------------------------------- GitHub Light
    dict(
        name="GitHub Light", dark=False,
        bg="#FFFFFF", panel="#F6F8FA", inline="#EFF1F3",
        sidebar="#F6F8FA", sidebar_sel="#E4E9EE",
        text="#1F2328", heading="#1F2328", minor="#0B0F14", secondary="#59636E",
        link="#0969DA", link_hover="#054DA7", rule="#D0D7DE", kbd_border="#B6BEC8",
        sel_bg="#ADD6FF", sel_text="#0B0F14",
        note="#0969DA", tip="#1A7F37", imp="#8250DF", warn="#9A6700", caution="#CF222E",
        accent="#0969DA",
        syn=dict(var="#953800", kw="#CF222E", str="#0A3069", com="#57606A",
                 num="#0550AE", atom="#0550AE", secvar="#24292F", defn="#8250DF",
                 pos="#1A7F37", neg="#CF222E"),
    ),
    # -------------------------------------------------------------- GitHub Dark
    dict(
        name="GitHub Dark", dark=True,
        bg="#0D1117", panel="#161B22", inline="#1F242C",
        sidebar="#010409", sidebar_sel="#161B22",
        text="#C9D1D9", heading="#E6EDF3", minor="#FFFFFF", secondary="#8B949E",
        link="#58A6FF", link_hover="#79C0FF", rule="#30363D", kbd_border="#6E7681",
        sel_bg="#1D4E89", sel_text="#FFFFFF",
        note="#58A6FF", tip="#3FB950", imp="#A371F7", warn="#D29922", caution="#F85149",
        accent="#58A6FF",
        syn=dict(var="#FFA657", kw="#FF7B72", str="#A5D6FF", com="#8B949E",
                 num="#79C0FF", atom="#79C0FF", secvar="#C9D1D9", defn="#D2A8FF",
                 pos="#3FB950", neg="#F85149"),
    ),
    # ------------------------------------------------------------------ Dracula
    dict(
        name="Dracula", dark=True,
        bg="#282A36", panel="#21222C", inline="#343746",
        sidebar="#191A21", sidebar_sel="#21222C",
        text="#F8F8F2", heading="#F8F8F2", minor="#FFFFFF", secondary="#7B88B8",
        link="#8BE9FD", link_hover="#D6F6FF", rule="#44475A", kbd_border="#6272A4",
        sel_bg="#44475A", sel_text="#F8F8F2",
        note="#8BE9FD", tip="#50FA7B", imp="#BD93F9", warn="#FFB86C", caution="#FF5555",
        accent="#BD93F9",
        syn=dict(var="#F8F8F2", kw="#FF79C6", str="#F1FA8C", com="#6272A4",
                 num="#BD93F9", atom="#8BE9FD", secvar="#FFB86C", defn="#50FA7B",
                 pos="#50FA7B", neg="#FF5555"),
    ),
    # ---------------------------------------------------------- Solarized Light
    dict(
        name="Solarized Light", dark=False,
        bg="#FDF6E3", panel="#EEE8D5", inline="#F3EDDA",
        sidebar="#EEE8D5", sidebar_sel="#DFD8C2",
        text="#657B83", heading="#073642", minor="#002B36", secondary="#93A1A1",
        link="#268BD2", link_hover="#1A6EA8", rule="#DCD4C0", kbd_border="#93A1A1",
        sel_bg="#B5D5EA", sel_text="#073642",
        note="#268BD2", tip="#859900", imp="#6C71C4", warn="#B58900", caution="#DC322F",
        accent="#268BD2",
        syn=dict(var="#268BD2", kw="#859900", str="#2AA198", com="#93A1A1",
                 num="#D33682", atom="#B58900", secvar="#657B83", defn="#6C71C4",
                 pos="#859900", neg="#DC322F"),
    ),
    # ----------------------------------------------------------- Solarized Dark
    dict(
        name="Solarized Dark", dark=True,
        bg="#002B36", panel="#073642", inline="#0E4450",
        sidebar="#00212B", sidebar_sel="#073642",
        text="#839496", heading="#93A1A1", minor="#EEE8D5", secondary="#75898F",
        link="#268BD2", link_hover="#4FA5E0", rule="#144B57", kbd_border="#586E75",
        sel_bg="#235A6B", sel_text="#FDF6E3",
        note="#268BD2", tip="#859900", imp="#6C71C4", warn="#B58900", caution="#DC322F",
        accent="#268BD2",
        syn=dict(var="#268BD2", kw="#859900", str="#2AA198", com="#586E75",
                 num="#D33682", atom="#B58900", secvar="#839496", defn="#6C71C4",
                 pos="#859900", neg="#DC322F"),
    ),
    # --------------------------------------------------------------------- Nord
    dict(
        name="Nord", dark=True,
        bg="#2E3440", panel="#3B4252", inline="#434C5E",
        sidebar="#272B35", sidebar_sel="#20242D",
        text="#D8DEE9", heading="#ECEFF4", minor="#FFFFFF", secondary="#A1AABE",
        link="#88C0D0", link_hover="#A3D3E0", rule="#434C5E", kbd_border="#4C566A",
        sel_bg="#5E81AC", sel_text="#ECEFF4",
        note="#81A1C1", tip="#A3BE8C", imp="#B48EAD", warn="#EBCB8B", caution="#BF616A",
        accent="#88C0D0",
        syn=dict(var="#D8DEE9", kw="#81A1C1", str="#A3BE8C", com="#616E88",
                 num="#B48EAD", atom="#EBCB8B", secvar="#8FBCBB", defn="#88C0D0",
                 pos="#A3BE8C", neg="#BF616A"),
    ),
    # ------------------------------------------------------------------ Monokai
    dict(
        name="Monokai", dark=True,
        bg="#272822", panel="#1E1F1C", inline="#32332B",
        sidebar="#1E1F1C", sidebar_sel="#171814",
        text="#F8F8F2", heading="#F8F8F2", minor="#FFFFFF", secondary="#A8A48F",
        link="#66D9EF", link_hover="#A1E7F5", rule="#49483E", kbd_border="#75715E",
        sel_bg="#49483E", sel_text="#F8F8F2",
        note="#66D9EF", tip="#A6E22E", imp="#AE81FF", warn="#E6DB74", caution="#F92672",
        accent="#66D9EF",
        syn=dict(var="#F8F8F2", kw="#F92672", str="#E6DB74", com="#75715E",
                 num="#AE81FF", atom="#66D9EF", secvar="#FD971F", defn="#A6E22E",
                 pos="#A6E22E", neg="#F92672"),
    ),
    # ----------------------------------------------------------------- One Dark
    dict(
        name="One Dark", dark=True,
        bg="#282C34", panel="#21252B", inline="#2C313A",
        sidebar="#21252B", sidebar_sel="#191D23",
        text="#ABB2BF", heading="#D7DAE0", minor="#FFFFFF", secondary="#9098A8",
        link="#61AFEF", link_hover="#8CC7F7", rule="#3E4451", kbd_border="#5C6370",
        sel_bg="#3E4451", sel_text="#FFFFFF",
        note="#61AFEF", tip="#98C379", imp="#C678DD", warn="#E5C07B", caution="#E06C75",
        accent="#61AFEF",
        syn=dict(var="#E06C75", kw="#C678DD", str="#98C379", com="#5C6370",
                 num="#D19A66", atom="#56B6C2", secvar="#ABB2BF", defn="#61AFEF",
                 pos="#98C379", neg="#E06C75"),
    ),
    # ------------------------------------------------------------- Gruvbox Dark
    dict(
        name="Gruvbox Dark", dark=True,
        bg="#282828", panel="#1D2021", inline="#32302F",
        sidebar="#1D2021", sidebar_sel="#141617",
        text="#EBDBB2", heading="#FBF1C7", minor="#FFFFFF", secondary="#A89984",
        link="#83A598", link_hover="#A9C2B9", rule="#3C3836", kbd_border="#665C54",
        sel_bg="#504945", sel_text="#FBF1C7",
        note="#83A598", tip="#B8BB26", imp="#D3869B", warn="#FABD2F", caution="#FB4934",
        accent="#FE8019",
        syn=dict(var="#EBDBB2", kw="#FB4934", str="#B8BB26", com="#928374",
                 num="#D3869B", atom="#FABD2F", secvar="#FE8019", defn="#8EC07C",
                 pos="#B8BB26", neg="#FB4934"),
    ),
    # --------------------------------------------------------- Catppuccin Mocha
    dict(
        name="Catppuccin Mocha", dark=True,
        bg="#1E1E2E", panel="#181825", inline="#313244",
        sidebar="#181825", sidebar_sel="#11111B",
        text="#CDD6F4", heading="#CDD6F4", minor="#FFFFFF", secondary="#A6ADC8",
        link="#89B4FA", link_hover="#B4BEFE", rule="#313244", kbd_border="#6C7086",
        sel_bg="#45475A", sel_text="#CDD6F4",
        note="#89B4FA", tip="#A6E3A1", imp="#CBA6F7", warn="#F9E2AF", caution="#F38BA8",
        accent="#CBA6F7",
        syn=dict(var="#CDD6F4", kw="#CBA6F7", str="#A6E3A1", com="#6C7086",
                 num="#FAB387", atom="#F9E2AF", secvar="#94E2D5", defn="#89B4FA",
                 pos="#A6E3A1", neg="#F38BA8"),
    ),
    # --------------------------------------------------------- Catppuccin Latte
    dict(
        name="Catppuccin Latte", dark=False,
        bg="#EFF1F5", panel="#E6E9EF", inline="#DCE0E8",
        sidebar="#E6E9EF", sidebar_sel="#CDD3DF",
        text="#4C4F69", heading="#2F334F", minor="#1E2030", secondary="#6C6F85",
        link="#1E66F5", link_hover="#1348B8", rule="#BCC0CC", kbd_border="#9CA0B0",
        sel_bg="#B9CCF8", sel_text="#1E2030",
        note="#1E66F5", tip="#40A02B", imp="#8839EF", warn="#DF8E1D", caution="#D20F39",
        accent="#8839EF",
        syn=dict(var="#4C4F69", kw="#8839EF", str="#40A02B", com="#8C8FA1",
                 num="#FE640B", atom="#DF8E1D", secvar="#179299", defn="#1E66F5",
                 pos="#40A02B", neg="#D20F39"),
    ),
    # -------------------------------------------------------------- Tokyo Night
    dict(
        name="Tokyo Night", dark=True,
        bg="#1A1B26", panel="#16161E", inline="#262A41",
        sidebar="#16161E", sidebar_sel="#101014",
        text="#A9B1D6", heading="#C0CAF5", minor="#FFFFFF", secondary="#7982A9",
        link="#7AA2F7", link_hover="#A5C0FB", rule="#292E42", kbd_border="#565F89",
        sel_bg="#33467C", sel_text="#C0CAF5",
        note="#7AA2F7", tip="#9ECE6A", imp="#BB9AF7", warn="#E0AF68", caution="#F7768E",
        accent="#7AA2F7",
        syn=dict(var="#C0CAF5", kw="#BB9AF7", str="#9ECE6A", com="#565F89",
                 num="#FF9E64", atom="#7DCFFF", secvar="#73DACA", defn="#7AA2F7",
                 pos="#9ECE6A", neg="#F7768E"),
    ),
    # ---------------------------------------------------------------- Rosé Pine
    dict(
        name="Rosé Pine", dark=True,
        bg="#191724", panel="#1F1D2E", inline="#26233A",
        sidebar="#1F1D2E", sidebar_sel="#121020",
        text="#E0DEF4", heading="#E0DEF4", minor="#FFFFFF", secondary="#908CAA",
        link="#C4A7E7", link_hover="#E4D6F7", rule="#26233A", kbd_border="#6E6A86",
        sel_bg="#403D52", sel_text="#E0DEF4",
        note="#9CCFD8", tip="#31748F", imp="#C4A7E7", warn="#F6C177", caution="#EB6F92",
        accent="#C4A7E7",
        syn=dict(var="#E0DEF4", kw="#31748F", str="#F6C177", com="#6E6A86",
                 num="#EBBCBA", atom="#9CCFD8", secvar="#908CAA", defn="#C4A7E7",
                 pos="#9CCFD8", neg="#EB6F92"),
    ),
    # ------------------------------------------------------------- Synthwave 84
    dict(
        name="Synthwave '84", dark=True,
        bg="#262335", panel="#241B2F", inline="#2F2A45",
        sidebar="#201C2D", sidebar_sel="#171321",
        text="#D8CFF0", heading="#F4F0FF", minor="#FFFFFF", secondary="#848BBD",
        link="#36F9F6", link_hover="#9FFCFA", rule="#495495", kbd_border="#848BBD",
        sel_bg="#463465", sel_text="#FFFFFF",
        note="#36F9F6", tip="#72F1B8", imp="#B893CE", warn="#FEDE5D", caution="#FE4450",
        accent="#FF7EDB",
        syn=dict(var="#FF7EDB", kw="#FEDE5D", str="#FF8B39", com="#848BBD",
                 num="#F97E72", atom="#B893CE", secvar="#72F1B8", defn="#36F9F6",
                 pos="#72F1B8", neg="#FE4450"),
    ),
]

HEX_RE = re.compile(r"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")
NON_COLOR = {"name", "mermaid.theme", "mermaid.fontFamily"}


def key_paths(obj, prefix=""):
    """Recursive set of key paths with a marker for leaf type."""
    paths = set()
    for k, v in obj.items():
        p = f"{prefix}{k}"
        if isinstance(v, dict) and set(v.keys()) == {"hex", "alpha"}:
            paths.add(p + ":color")
        elif isinstance(v, dict):
            paths |= key_paths(v, p + ".")
        else:
            paths.add(p)
    return paths


def validate(palette, example_paths):
    errors = []
    got = key_paths(palette)
    missing = example_paths - got
    # The optional v1.2 tab token group postdates the on-disk Example.json.
    extra = {k for k in (got - example_paths) if not (k == "tab" or k.startswith("tab."))}
    if missing:
        errors.append(f"missing keys: {sorted(missing)}")
    if extra:
        errors.append(f"extra keys: {sorted(extra)}")

    def walk(obj, prefix=""):
        for k, v in obj.items():
            p = f"{prefix}{k}"
            if isinstance(v, dict) and set(v.keys()) == {"hex", "alpha"}:
                if not HEX_RE.match(v["hex"]):
                    errors.append(f"{p}.hex bad: {v['hex']}")
                if not (0 <= v["alpha"] <= 1):
                    errors.append(f"{p}.alpha out of range: {v['alpha']}")
            elif isinstance(v, dict):
                walk(v, p + ".")
            elif isinstance(v, str):
                if p in NON_COLOR:
                    if not v.strip():
                        errors.append(f"{p} empty")
                elif not HEX_RE.match(v):
                    errors.append(f"{p} bad hex: {v}")
    walk(palette)
    return errors


def main():
    with open(EXAMPLE) as f:
        example_paths = key_paths(json.load(f))

    os.makedirs(OUT_DIR, exist_ok=True)
    failed = False
    for spec in THEMES:
        palette = build(spec)
        errs = validate(palette, example_paths)
        if errs:
            failed = True
            print(f"FAIL {spec['name']}:")
            for e in errs:
                print(f"  - {e}")
            continue
        # Bundle resource file names must stay ASCII: accented names break the
        # code seal when Finder extracts the release zip with a different
        # Unicode normalization than the one that was signed.
        ascii_name = unicodedata.normalize("NFKD", spec["name"]).encode("ascii", "ignore").decode("ascii")
        path = os.path.join(OUT_DIR, f"{ascii_name}.json")
        with open(path, "w") as f:
            json.dump(palette, f, indent=2, sort_keys=True, ensure_ascii=False)
            f.write("\n")
        print(f"OK   {path}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
