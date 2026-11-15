#!/usr/bin/env python3
"""A recipe with an image, for the update tests of the tandoor suite (stdlib
only).

It runs on the test host: tests/tandoor/run.sh copies it to /tmp/recipe.py
there. It talks to Tandoor through Traefik on 127.0.0.1 as tandoor.test.

  recipe.py token USER
      Logs USER in with the password on stdin, as Tandoor's UI does (the
      CSRF cookie of the login page, allauth's browser API), and prints a new
      API token (tda_...). One login: Tandoor allows three a minute.
  recipe.py add TOKEN
      Creates a recipe with an image (a PNG of one pixel) and prints its id.
  recipe.py check TOKEN ID
      Fails unless the recipe ID is there with its name and an image that
      downloads (from Tandoor's /media/ or from the signed URL of a bucket);
      prints the SHA-256 of the image.
"""
import base64
import hashlib
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = "http://127.0.0.1"
HOST = "tandoor.test"
ORIGIN = "http://" + HOST
NAME = "Noix update soup"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


def call(method, path, token=None, body=None, content_type=None, headers=None):
    """A request through Traefik; returns the answer, raises on an error."""
    all_headers = {"Host": HOST}
    if token:
        all_headers["Authorization"] = "Bearer " + token
    if content_type:
        all_headers["Content-Type"] = content_type
    all_headers.update(headers or {})
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=all_headers)
    try:
        return urllib.request.urlopen(req)
    except urllib.error.HTTPError as err:
        sys.exit(f"{method} {path} answered {err.code}: {err.read()[:300]!r}")


def cookies(answer):
    """The cookies an answer sets, by name."""
    found = {}
    for header in answer.headers.get_all("Set-Cookie") or []:
        name, _, rest = header.partition("=")
        found[name.strip()] = rest.split(";", 1)[0]
    return found


def token(user):
    csrf = cookies(call("GET", "/account/login/"))["csrftoken"]
    login = call(
        "POST",
        "/_allauth/browser/v1/auth/login",
        body=json.dumps({"username": user, "password": sys.stdin.read()}).encode(),
        content_type="application/json",
        headers={"Cookie": "csrftoken=" + csrf, "X-CSRFToken": csrf, "Origin": ORIGIN},
    )
    session = cookies(login)
    # Django rotates the CSRF token on login.
    csrf = session.get("csrftoken", csrf)
    created = call(
        "POST",
        "/api/access-token/",
        body=json.dumps({"scope": "read write", "expires": "2099-12-31T00:00:00Z"}).encode(),
        content_type="application/json",
        headers={
            "Cookie": f"csrftoken={csrf}; sessionid={session['sessionid']}",
            "X-CSRFToken": csrf,
            "Origin": ORIGIN,
        },
    )
    print(json.load(created)["token"])


def add(api_token):
    recipe = json.load(
        call("POST", "/api/recipe/", api_token, json.dumps({"name": NAME, "steps": []}).encode(), "application/json")
    )
    boundary = uuid.uuid4().hex
    body = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="noix.png"\r\n'
        "Content-Type: image/png\r\n\r\n"
    ).encode() + PNG + f"\r\n--{boundary}--\r\n".encode()
    call("PUT", f"/api/recipe/{recipe['id']}/image/", api_token, body, "multipart/form-data; boundary=" + boundary)
    print(recipe["id"])


def check(api_token, recipe_id):
    recipe = json.load(call("GET", f"/api/recipe/{recipe_id}/", api_token))
    if recipe.get("name") != NAME:
        sys.exit(f"recipe {recipe_id} is {recipe.get('name')!r}, not {NAME!r}")
    image = recipe.get("image") or ""
    if not image:
        sys.exit(f"recipe {recipe_id} has no image")
    url = urllib.parse.urlsplit(image)
    if url.hostname == HOST:
        answer = call("GET", url.path + ("?" + url.query if url.query else ""))
    else:
        try:
            answer = urllib.request.urlopen(image)
        except urllib.error.HTTPError as err:
            sys.exit(f"the image {image} answered {err.code}")
    data = answer.read()
    if not data.startswith(b"\x89PNG"):
        sys.exit(f"the image {image} is not a PNG: {data[:40]!r}")
    print(hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    command, args = sys.argv[1], sys.argv[2:]
    {"token": token, "add": add, "check": check}[command](*args)
