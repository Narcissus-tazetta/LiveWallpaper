#!/usr/bin/env python3
import base64
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sign_zip.py <private_pem_path> <zip_path>", file=sys.stderr)
        return 1

    private_key_path = Path(sys.argv[1])
    zip_path = Path(sys.argv[2])

    if not private_key_path.exists():
        print(f"private key not found: {private_key_path}", file=sys.stderr)
        return 1
    if not zip_path.exists():
        print(f"zip not found: {zip_path}", file=sys.stderr)
        return 1

    private_key = serialization.load_pem_private_key(private_key_path.read_bytes(), password=None)
    signature = private_key.sign(zip_path.read_bytes())
    print(base64.b64encode(signature).decode("ascii"), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
