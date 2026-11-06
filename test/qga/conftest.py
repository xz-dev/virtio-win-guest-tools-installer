"""Disposable, already-running libvirt/SSH guest. No VM lifecycle or credential manager."""
import base64
import json
import os
import shlex
import subprocess
import time
import uuid
from pathlib import Path

import pytest


class Guest:
    def __init__(self, settings, output):
        self.settings = settings
        self.output = output
        self.directory = "C:/qga-acceptance/" + uuid.uuid4().hex
        self.current = None
        self.auth_failed = False
        self.sequence = 0
        self.pending = False

    def ssh(self, script):
        script = "$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.Encoding]::UTF8;" + script
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        try:
            result = subprocess.run(
                [*self.settings["wrapper"], "ssh", "-o", "BatchMode=yes", self.settings["ssh"],
                 "powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                capture_output=True, text=True, timeout=240,
            )
        except subprocess.TimeoutExpired:
            self.pending = True
            pytest.exit("Remote operation timed out; preserve guest instead of starting another installer", 3)
        if result.returncode == 5 or "permission denied" in result.stderr.lower():
            self.auth_failed = True
            pytest.exit("SSH authentication failed; no retry or alternate authentication attempted", 3)
        if result.returncode == 255:
            self.pending = True
            pytest.exit("SSH transport or authentication failed; preserve guest without retry or cleanup", 3)
        assert result.returncode == 0, result.stderr
        return result.stdout.strip().lstrip("\ufeff")

    def copy(self, source, name):
        destination = self.directory + "/" + name
        result = subprocess.run(
            [*self.settings["wrapper"], "scp", "-o", "BatchMode=yes", str(source),
             self.settings["ssh"] + ":" + destination],
            capture_output=True, text=True, timeout=240,
        )
        if result.returncode == 5 or "permission denied" in result.stderr.lower():
            self.auth_failed = True
            pytest.exit("SCP authentication failed; no retry or alternate authentication attempted", 3)
        if result.returncode == 255:
            self.pending = True
            pytest.exit("SCP transport or authentication failed; preserve guest without retry or cleanup", 3)
        assert result.returncode == 0, result.stderr
        return destination

    def state(self):
        return json.loads(self.ssh(r"""
$roots=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
$products=@(foreach($root in $roots){Get-ItemProperty "$root\*" -ErrorAction SilentlyContinue |
 Where-Object {$_.DisplayName -like 'QEMU guest agent*'} |
 Select-Object PSPath,DisplayName,DisplayVersion})
$service=Get-Service QEMU-GA -ErrorAction SilentlyContinue
$files=@();$hash=$null
if($service){
 $image=(Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Services\QEMU-GA).ImagePath
 if($image -notmatch '^"([^"]+qemu-ga\.exe)"'){throw 'Unexpected Agent service executable path'}
 $exe=$Matches[1];$files=@(Get-ChildItem (Split-Path $exe) -File | ForEach-Object Name)
 if(Test-Path $exe){$hash=(Get-FileHash $exe -Algorithm SHA256).Hash}
}
[ordered]@{products=$products;service=[string]$service.Status;files=$files;agentSha256=$hash;
 provider=($null -ne (Get-Service 'QEMU Guest Agent VSS Provider' -ErrorAction SilentlyContinue))} |
 ConvertTo-Json -Depth 5 -Compress
"""))

    def run(self, bundle, arguments=()):
        self.sequence += 1
        log = self.directory + f"/{self.sequence}.log"
        # Only fixed switches/numeric choices are passed by these tests, never shell input or secrets.
        args = " ".join(["/quiet", "/norestart", "/log", log, *arguments])
        self.pending = True
        text = self.ssh(
            f"$p=Start-Process '{bundle}' -ArgumentList '{args}' -PassThru;"
            "if($p.WaitForExit(180000)){$p.ExitCode}else{'QGA_TEST_PENDING'}"
        )
        if text == "QGA_TEST_PENDING":
            pytest.exit("Installer still running; preserve guest and inspect it before another test", 3)
        code = int(text)
        self.pending = False
        content = self.ssh(f"Get-Content '{log}' -Raw")
        (self.output / f"{self.sequence}.log").write_text(content)
        snapshot = self.state()
        (self.output / f"{self.sequence}-state.json").write_text(json.dumps(snapshot, indent=2))
        return code, content

    def install(self, bundle, choice=None):
        args = () if choice is None else (f"QgaVssEnabled={choice}",)
        code, _ = self.run(bundle, args)
        assert code in (0, 3010), f"Install/upgrade returned {code}; see retained log"
        self.current = bundle

    def blocked(self, bundle, arguments):
        before = self.state()
        code, log = self.run(bundle, arguments)
        assert code not in (0, 3010), "Opposite choice or unavailable prerequisite was accepted"
        assert "Apply begin" not in log, "Refusal occurred after Apply began"
        assert self.state() == before, "Refused operation changed delivered Agent state"

    def rpc(self, command):
        deadline = time.monotonic() + 60
        while True:
            result = subprocess.run(
                ["virsh", "-c", self.settings["uri"], "qemu-agent-command", self.settings["domain"],
                 json.dumps({"execute": command}), "--timeout", "8"],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode == 0:
                return json.loads(result.stdout)
            if command == "guest-fsfreeze-status" and "fsfreeze not possible as VSS failed to initialize" in result.stderr:
                return {"vssUnavailable": result.stderr.strip()}
            assert "not configured" not in result.stderr, "Configure the test QGA channel before running"
            assert time.monotonic() < deadline, result.stderr
            time.sleep(2)

    def agent(self, full, version):
        state = self.state()
        assert len(state["products"]) == 1
        assert state["service"] == "Running" and state["agentSha256"]
        assert "qemu-ga.exe" in state["files"]
        assert state["provider"] is full
        for name in ("qga-vss.dll", "qga-vss.tlb"):
            assert (name in state["files"]) is full
        info = self.rpc("guest-info")
        assert info["return"]["version"] == version
        freeze = self.rpc("guest-fsfreeze-status")
        if full:
            assert freeze == {"return": "thawed"}
        else:
            assert "vssUnavailable" in freeze
        (self.output / f"{self.sequence}-rpc.json").write_text(json.dumps({"info": info, "freeze": freeze}, indent=2))

    def start_type(self, service):
        return int(self.ssh(rf"(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\{service}').Start"))

    def set_start_type(self, service, value):
        # Set-Service changes configuration only: deliberately do not stop a running COM+ service.
        mode = {2: "Automatic", 3: "Manual", 4: "Disabled"}[value]
        self.ssh(f"Set-Service '{service}' -StartupType {mode}")


@pytest.fixture
def guest(tmp_path):
    if os.environ.get("QGA_TEST_ALLOW_INSTALL") != "1":
        pytest.skip("Destructive disposable-guest tests require QGA_TEST_ALLOW_INSTALL=1")
    names = ("SSH", "DOMAIN", "OLD_BUNDLE", "NEW_BUNDLE", "OLD_VERSION", "NEW_VERSION")
    missing = [name for name in names if not os.environ.get("QGA_TEST_" + name)]
    assert not missing, "Missing QGA_TEST settings: " + ", ".join(missing)
    settings = {name.lower(): os.environ["QGA_TEST_" + name] for name in names}
    settings.update(uri=os.environ.get("QGA_TEST_URI", "qemu:///system"),
                    wrapper=shlex.split(os.environ.get("QGA_TEST_SSH_WRAPPER", "")))
    assert settings["old_version"] != settings["new_version"], "An upgrade requires different actual Agent versions"
    output = Path(os.environ.get("QGA_TEST_OUTPUT", str(tmp_path))) / uuid.uuid4().hex
    output.mkdir(parents=True, exist_ok=True)
    vm = Guest(settings, output)
    before = vm.state()
    assert not before["products"] and not before["service"] and not before["provider"], "Restore a clean disposable snapshot first"
    # Missing channel is a fixture failure, not evidence that a particular Agent variant failed.
    xml = subprocess.run(["virsh", "-c", settings["uri"], "dumpxml", settings["domain"]],
                         check=True, capture_output=True, text=True).stdout
    assert "org.qemu.guest_agent.0" in xml, "The running test VM needs its guest-agent channel"
    vm.ssh(f"New-Item -ItemType Directory -Force '{vm.directory}' | Out-Null")
    vm.old = vm.copy(Path(settings["old_bundle"]), "old.exe")
    vm.new = vm.copy(Path(settings["new_bundle"]), "new.exe")
    try:
        yield vm
    finally:
        if not vm.auth_failed and not vm.pending:
            if vm.current:
                code, _ = vm.run(vm.current, ("/uninstall",))
                assert code in (0, 3010), "Cleanup failed; preserve logs and restore the operator's snapshot"
            after = vm.state()
            assert not after["products"] and not after["service"] and not after["provider"], "Guest not clean; do not guess product ownership"
