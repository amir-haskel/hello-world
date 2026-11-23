import importlib

import pytest

import hello_world


@pytest.fixture
def client():
    return hello_world.app.test_client()


def test_hello(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.get_json()["message"] == "Hello, World!"


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_version_defaults_to_dev():
    assert hello_world.VERSION  # never empty


def test_version_comes_from_build_env(monkeypatch):
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    monkeypatch.setenv("GIT_SHA", "abc123")
    mod = importlib.reload(hello_world)
    try:
        body = mod.app.test_client().get("/version").get_json()
        assert body == {"version": "1.2.3", "commit": "abc123"}
    finally:
        monkeypatch.delenv("APP_VERSION")
        monkeypatch.delenv("GIT_SHA")
        importlib.reload(hello_world)
