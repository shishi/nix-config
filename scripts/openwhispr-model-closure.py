import base64
import json
import sys

manifest = json.load(open(sys.argv[1]))
document = json.load(open(sys.argv[2]))
derivations = document.get("derivations", document)
hashes = set()
for model in manifest["models"]:
    digest = model["sha256"].lower()
    hashes.add(digest)
    hashes.add("sha256-" + base64.b64encode(bytes.fromhex(digest)).decode())

for name, derivation in derivations.items():
    for output in derivation["outputs"].values():
        if output.get("hash") in hashes:
            print("Model bytes entered the system derivation closure: " + name, file=sys.stderr)
            sys.exit(1)

print("The system derivation closure excludes the declared model outputs")
