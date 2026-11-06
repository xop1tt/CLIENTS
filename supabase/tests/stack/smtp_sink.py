"""Тестовый SMTP-сервер: принимает письма и складывает их в папку как JSON.

Только для локального стенда. Если существует файл <dir>/FAIL, сервер отвечает ошибкой 451
на RCPT — так тесты проверяют «почтовый провайдер недоступен».
"""

import asyncio
import base64
import email
import email.policy
import json
import sys
import time
import uuid
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/lg-mail")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2525
OUT.mkdir(parents=True, exist_ok=True)


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    def send(line: str) -> None:
        writer.write((line + "\r\n").encode())

    send("220 lg-sink ready")
    rcpt: list[str] = []
    auth_user = None
    while True:
        raw = await reader.readline()
        if not raw:
            break
        line = raw.decode(errors="replace").rstrip("\r\n")
        cmd = line.split(" ")[0].upper()
        if cmd in ("EHLO", "HELO"):
            send("250-lg-sink")
            send("250 AUTH PLAIN LOGIN")
        elif cmd == "AUTH":
            parts = line.split(" ")
            if len(parts) > 2 and parts[1].upper() == "PLAIN":
                dec = base64.b64decode(parts[2]).split(b"\x00")
                auth_user = dec[1].decode()
                ok = dec[2] == b"sink-pass"
                send("235 ok" if ok else "535 bad credentials")
            else:
                send("504 unsupported")
        elif cmd == "MAIL":
            rcpt = []
            send("250 ok")
        elif cmd == "RCPT":
            to = line.split(":", 1)[1].strip().strip("<>")
            # FAIL с адресом внутри — ошибка только для этого получателя, иначе для всех.
            only = (OUT / "FAIL").read_text().strip() if (OUT / "FAIL").exists() else None
            if only is not None and (only in ("", "1") or only == to):
                send("451 temporary failure")
            else:
                rcpt.append(to)
                send("250 ok")
        elif cmd == "DATA":
            send("354 go ahead")
            await writer.drain()
            data = b""
            while True:
                chunk = await reader.readline()
                if chunk in (b".\r\n", b".\n", b""):
                    break
                if chunk.startswith(b".."):
                    chunk = chunk[1:]
                data += chunk
            msg = email.message_from_bytes(data, policy=email.policy.default)
            body = msg.get_body(preferencelist=("plain",))
            html = msg.get_body(preferencelist=("html",))
            rec = {
                "to": rcpt, "subject": str(msg["subject"]), "from": str(msg["from"]), "user": auth_user,
                "text": body.get_content() if body else "", "html": html.get_content() if html else "",
                "at": time.time(),
            }
            (OUT / f"{time.time():.6f}-{uuid.uuid4().hex}.json").write_text(json.dumps(rec, ensure_ascii=False))
            send("250 queued")
        elif cmd == "QUIT":
            send("221 bye")
            await writer.drain()
            break
        else:
            send("250 ok")
        await writer.drain()
    writer.close()


async def main() -> None:
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server:
        await server.serve_forever()


asyncio.run(main())
