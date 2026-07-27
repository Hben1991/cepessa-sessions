"""Deterministic Unicode normalization for mixed Hebrew-English transcripts."""

from __future__ import annotations

import re
import unicodedata

_WHITESPACE = re.compile(r"\s+")
_BIDI_CONTROLS = {
    "\u061c",
    "\u200e",
    "\u200f",
    "\u202a",
    "\u202b",
    "\u202c",
    "\u202d",
    "\u202e",
    "\u2066",
    "\u2067",
    "\u2068",
    "\u2069",
}
_APOSTROPHES = {"'", "\u2018", "\u2019", "\u05f3", "\u05f4"}


def _is_hebrew_diacritic(character: str) -> bool:
    codepoint = ord(character)
    return (
        0x0591 <= codepoint <= 0x05BD
        or codepoint == 0x05BF
        or 0x05C1 <= codepoint <= 0x05C2
        or 0x05C4 <= codepoint <= 0x05C5
        or codepoint == 0x05C7
    )


def normalize_text(text: str) -> str:
    """Normalize text without transliterating or translating either language."""

    normalized = unicodedata.normalize("NFC", text).casefold()
    output: list[str] = []
    for character in normalized:
        if character in _BIDI_CONTROLS or _is_hebrew_diacritic(character):
            continue
        if character in _APOSTROPHES:
            continue
        category = unicodedata.category(character)
        if category.startswith("M"):
            continue
        if category.startswith("P") or category.startswith("S"):
            output.append(" ")
            continue
        if category.startswith("Z") or character.isspace():
            output.append(" ")
            continue
        output.append(character)
    return _WHITESPACE.sub(" ", "".join(output)).strip()


def normalized_tokens(text: str) -> list[str]:
    normalized = normalize_text(text)
    return normalized.split(" ") if normalized else []


def normalized_character_stream(text: str) -> list[str]:
    return list("".join(normalized_tokens(text)))


def token_language(token: str) -> str:
    has_hebrew = any(0x0590 <= ord(character) <= 0x05FF for character in token)
    has_latin = any(
        "LATIN" in unicodedata.name(character, "")
        for character in token
        if character.isalpha()
    )
    if has_hebrew and has_latin:
        return "mixed"
    if has_hebrew:
        return "he"
    if has_latin:
        return "en"
    return "other"
