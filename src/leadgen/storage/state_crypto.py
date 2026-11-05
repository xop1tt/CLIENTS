"""Шифрование файла состояния перед сохранением в кэш GitHub Actions.

Кэш публичного репозитория может быть восстановлен workflow из pull request'а форка,
поэтому база с контактами хранится там только в зашифрованном виде (Fernet, AES-128-CBC + HMAC).
"""
from __future__ import annotations

import base64
import hashlib
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken


def _fernet(secret: str) -> Fernet:
    key = base64.urlsafe_b64encode(hashlib.sha256(secret.encode("utf-8")).digest())
    return Fernet(key)


def encrypt_file(src: Path, dst: Path, secret: str) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(_fernet(secret).encrypt(src.read_bytes()))


def decrypt_file(src: Path, dst: Path, secret: str) -> bool:
    """False — неверный ключ или повреждённый файл (тогда восстанавливаемся из Notion)."""
    try:
        data = _fernet(secret).decrypt(src.read_bytes())
    except (InvalidToken, OSError):
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)
    return True
