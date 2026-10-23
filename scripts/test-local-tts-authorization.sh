#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
backend_root="${MIKU_TTS_BACKEND_ROOT:-${repository_root:h}/miku-tts}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/miku-local-tts-auth.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

test_binary="$temporary_root/miku-local-tts-authorization-tests"
interop_helper="$temporary_root/backend-interop.py"

cat > "$interop_helper" <<'PYTHON'
import hashlib
import json
import os
import sys
from pathlib import Path

backend_root = os.environ["MIKU_TTS_BACKEND_ROOT"]
sys.path.insert(0, backend_root)

from local_license.core import AttestationResult, LicenseAuthority


class TestOnlyAttestationVerifier:
    def verify_enrollment(self, attestation, client_data_hash, device_id):
        if attestation != {"test_only": "mock"} or len(client_data_hash) != 32:
            raise ValueError("test attestation input mismatch")
        return AttestationResult(key_id="test-only-attestation", counter=0)

    def verify_assertion(self, *args, **kwargs):
        raise AssertionError("renew is outside this interop test")


state_directory, mode, input_path, output_path = sys.argv[1:]
state_directory = Path(state_directory)
request = json.loads(Path(input_path).read_text(encoding="utf-8"))
clock = lambda: 1_700_000_000
verifier = TestOnlyAttestationVerifier()

if mode == "prepare":
    authority = LicenseAuthority.create(
        state_directory,
        clock=clock,
        attestation_verifier=verifier,
    )
    dek = bytes(range(32))
    authority.create_entitlement("interop-entitlement", max_devices=1)
    authority.register_release(request["release_id"], request["manifest_sha256"], dek=dek)
    activation_token = authority.create_activation("interop-entitlement")
    challenge = authority.challenge({
        "v": 1,
        "op": "enroll",
        "device_id": request["device_id"],
        "release_id": request["release_id"],
        "signing_public_key": request["signing_public_key"],
        "agreement_public_key": request["agreement_public_key"],
    })
    response = {
        **challenge,
        "activation_token": activation_token,
        "server_public_key": authority.public_signing_key(),
        "dek_sha256": hashlib.sha256(dek).hexdigest(),
    }
elif mode == "grant":
    authority = LicenseAuthority(
        state_directory / "license.sqlite3",
        state_directory / "lease-ed25519.key",
        clock=clock,
        attestation_verifier=verifier,
    )
    response = {"lease": authority.grant(request, "enroll")}
else:
    raise ValueError("unknown mode")

Path(output_path).write_text(
    json.dumps(response, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PYTHON

xcrun swiftc \
    "$repository_root/Sources/MikuDesktop/MikuLocalTTSAuthorization.swift" \
    "$repository_root/Tests/MikuLocalTTSAuthorizationTests.swift" \
    -o "$test_binary" \
    -framework Security \
    -framework LocalAuthentication \
    -framework DeviceCheck

MIKU_TTS_BACKEND_ROOT="$backend_root" \
MIKU_BACKEND_INTEROP_HELPER="$interop_helper" \
MIKU_TEST_TEMP_DIR="$temporary_root" \
PYTHONDONTWRITEBYTECODE=1 \
    "$test_binary"
