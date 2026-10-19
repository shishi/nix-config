#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit


def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def token(secret, role, issued_at):
    header = encode(
        json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    claims = {
        "role": role,
        "iss": "supabase",
        "iat": issued_at,
        "exp": issued_at + 20 * 366 * 86400,
    }
    payload = encode(json.dumps(claims, separators=(",", ":")).encode())
    message = f"{header}.{payload}"
    signature = encode(hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest())
    return f"{message}.{signature}"


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: readest-init.py ENV_FILE HTTPS_ORIGIN")
    destination = Path(sys.argv[1])
    if destination.exists():
        return
    origin = sys.argv[2].rstrip("/")
    parsed = urlsplit(origin)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path
        or parsed.query
        or parsed.fragment
        or any(character in origin for character in "\r\n'")
    ):
        raise SystemExit("Readest requires a valid HTTPS origin.")
    jwt_secret = secrets.token_hex(32)
    issued_at = int(time.time())
    values = {
        "HOST_IP": parsed.hostname,
        "POSTGRES_PASSWORD": secrets.token_hex(32),
        "POSTGRES_HOST": "db",
        "POSTGRES_PORT": "5432",
        "POSTGRES_DB": "postgres",
        "JWT_EXPIRY": "3600",
        "JWT_SECRET": jwt_secret,
        "ANON_KEY": token(jwt_secret, "anon", issued_at),
        "SERVICE_ROLE_KEY": token(jwt_secret, "service_role", issued_at),
        "KONG_HTTP_PORT": "8000",
        "API_EXTERNAL_URL": origin,
        "SITE_URL": origin,
        "ADDITIONAL_REDIRECT_URLS": f"{origin}/**",
        "SUPABASE_PUBLIC_URL": origin,
        "S3_PUBLIC_ENDPOINT": origin,
        "DISABLE_SIGNUP": "false",
        "ENABLE_EMAIL_SIGNUP": "true",
        "ENABLE_EMAIL_AUTOCONFIRM": "true",
        "ENABLE_ANONYMOUS_USERS": "false",
        "SMTP_HOST": "",
        "SMTP_PORT": "587",
        "SMTP_USER": "",
        "SMTP_PASS": "",
        "SMTP_ADMIN_EMAIL": "",
        "SMTP_SENDER_NAME": "Readest",
        "PGRST_DB_SCHEMAS": "public,graphql_public",
        "OBJECT_STORAGE_TYPE": "s3",
        "S3_ACCESS_KEY_ID": secrets.token_hex(10),
        "S3_SECRET_ACCESS_KEY": secrets.token_hex(32),
        "S3_BUCKET_NAME": "readest-files",
        "SELF_HOSTED": "true",
        "STORAGE_FIXED_QUOTA": "1073741824",
        "TRANSLATION_FIXED_QUOTA": "50000",
        "FONT_BASE_URL": "",
    }
    content = "".join(f"{key}='{value}'\n" for key, value in values.items())
    descriptor, temporary_name = tempfile.mkstemp(prefix=".env-", dir=destination.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary, destination)
    finally:
        temporary.unlink()


if __name__ == "__main__":
    main()
