<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="macos/Resources/AppIcon-Dark-1024.png">
  <img src="macos/Resources/AppIcon-1024.png" alt="Иконка Lead Generator" width="128" height="128">
</picture>

# Customers

**Бесплатное приложение для macOS, которое само находит заказчиков на разработку**<br>
сайты · Telegram-боты · приложения · автоматизация · CRM · доработки

[![Последний релиз](https://img.shields.io/github/v/release/xop1tt/CLIENTS?label=%D1%80%D0%B5%D0%BB%D0%B8%D0%B7&color=2ea44f)](https://github.com/xop1tt/CLIENTS/releases/latest)
[![Загрузки](https://img.shields.io/github/downloads/xop1tt/CLIENTS/total?label=%D0%B7%D0%B0%D0%B3%D1%80%D1%83%D0%B7%D0%BA%D0%B8)](https://github.com/xop1tt/CLIENTS/releases)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](https://github.com/xop1tt/CLIENTS/wiki/Установка)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white)](macos)
<br>
[![Tests](https://github.com/xop1tt/CLIENTS/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/xop1tt/CLIENTS/actions/workflows/tests.yml)
[![macOS app](https://github.com/xop1tt/CLIENTS/actions/workflows/macos-app.yml/badge.svg?branch=main)](https://github.com/xop1tt/CLIENTS/actions/workflows/macos-app.yml)
[![Cloud](https://github.com/xop1tt/CLIENTS/actions/workflows/cloud.yml/badge.svg?branch=main)](https://github.com/xop1tt/CLIENTS/actions/workflows/cloud.yml)
[![Лицензия: PIBUL 1.0](https://img.shields.io/badge/%D0%BB%D0%B8%D1%86%D0%B5%D0%BD%D0%B7%D0%B8%D1%8F-PIBUL%201.0-blue)](LICENSE)

[**⬇️ Скачать для macOS**](https://github.com/xop1tt/CLIENTS/releases/latest) ·
[**📖 Документация (Wiki)**](https://github.com/xop1tt/CLIENTS/wiki) ·
[**🐞 Сообщить о проблеме**](https://github.com/xop1tt/CLIENTS/issues/new)

</div>

---

Lead Generator просматривает открытые источники: RSS-ленты бирж (FL.ru и любые другие), публичные Telegram-каналы,
сообщества VK и организации из OpenStreetMap. Он отбирает настоящие заказы, оценивает каждый по понятным правилам и
складывает в удобную таблицу на вашем Mac. **Всё бесплатно навсегда**: без подписок, пробных периодов, платных API и AI-сервисов.

## ✨ Возможности

| | |
|---|---|
| 🔎 **Поиск в один клик** | Кнопка «Найти лиды» (⌘R) или автопроверка по расписанию, в том числе в фоне из строки меню |
| 📡 **Четыре вида источников** | RSS/Atom-ленты, Telegram-каналы, VK-сообщества, OpenStreetMap с проверкой сайтов организаций |
| 🎯 **Понятная оценка** | 0–100 баллов и причины: тематика, явный запрос, бюджет, срочность, спам. Факты отдельно от предположений |
| 🧹 **Без дублей и мусора** | Дедупликация по ID и отпечатку текста, домена, телефона. Исключения: домены, телефоны, email, ваша база клиентов из CSV |
| 🗂 **Удобная работа с лидами** | Три панели, фильтры, поиск, избранное, архив, заметки, история, черновик первого обращения |
| ☁️ **Синхронизация (по желанию)** | Вход по почте и данные на нескольких Mac через ваш бесплатный проект Supabase |
| 💾 **Данные под контролем** | Ежедневные резервные копии, копии в Dropbox, Google Диск, Яндекс Диск, iCloud и др., экспорт в CSV и JSON, отправка в Bitrix24, Notion и через вебхук (Make, n8n, Zapier) |
| 🔄 **Автообновление** | Новая версия ставится из приложения со сверкой SHA-256 |
| 🎨 **Нативный macOS** | SwiftUI, светлая и тёмная тема, акцентный цвет, масштаб интерфейса 80–150% |
| 🔒 **Приватность** | Своих серверов и аналитики нет: у локальной учётной записи лиды не покидают Mac |

## 🚀 Быстрый старт

1. Скачайте `Customers-vX.Y.Z-macOS.dmg` со страницы [последнего релиза](https://github.com/xop1tt/CLIENTS/releases/latest).
2. Откройте dmg и перетащите **Lead Generator** в «Программы».
3. При первом запуске: правый клик по приложению → **Открыть** → **Открыть**
   (сборка без платной подписи Apple, macOS спросит один раз).
4. Создайте учётную запись, добавьте в «Источниках» свои Telegram-каналы, RSS-ленты или город и нажмите **«Найти лиды»**.

Нужна macOS 14 Sonoma или новее. Сборка из исходников: [Wiki → Установка](https://github.com/xop1tt/CLIENTS/wiki/Установка).

## 📖 Документация

Подробная документация переехала в **[Wiki](https://github.com/xop1tt/CLIENTS/wiki)**:

| Пользователям | Продвинутым |
|---|---|
| [Установка](https://github.com/xop1tt/CLIENTS/wiki/Установка) | [Поиск в GitHub Actions](https://github.com/xop1tt/CLIENTS/wiki/Поиск-в-GitHub-Actions) (Python, Notion, Telegram) |
| [Работа с приложением](https://github.com/xop1tt/CLIENTS/wiki/Работа-с-приложением) | [Внешние интеграции и бесплатные лимиты](https://github.com/xop1tt/CLIENTS/wiki/Внешние-интеграции) |
| [Источники](https://github.com/xop1tt/CLIENTS/wiki/Источники) | [Разработка и сборка](https://github.com/xop1tt/CLIENTS/wiki/Разработка-и-сборка) |
| [Оценка и фильтры](https://github.com/xop1tt/CLIENTS/wiki/Оценка-и-фильтры) | [Безопасность и конфиденциальность](https://github.com/xop1tt/CLIENTS/wiki/Безопасность-и-конфиденциальность) |
| [Учётные записи и облако](https://github.com/xop1tt/CLIENTS/wiki/Учётные-записи-и-облако) | [Ограничения и планы](https://github.com/xop1tt/CLIENTS/wiki/Ограничения-и-планы) |
| [Резервные копии и экспорт](https://github.com/xop1tt/CLIENTS/wiki/Резервные-копии-и-экспорт) | [Настройка облака Supabase](docs/cloud-setup.md) · [устройство облака](docs/cloud.md) |
| [Обновления и отчёты о сбоях](https://github.com/xop1tt/CLIENTS/wiki/Обновления-и-отчёты-о-сбоях) | [Аудит источников](docs/research.md) |
| [Частые проблемы](https://github.com/xop1tt/CLIENTS/wiki/Частые-проблемы) | [Приложение: исходники](macos/README.md) |

## 📡 Откуда берутся лиды

| Источник | Доступ | Что находит |
|---|---|---|
| RSS-ленты (FL.ru и любые другие) | бесплатно | заказы с бирж: описание, бюджет, ссылка |
| Telegram-каналы | бесплатно | посты публичных каналов с заказами и контактами |
| VK-сообщества | бесплатный ключ | посты открытых сообществ |
| OpenStreetMap + проверка сайтов | бесплатно | организации без сайта или с устаревшим сайтом |

Kwork, Habr Freelance, Яндекс Карты, 2ГИС и поисковые системы не подключены: бесплатно и в рамках правил их
использовать нельзя. Причины: [Wiki → Источники](https://github.com/xop1tt/CLIENTS/wiki/Источники#что-не-подключено-и-почему).

## 🧱 Из чего состоит

```
macos/        приложение для macOS (SwiftUI): поиск, база лидов, учётные записи, облако
supabase/     необязательное облако: миграции Postgres, Edge Functions, тесты
src/leadgen/  Python-версия для поиска по расписанию в GitHub Actions (Notion + Telegram)
docs/         облако и аудит источников
```

## 🔒 Безопасность

Уязвимость? Не создавайте публичный issue, напишите через **Security → Report a vulnerability**.
Подробности: [SECURITY.md](SECURITY.md).

## 📄 Лицензия

Lead Generator распространяется по лицензии **Personal & Internal Business Use License (PIBUL) 1.0**: его можно
бесплатно использовать для себя и внутри своей организации. Продажа, коммерческое распространение и публикация копий
без письменного разрешения автора запрещены. Полный текст: [LICENSE](LICENSE).

<div align="center">
<sub>© 2026 xop1tt · <a href="LICENSE">PIBUL 1.0</a></sub>
</div>
