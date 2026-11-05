"""Реестр типов источников. Новый источник = новый класс + строка здесь + блок в конфиге."""
from __future__ import annotations

from leadgen.sources.base import Source
from leadgen.sources.osm_overpass import OsmOverpassSource
from leadgen.sources.rss import RssSource
from leadgen.sources.telegram_web import TelegramWebSource
from leadgen.sources.vk import VkWallSource

SOURCE_TYPES: dict[str, type[Source]] = {
    RssSource.type_name: RssSource,
    TelegramWebSource.type_name: TelegramWebSource,
    VkWallSource.type_name: VkWallSource,
    OsmOverpassSource.type_name: OsmOverpassSource,
}
