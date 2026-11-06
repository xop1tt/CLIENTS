"""Подписывает тестовые JWT (anon, service_role) секретом локального стенда."""
import base64, hashlib, hmac, json, sys

def b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

secret, role = sys.argv[1], sys.argv[2]
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
payload = b64(json.dumps({"role": role, "iss": "supabase-local", "iat": 1735689600, "exp": 4102444800}).encode())
sig = b64(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
print(f"{header}.{payload}.{sig}")
