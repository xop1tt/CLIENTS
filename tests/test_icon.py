"""Проверки значка приложения: один тёмный значок, буква C по центру, без подмены в Dock.

Исправление «значок становится светлым при закрытии приложения»: подмена значка в коде слетала при выходе,
поэтому значок теперь один, тёмный, из пакета. Эти тесты не дают вернуть светлый вариант или подмену.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest
from PIL import Image

MACOS = Path(__file__).resolve().parent.parent / "macos"
ICON = MACOS / "Resources" / "AppIcon-1024.png"
TILE_FROM, TILE_TO = 100, 924  # плитка macOS внутри холста 1024


@pytest.fixture(scope="module")
def letter():
    im = Image.open(ICON).convert("RGB")
    px = im.load()
    xs, ys = [], []
    for y in range(im.height):
        for x in range(im.width):
            r, g, b = px[x, y]
            if b > 200 and b - r > 80:  # синий цвет буквы
                xs.append(x)
                ys.append(y)
    return im, (min(xs), min(ys), max(xs), max(ys))


def test_icon_size_and_format():
    im = Image.open(ICON)
    assert im.size == (1024, 1024)


def test_letter_is_centered_both_ways(letter):
    _, (x0, y0, x1, y1) = letter
    assert abs((y0 + y1) / 2 - 511.5) <= 2, "по вертикали ровно по центру"
    assert abs((x0 + x1) / 2 - 511.5) <= 2, "по горизонтали по центру"


def test_letter_has_even_padding_inside_the_tile(letter):
    _, (x0, y0, x1, y1) = letter
    left, right, top, bottom = x0 - TILE_FROM, TILE_TO - x1, y0 - TILE_FROM, TILE_TO - y1
    assert abs(left - right) <= 3 and abs(top - bottom) <= 3
    assert min(left, right, top, bottom) >= 100, "отступ от краёв плитки есть"
    assert max(left, right, top, bottom) <= 200, "но он небольшой"


def test_letter_is_upright_not_tilted(letter):
    im, (x0, y0, x1, y1) = letter
    # Верх и низ симметричны: зеркальное отражение по вертикали совпадает с исходным в области буквы.
    box = (x0, y0, x1 + 1, y1 + 1)
    crop = im.crop(box).convert("L")
    flipped = crop.transpose(Image.FLIP_TOP_BOTTOM)
    diff = sum(abs(a - b) for a, b in zip(crop.getdata(), flipped.getdata())) / (crop.width * crop.height)
    assert diff < 40, "буква симметрична сверху вниз, то есть без наклона"


def test_letter_color_is_blue_like_the_old_icon(letter):
    im, (x0, y0, x1, y1) = letter
    r, g, b = im.getpixel((x0 + 55, (y0 + y1) // 2))  # середина левой части штриха
    assert b > 200 and r < 100 and g > 100


def test_tile_is_dark(letter):
    im, _ = letter
    for x, y in [(130, 512), (512, 130), (512, 900), (900, 512), (200, 200)]:
        assert sum(im.getpixel((x, y))[:3]) / 3 < 60, f"плитка тёмная в точке {x},{y}"


def test_there_is_no_light_variant_or_dark_override():
    assert not list((MACOS / "Resources").glob("*Dark*")), "светлого и тёмного вариантов нет, значок один"
    build = (MACOS / "scripts" / "build-app.sh").read_text(encoding="utf-8")
    assert "AppIcon-1024.png" in build and "Dark" not in build
    for path in (MACOS / "Sources").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        assert not re.search(r"applicationIconImage\s*=", text), f"{path.name}: значок в Dock не подменяется"
