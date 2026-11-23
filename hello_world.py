"""Hello World microservice that reports its own version.

The version is baked into the container image at build time
(Dockerfile ARG -> ENV APP_VERSION). It is never overridden at runtime,
so a running container always reports the exact version it was built as.
"""

import os
import sys

from flask import Flask, jsonify

VERSION = os.environ.get("APP_VERSION", "0.0.0-dev")
GIT_SHA = os.environ.get("GIT_SHA", "unknown")

app = Flask(__name__)


@app.get("/")
def hello():
    return jsonify(message="Hello, Worlds!", version=VERSION)


@app.get("/version")
def version():
    return jsonify(version=VERSION, commit=GIT_SHA)


@app.get("/health")
def health():
    return jsonify(status="ok")


if __name__ == "__main__":
    if "--version" in sys.argv:
        print(VERSION)
        sys.exit(0)
    # Local development only. In the container, gunicorn serves the app.
    app.run(host="127.0.0.1", port=int(os.environ.get("PORT", "8080")))
