"""Host and category settings for the cmem Hermes plugin come from the environment."""
import importlib.util
import sys
import types
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[1] / "plugins/cmem/__init__.py"


def load(monkeypatch, **env):
    for key in ("CMEM_PROJECT", "CMEM_HOST_PROJECTS", "CMEM_CATEGORIES"):
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    stub = types.ModuleType("agent.memory_provider")
    stub.MemoryProvider = object
    monkeypatch.setitem(sys.modules, "agent", types.ModuleType("agent"))
    monkeypatch.setitem(sys.modules, "agent.memory_provider", stub)
    spec = importlib.util.spec_from_file_location("cmem_plugin_under_test", PLUGIN)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_hostname_maps_through_env(monkeypatch):
    plugin = load(monkeypatch, CMEM_HOST_PROJECTS="box-a=hermes-alpha, bad, box-b = hermes-beta,=x")
    monkeypatch.setattr(plugin.socket, "gethostname", lambda: "box-b.example.internal")
    assert plugin._project() == "hermes-beta"
    assert plugin._HOST_PROJECTS == {"box-a": "hermes-alpha", "box-b": "hermes-beta"}


def test_unmapped_host_falls_back_to_hostname(monkeypatch):
    plugin = load(monkeypatch)
    monkeypatch.setattr(plugin.socket, "gethostname", lambda: "box-c")
    assert plugin._HOST_PROJECTS == {}
    assert plugin._project() == "hermes-box-c"


def test_categories_extend_the_defaults(monkeypatch):
    assert load(monkeypatch)._CATEGORIES == ["user", "project", "agent"]
    assert load(monkeypatch, CMEM_CATEGORIES="org-a, org-b")._CATEGORIES == [
        "user", "project", "agent", "org-a", "org-b"]
