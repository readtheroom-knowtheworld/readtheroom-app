#!/usr/bin/env python3
"""Generate the ten chameleon avatar SVGs into readtheroom/assets/avatars/.

Run with `python3 scripts/gen_chameleon_avatars.py` after editing VARIANTS or a
shape; it overwrites the whole set so the family stays consistent. The ids it
emits (chameleon_01 .. chameleon_10) are the `avatar_id` values stored in
`user_profiles`, and `avatarAssetPath()` in lib/src/utils/avatar_catalog.dart
must list exactly the same ids (test/avatar_catalog_test.dart asserts every id
resolves to a file that exists).


One shared silhouette family: a head-and-curled-tail bust inside a circular
disc, drawn with flat shapes only (no gradients, filters, masks or external
refs) so flutter_svg renders it identically everywhere and each file stays
well under 8 KB.

Variation comes from the palette (disc / body / crest / belly / eye ring) plus
one small accent per avatar.
"""

import os

OUT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "readtheroom", "assets", "avatars",
)

# (name, disc, body, shade, crest, belly, accent-kind, accent colour)
VARIANTS = [
    ("chameleon_01", "#D7F0E6", "#2FA37C", "#238263", "#1C6B52", "#BFE8D6", "spots",   "#17544181"),
    ("chameleon_02", "#FFE9D2", "#F2994A", "#D87F33", "#B8651F", "#FFD9AE", "stripes", "#B8651F"),
    ("chameleon_03", "#E6E2FB", "#7B6CE0", "#6254C6", "#4C3FA8", "#D6D0F7", "leaf",    "#3EA36B"),
    ("chameleon_04", "#FDE2EC", "#E8699A", "#CC4C7F", "#A93765", "#FACBDC", "glasses", "#2E3440"),
    ("chameleon_05", "#DFF1FB", "#3BA3D4", "#2684B3", "#1C6A92", "#C7E6F6", "spots",   "#1C6A9281"),
    ("chameleon_06", "#FFF4D1", "#E8C33C", "#CBA421", "#A88617", "#FBEAA9", "stripes", "#A88617"),
    ("chameleon_07", "#E9E9EC", "#6E7480", "#585E69", "#444A54", "#D2D4D9", "scarf",   "#D94F4F"),
    ("chameleon_08", "#E3F7D8", "#76C043", "#5EA132", "#497E26", "#CCEEB6", "leaf",    "#2F7D4F"),
    ("chameleon_09", "#F3E3D2", "#B07A4E", "#95633C", "#774E2D", "#E4CDB3", "spots",   "#774E2D81"),
    ("chameleon_10", "#E2EAF7", "#4F5FA8", "#3D4B8C", "#2F3A6E", "#C9D5EE", "glasses", "#F2C14E"),
]

HEADER = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" '
    'width="128" height="128" role="img" aria-label="Chameleon avatar">\n'
)


def accent(kind, colour):
    """Small distinguishing mark, drawn on top of the body."""
    if kind == "spots":
        return (
            f'  <g fill="{colour}">\n'
            '    <circle cx="62" cy="70" r="5"/>\n'
            '    <circle cx="76" cy="80" r="3.5"/>\n'
            '    <circle cx="52" cy="83" r="4"/>\n'
            '  </g>\n'
        )
    if kind == "stripes":
        return (
            f'  <g fill="none" stroke="{colour}" stroke-width="4" '
            'stroke-linecap="round" opacity="0.55">\n'
            '    <path d="M50 66 Q60 74 56 88"/>\n'
            '    <path d="M64 64 Q74 73 70 88"/>\n'
            '    <path d="M78 68 Q86 76 83 88"/>\n'
            '  </g>\n'
        )
    if kind == "leaf":
        # A single leaf tucked behind the casque, like a jaunty hat.
        return (
            f'  <g fill="{colour}">\n'
            '    <path d="M96 34 Q112 22 118 34 Q112 46 98 42 Z"/>\n'
            '    <path d="M99 39 Q108 34 116 32" fill="none" stroke="#ffffff" '
            'stroke-width="1.6" opacity="0.55"/>\n'
            '  </g>\n'
        )
    if kind == "glasses":
        # In profile only one lens is visible; the arm runs back over the head.
        return (
            f'  <g fill="none" stroke="{colour}" stroke-width="3.2" '
            'stroke-linecap="round">\n'
            '    <circle cx="101" cy="58" r="12"/>\n'
            '    <path d="M89 55 Q80 51 74 54"/>\n'
            '  </g>\n'
        )
    if kind == "scarf":
        return (
            f'  <g fill="{colour}">\n'
            '    <path d="M46 80 Q64 92 86 84 L88 93 Q64 102 44 90 Z"/>\n'
            '    <path d="M84 90 L92 104 L82 102 Z"/>\n'
            '  </g>\n'
        )
    raise ValueError(kind)


def build(name, disc, body, shade, crest, belly, kind, accent_colour):
    parts = [HEADER]
    # Disc background.
    parts.append(f'  <circle cx="64" cy="64" r="64" fill="{disc}"/>\n')
    # Curled tail, behind the body.
    parts.append(
        f'  <path d="M44 96 Q22 96 26 78 Q29 66 41 68 Q50 70 48 79 '
        f'Q46 86 39 84 Q34 82 36 77" fill="none" stroke="{shade}" '
        'stroke-width="9" stroke-linecap="round"/>\n'
    )
    # Body / neck bust.
    parts.append(
        f'  <path d="M40 122 Q34 92 48 72 Q60 54 84 50 Q104 47 112 62 '
        f'Q118 76 104 84 Q92 92 92 122 Z" fill="{body}"/>\n'
    )
    # Belly highlight.
    parts.append(
        f'  <path d="M52 122 Q48 98 58 82 Q66 72 78 70 Q74 86 76 122 Z" '
        f'fill="{belly}" opacity="0.75"/>\n'
    )
    # Dorsal crest.
    parts.append(
        f'  <path d="M60 60 L66 48 L70 59 L78 45 L82 56 L92 44 L95 55 '
        f'Q84 50 74 53 Q66 56 60 60 Z" fill="{crest}"/>\n'
    )
    # Head.
    parts.append(
        f'  <path d="M84 48 Q106 42 116 58 Q120 70 106 76 Q92 80 84 70 '
        f'Q78 58 84 48 Z" fill="{body}"/>\n'
    )
    # Casque (head ridge).
    parts.append(
        f'  <path d="M96 40 Q112 36 118 50 Q110 46 98 48 Z" fill="{crest}"/>\n'
    )
    # Eye.
    parts.append(f'  <circle cx="101" cy="58" r="9" fill="{belly}"/>\n')
    parts.append(f'  <circle cx="103" cy="58" r="4.6" fill="{shade}"/>\n')
    parts.append('  <circle cx="104.5" cy="56.5" r="1.7" fill="#ffffff"/>\n')
    # Mouth line.
    parts.append(
        f'  <path d="M104 73 Q114 74 120 68" fill="none" stroke="{shade}" '
        'stroke-width="3.4" stroke-linecap="round"/>\n'
    )
    # Accent on top.
    parts.append(accent(kind, accent_colour))
    parts.append('</svg>\n')
    return "".join(parts)


def main():
    os.makedirs(OUT, exist_ok=True)
    for variant in VARIANTS:
        name = variant[0]
        svg = build(*variant)
        path = os.path.join(OUT, f"{name}.svg")
        with open(path, "w") as fh:
            fh.write(svg)
        print(f"{name}.svg  {len(svg.encode()):5d} bytes")


if __name__ == "__main__":
    main()
