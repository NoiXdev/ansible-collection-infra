#!/usr/bin/env python3
"""Registers an account on a Vaultwarden server, as the official clients do.

    client.py register <url> <email> <password> [<invite link>]

The master key is PBKDF2-SHA256 of the password, salted with the address
(600000 iterations); the server gets the master password hash (one more
PBKDF2 round, salted with the password) and the account's keys encrypted as
the clients encrypt them: a random 64-byte symmetric key as an EncString of
type 2 (AES-256-CBC with HMAC-SHA256) under the stretched master key, and an
RSA key pair whose private key is encrypted under that symmetric key.

With an invite link (the link of the invitation mail the admin page sends),
the registration carries the invitation's token; without one it asks for a
registration token first, which the server hands out only when signups are
allowed or, with mail off, for an invited address.

Prints nothing on success; exits 1 with the server's message otherwise.
CLIENT_INSECURE_TLS=1 accepts any certificate (the tests' Traefik serves its
own). Needs python3-cryptography.
"""

import base64
import hashlib
import hmac
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import padding, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ITERATIONS = 600000
PBKDF2 = 0
CONTEXT = ssl._create_unverified_context() if os.environ.get("CLIENT_INSECURE_TLS") == "1" else None


class ServerError(Exception):
    pass


def b64(data):
    return base64.b64encode(data).decode()


def hkdf_expand(key, info):
    # HKDF-Expand (RFC 5869) with SHA-256: one block is the 32 bytes needed.
    return hmac.new(key, info + b"\x01", hashlib.sha256).digest()


def enc_string(data, enc_key, mac_key):
    """EncString type 2: 2.<iv>|<ciphertext>|<mac>, base64 each."""
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    encryptor = Cipher(algorithms.AES(enc_key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(padded) + encryptor.finalize()
    mac = hmac.new(mac_key, iv + ciphertext, hashlib.sha256).digest()
    return "2." + b64(iv) + "|" + b64(ciphertext) + "|" + b64(mac)


def post(url, path, body):
    request = urllib.request.Request(
        url.rstrip("/") + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60, context=CONTEXT) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        text = error.read().decode(errors="replace")
        try:
            message = json.loads(text).get("message") or text
        except ValueError:
            message = text
        raise ServerError("%s answered %d: %s" % (path, error.code, message.strip()[:300]))
    return json.loads(text) if text.strip() else None


def register(url, email, password, invite_link=None):
    email = email.strip().lower()
    master_key = hashlib.pbkdf2_hmac("sha256", password.encode(), email.encode(), ITERATIONS)
    master_password_hash = b64(hashlib.pbkdf2_hmac("sha256", master_key, password.encode(), 1))
    stretched_enc = hkdf_expand(master_key, b"enc")
    stretched_mac = hkdf_expand(master_key, b"mac")

    user_key = os.urandom(64)
    protected_user_key = enc_string(user_key, stretched_enc, stretched_mac)

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_der = private_key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    private_der = private_key.private_bytes(
        serialization.Encoding.DER, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )

    body = {
        "email": email,
        "masterPasswordHash": master_password_hash,
        "masterPasswordHint": None,
        "userSymmetricKey": protected_user_key,
        "userAsymmetricKeys": {
            "publicKey": b64(public_der),
            "encryptedPrivateKey": enc_string(private_der, user_key[:32], user_key[32:]),
        },
        "kdf": PBKDF2,
        "kdfIterations": ITERATIONS,
    }
    if invite_link:
        # http://host/#/accept-organization/?email=...&organizationUserId=...&token=...
        query = urllib.parse.parse_qs(invite_link.split("?", 1)[-1])
        try:
            body["orgInviteToken"] = query["token"][0]
            body["organizationUserId"] = query["organizationUserId"][0]
        except KeyError:
            raise ServerError("the invite link has no token or organizationUserId")
    else:
        token = post(url, "/identity/accounts/register/send-verification-email", {"email": email, "name": None})
        if not isinstance(token, str):
            raise ServerError("the server sent a verification mail instead of a registration token")
        body["emailVerificationToken"] = token
    post(url, "/identity/accounts/register/finish", body)


def main(argv):
    if len(argv) not in (5, 6) or argv[1] != "register":
        sys.stderr.write("usage: client.py register <url> <email> <password> [<invite link>]\n")
        return 2
    try:
        register(argv[2], argv[3], argv[4], argv[5] if len(argv) == 6 else None)
    except (ServerError, urllib.error.URLError) as error:
        sys.stderr.write("%s\n" % error)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
