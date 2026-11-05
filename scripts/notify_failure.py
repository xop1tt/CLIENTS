"""Аварийное уведомление о падении workflow (только stdlib — сработает, даже если сломались зависимости)."""
import json
import os
import random
import urllib.request

PHRASES = ["Полный пиздец, дядь. Запуск упал целиком.", "Workflow лёг лицом в пол.",
           "Красная тревога! GitHub Actions не доехал до конца.", "Всё, приплыли. Нужны твои золотые руки."]


def main() -> None:
    if os.environ.get("LEADGEN_MODE") != "live":
        print("dry-run: аварийное уведомление не отправляется")
        return
    if os.path.exists("state/critical_notified"):
        print("Критический сбой уже сообщён из приложения")
        return
    token, chat = os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID")
    if not token or not chat:
        print("Telegram не настроен")
        return
    text = f"{random.choice(PHRASES)}\nМодуль: GitHub Actions (вся система)\nЛог: {os.environ.get('RUN_URL', '')}"
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",
                                 data=json.dumps({"chat_id": chat, "text": text}).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:  # noqa: BLE001
        print(f"Не удалось отправить: {type(e).__name__}")


if __name__ == "__main__":
    main()
