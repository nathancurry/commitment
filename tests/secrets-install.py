#!/usr/bin/env python3
"""Optional offline enabled-install check using an explicitly supplied wheelhouse.

Uses a disposable HOME and fake Podman/systemctl. Never authenticates to Bitwarden.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
wheelhouse = Path(sys.argv[1]).resolve(strict=True)

with tempfile.TemporaryDirectory(prefix="commitment-sdk-install-") as temporary:
    root = Path(temporary)
    home = root / "home"
    home.mkdir()
    config_dir = root / "config/commitment"
    config_dir.mkdir(parents=True)
    config = config_dir / "config.env"
    config.write_text((ROOT / "config.example.env").read_text().replace(
        "BITWARDEN_SECRETS_ENABLED=false", "BITWARDEN_SECRETS_ENABLED=true"))
    config.chmod(0o600)
    original_config = config.read_bytes()
    fakebin = root / "bin"
    fakebin.mkdir()
    for name, content in {
        "podman": '#!/bin/sh\n[ "$1" = info ] || exit 91\nprintf "true\\n"\n',
        "systemctl": '#!/bin/sh\nprintf "%s\\n" "$*" >>"$INSTALL_SYSTEMCTL_LOG"\n',
    }.items():
        path = fakebin / name
        path.write_text(content)
        path.chmod(0o700)
    env = {"HOME": str(home), "USER": "fixture", "PATH": str(fakebin) + ":/usr/bin:/bin",
           "XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
           "COMMITMENT_SKIP_BUILD": "1", "INSTALL_SYSTEMCTL_LOG": str(root / "systemctl.log")}
    runtime = home / ".local/libexec/commitment"
    venv = runtime / "secrets-venv"
    # Site-local pip configuration forces the real installer offline, even with
    # --isolated. No user/global pip settings or operator environment are touched.
    subprocess.run([sys.executable, "-I", "-m", "venv", str(venv)], check=True, env=env)
    (venv / "pip.conf").write_text("[global]\nno-index = true\nfind-links = " + str(wheelhouse) + "\n")
    venv.chmod(0o700)
    subprocess.run([str(ROOT / "install.sh")], check=True, env=env, stdout=subprocess.DEVNULL)
    assert config.read_bytes() == original_config
    for name in ("secret-broker.py", "commitment-secret.py", "requirements-secrets.txt"):
        assert (runtime / name).read_bytes() == (ROOT / name).read_bytes()
        assert not (runtime / name).samefile(ROOT / name)
    assert (root / "systemctl.log").read_text() == "--user daemon-reload\n"
    assert (venv.stat().st_mode & 0o777) == 0o700
    python = str(venv / "bin/python")
    subprocess.run([python, "-IB", str(ROOT / "tests/sdk-contract.py")], check=True, env=env)
    # A hostile cwd/PYTHONPATH cannot replace the installed SDK under -I.
    (root / "bitwarden_sdk.py").write_text('raise RuntimeError("untrusted module")\n')
    subprocess.run([python, "-I", "-c", "from bitwarden_sdk import BitwardenClient"],
                   check=True, env={**env, "PYTHONPATH": str(root)}, cwd=root)
    subprocess.run([str(ROOT / "install.sh")], check=True, env=env, stdout=subprocess.DEVNULL)
    assert config.read_bytes() == original_config
    subprocess.run([str(ROOT / "uninstall.sh")], check=True, env=env, stdout=subprocess.DEVNULL)
    assert not (runtime / "secret-broker.py").exists()
    assert config.read_bytes() == original_config
    assert venv.is_dir()
print("ok - offline enabled install/reinstall, private importable SDK, installed copies, and uninstall preservation")
