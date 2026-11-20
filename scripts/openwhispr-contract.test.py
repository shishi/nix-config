import json
import shlex
import sys

config = json.load(open(sys.argv[1]))


def options(command):
    return shlex.split(command)


for name, port in (("whisper", "8178"), ("cleanup", "8179")):
    service = config["services"].get("openwhispr-" + name, {})
    args = options(service.get("exec", ""))
    assert "--host" in args, f"{name} must bind explicitly to loopback"
    assert args[args.index("--host") + 1] == "127.0.0.1"
    assert args[args.index("--port") + 1] == port
    assert service["user"] == "openwhispr"
    assert "openwhispr-models.service" in service.get("requisite", []), "Preparation failures must not be restarted through consumers"
    assert service["timeout"] == "11min"

cleanup = options(config["services"]["openwhispr-cleanup"]["exec"])
assert cleanup[cleanup.index("--sleep-idle-seconds") + 1] == "-1"
assert cleanup[cleanup.index("--alias") + 1] == "gemma-4-e4b"
whisper = options(config["services"]["openwhispr-whisper"]["exec"])
assert "--convert" in whisper
assert whisper[whisper.index("--language") + 1] == "auto"
assert whisper[whisper.index("--inference-path") + 1] == "/v1/audio/transcriptions"
serve = config["services"]["openwhispr-serve"]
assert all(not dependency.startswith("openwhispr-") for dependency in serve["requires"])
assert "tailscaled-autoconnect.service" in serve["after"]
assert "openwhispr-serve.service" in config["tailscaledWants"]
assert "render" in config["groups"] and config["graphics"]
models = config["services"]["openwhispr-models"]
assert models["state"] == "openwhispr-models"
assert models.get("stopIfChanged", True) is False, "Model preparation must restart before consumers during switch"
assert models["preventRestart"] == [65]
assert {"openwhispr-whisper.service", "openwhispr-cleanup.service"} <= set(models["wants"])
print("OpenWhispr startup, loopback, GPU access and independent publication contracts passed")
