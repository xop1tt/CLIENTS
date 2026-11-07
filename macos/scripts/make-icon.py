#!/usr/bin/env python3
"""Рисует Resources/AppIcon-1024.png (нужен Pillow): буква C на тёмной плитке в стиле macOS.

Значок один и тёмный, без светлого варианта и без подмены в Dock: при выходе из приложения
Dock показывает значок из пакета, поэтому он должен быть таким же, как при работе.
Геометрия задана числами ниже; Resources/AppIcon.svg повторяет её, а проверки в
tests/test_icon.py и LeadGeneratorTests/IconTests.swift следят, что буква по центру и с отступами.
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE, SS = 1024, 4                 # итоговый размер и сглаживание
TILE_X, TILE_SIZE, TILE_R = 100, 824, 185
R_OUT, STROKE, GAP = 265, 110, 38  # внешний радиус C, толщина штриха, полураскрытие справа (градусы)
CY = SIZE / 2
R_MID = R_OUT - STROKE / 2
# Сдвиг по горизонтали: у буквы справа вырез, поэтому по краям рамки центрируем её саму.
right = R_MID * math.cos(math.radians(GAP)) + STROKE / 2
CX = SIZE / 2 + (R_OUT - right) / 2


def gradient(top, bottom, box):
    w, h = box[2] - box[0], box[3] - box[1]
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        col.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return col.resize((w, h))


def letter_mask(scale):
    m = Image.new("L", (SIZE * scale, SIZE * scale), 0)
    d = ImageDraw.Draw(m)
    c = (CX * scale, CY * scale)
    r_out, r_in, w = R_OUT * scale, (R_OUT - STROKE) * scale, STROKE * scale
    d.arc([c[0] - r_out, c[1] - r_out, c[0] + r_out, c[1] + r_out],
          start=GAP, end=360 - GAP, fill=255, width=int(w))
    for sign in (-1, 1):  # скруглённые концы
        a = math.radians(sign * GAP)
        x, y = c[0] + R_MID * scale * math.cos(a), c[1] + R_MID * scale * math.sin(a)
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
    return m


def build() -> Image.Image:
    big = SIZE * SS
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    tile = Image.new("L", (big, big), 0)
    ImageDraw.Draw(tile).rounded_rectangle(
        [TILE_X * SS, TILE_X * SS, (TILE_X + TILE_SIZE) * SS - 1, (TILE_X + TILE_SIZE) * SS - 1], TILE_R * SS, fill=255)
    # тень плитки
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    shadow.putalpha(ImageChops.offset(tile, 0, 12 * SS).filter(ImageFilter.GaussianBlur(16 * SS)).point(lambda v: int(v * 0.22)))
    img = Image.alpha_composite(img, shadow)
    bg = gradient((0x1F, 0x1F, 0x22), (0x09, 0x09, 0x0A), (0, TILE_X * SS, big, (TILE_X + TILE_SIZE) * SS))
    layer = Image.new("RGB", (big, big), (0x1F, 0x1F, 0x22))
    layer.paste(bg, (0, TILE_X * SS))
    img = Image.alpha_composite(img, Image.merge("RGBA", (*layer.split(), tile)))
    # тонкая светлая кромка плитки
    edge = ImageChops.subtract(tile, tile.filter(ImageFilter.MinFilter(2 * SS + 1)))
    img = Image.alpha_composite(img, Image.merge("RGBA", (*Image.new("RGB", (big, big), (255, 255, 255)).split(), edge.point(lambda v: int(v * 0.10)))))
    # буква C: тень и синий градиент (как был у рупора)
    mask = letter_mask(SS)
    lift = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    lift.putalpha(ImageChops.offset(mask, 0, 8 * SS).filter(ImageFilter.GaussianBlur(10 * SS)).point(lambda v: int(v * 0.55)))
    img = Image.alpha_composite(img, lift)
    top = int((CY - R_OUT) * SS)
    blue = Image.new("RGB", (big, big), (0x1A, 0x7C, 0xFF))
    blue.paste(gradient((0x5A, 0xC2, 0xFF), (0x1A, 0x7C, 0xFF), (0, top, big, int((CY + R_OUT) * SS))), (0, top))
    img = Image.alpha_composite(img, Image.merge("RGBA", (*blue.split(), mask)))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "Resources" / "AppIcon-1024.png")
    build().save(out)
    print(f"Готово: {out}; центр буквы по X = {CX:.2f}")
