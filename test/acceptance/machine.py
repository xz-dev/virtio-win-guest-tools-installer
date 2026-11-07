"""A disposable Windows test machine: a libvirt VM reached over SSH.

Configuration (environment):
  PR85_VM            libvirt domain name of the test VM
  PR85_SSH           ssh destination of the VM, e.g. tester@192.168.122.10 (key auth via your ssh config)
  PR85_LIBVIRT_URI   optional, default qemu:///system
  PR85_SSH_WRAPPER   optional command put in front of ssh/scp (e.g. for password auth or a pinned known_hosts)
"""
import base64
import json
import os
import shlex
import signal
import subprocess
import time
from pathlib import Path

import pytest

GUEST_DIR = r"C:\virtio-win-acceptance"
HERE = Path(__file__).resolve().parent


class Machine:
    def __init__(self, domain, ssh, uri="qemu:///system", wrapper=()):
        self.domain, self.ssh, self.uri, self.wrapper = domain, ssh, uri, list(wrapper)
        self.step = 0
        self.auth_failed = False

    def _check_auth(self, result=None):
        if result is not None:
            diagnostic = (result.stderr or "").casefold()
            self.auth_failed |= result.returncode == 5 or any(message in diagnostic for message in (
                "permission denied", "too many authentication failures", "authentication failed"))
        if self.auth_failed:
            pytest.exit("SSH/SCP authentication failed; no further guest actions or cleanup will run.", returncode=3)

    # --- VM lifecycle (always graceful; never a forced power-off) ---
    def _virsh(self, *args):
        self._check_auth()
        return subprocess.run(["virsh", "-c", self.uri, *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def start_from(self, snapshot):
        self.shutdown()
        self._virsh("snapshot-revert", self.domain, snapshot)
        if self._virsh("domstate", self.domain) != "running":
            self._virsh("start", self.domain)
        self._wait_until_reachable()
        self.powershell(f"New-Item -ItemType Directory -Force '{GUEST_DIR}' | Out-Null")
        for name in ("observe.ps1", "Cancel.cs"):
            self.copy_in(HERE / "guest" / name, f"{GUEST_DIR}\\{name}")

    def shutdown(self):
        if self.auth_failed:
            return  # Leave recovery to the operator; do not make another connection or lifecycle call.
        if self._virsh("domstate", self.domain) == "shut off":
            return
        self.powershell("shutdown.exe /s /t 0", check=False)
        for _ in range(60):
            time.sleep(5)
            if self._virsh("domstate", self.domain) == "shut off":
                return
        raise TimeoutError("VM did not shut down; resolve it by hand, do not force it off")

    def reboot(self):
        deadline = time.monotonic() + 600
        before = self._boot_time(timeout=min(20, max(0, deadline - time.monotonic())))
        print(f"{self.domain}: requesting reboot; prior boot time {before}", flush=True)
        self.powershell("shutdown.exe /r /t 0", check=False)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                # SSH can briefly answer before the old Windows session goes away.
                after = self._boot_time(timeout=min(20, remaining))
                if after and after != before:
                    print(f"{self.domain}: new boot time {after}", flush=True)
                    return
            except RuntimeError:
                print(f"{self.domain}: boot-time query unavailable; waiting within the original deadline", flush=True)
            time.sleep(min(10, max(0, deadline - time.monotonic())))
        raise TimeoutError("Windows did not become reachable with a new boot time within the reboot budget")

    def _boot_time(self, timeout=20):
        return self.powershell("(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')", timeout=timeout)

    def _wait_until_reachable(self, timeout=600):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                if self.powershell("'ok'", check=False, timeout=min(20, remaining)) == "ok":
                    return
            except RuntimeError:
                pass  # Only a read-only probe timed out; authentication failures exit the suite.
            time.sleep(min(10, max(0, deadline - time.monotonic())))
        raise TimeoutError("VM not reachable over ssh within the readiness budget")

    # --- transport ---
    def powershell(self, script, check=True, timeout=None):
        """Only read-only probes set timeout; installer and cancellation calls remain unbounded."""
        self._check_auth()
        encoded = base64.b64encode(("$ProgressPreference='SilentlyContinue';" + script).encode("utf-16-le")).decode()
        command = [*self.wrapper, "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", self.ssh,
                   f"powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded}"]
        if timeout is None:
            result = subprocess.run(command, capture_output=True, text=True)
        else:
            if timeout <= 0:
                raise RuntimeError("Read-only guest query has no remaining time")
            print(f"{self.domain}: read-only query start (limit {timeout:.1f}s)", flush=True)
            # Reserve part of this call's budget for draining/reaping the owned query.
            deadline = time.monotonic() + timeout
            drain_reserve = min(0.1, timeout / 5)
            query = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, start_new_session=True)
            try:
                try:
                    stdout, stderr = query.communicate(timeout=max(0, deadline - time.monotonic() - drain_reserve))
                except subprocess.TimeoutExpired as expired:
                    def diagnostic(value):
                        return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")
                    stderr = diagnostic(expired.stderr)
                    try:
                        os.killpg(query.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        _, final_stderr = query.communicate(timeout=max(0, deadline - time.monotonic()))
                        stderr += diagnostic(final_stderr)
                    except subprocess.TimeoutExpired as draining:
                        stderr += diagnostic(draining.stderr)
                    try:
                        query.wait(timeout=max(0, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        pass  # Do not wait for an escaped/unproven pipe holder.
                    self._check_auth(subprocess.CompletedProcess(command, query.returncode, "", stderr))
                    print(f"{self.domain}: read-only query timed out", flush=True)
                    raise RuntimeError(f"Read-only guest query timed out within its {timeout:.1f}s budget") from None
                result = subprocess.CompletedProcess(command, query.returncode, stdout, stderr)
            finally:
                # Popen.__exit__ would wait without a limit. Close only our captured ends.
                for pipe in (query.stdin, query.stdout, query.stderr):
                    if pipe is not None:
                        pipe.close()
            print(f"{self.domain}: read-only query returned status {result.returncode}", flush=True)
        self._check_auth(result)
        if check and result.returncode != 0:
            raise RuntimeError(f"guest command failed ({result.returncode}): {result.stderr.strip()}")
        return result.stdout.strip()

    def copy_in(self, local, remote):
        self._check_auth()
        result = subprocess.run(
            [*self.wrapper, "scp", "-o", "BatchMode=yes", "-q", str(local), f"{self.ssh}:{remote}"],
            capture_output=True, text=True)
        self._check_auth(result)
        result.check_returncode()

    def _upload_msi(self, msi):
        remote = f"{GUEST_DIR}\\{Path(msi).name}"
        self.copy_in(msi, remote)
        self.step += 1
        return remote, f"{GUEST_DIR}\\{self.step:02d}-{Path(msi).stem}.log"

    # --- what a user does ---
    def install(self, msi, properties=""):
        """Silent install; returns the msiexec exit code. The verbose log stays in C:\\virtio-win-acceptance."""
        remote, log = self._upload_msi(msi)
        return int(self.powershell(
            f"(Start-Process msiexec.exe -ArgumentList '/i \"{remote}\" /qn REBOOT=ReallySuppress {properties} "
            f"/l*v \"{log}\"' -Wait -PassThru).ExitCode"))

    def change_features(self, msi, properties):
        """Maintenance run of the installed product, e.g. REMOVE=FE_balloon_driver."""
        return self.install(msi, properties)

    def uninstall(self, msi):
        remote, log = self._upload_msi(msi)
        return int(self.powershell(
            f"(Start-Process msiexec.exe -ArgumentList '/x \"{remote}\" /qn REBOOT=ReallySuppress "
            f"/l*v \"{log}\"' -Wait -PassThru).ExitCode"))

    def install_and_cancel_at(self, msi, action):
        """Install, pressing Cancel when `action` starts; returns the exit code."""
        remote, log = self._upload_msi(msi)
        return int(self.powershell(
            f"Add-Type -Path '{GUEST_DIR}\\Cancel.cs'; "
            f"[MsiCancel]::Run('{remote}', 'REBOOT=ReallySuppress', '{action}', '{log}')"))

    DEVICE_INSTALL_POLICY = r"HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"

    def block_device_installs(self, service):
        """Group policy 'Prevent installation of devices that match these device IDs', for the devices
        currently driven by `service` (e.g. BALLOON). The test machine must have no such policy beforehand."""
        key = self.DEVICE_INSTALL_POLICY
        self.powershell(
            f"if (Test-Path '{key}') {{ throw 'device-install policy already configured; refusing to change it' }}; "
            "$ids = @(Get-PnpDevice -PresentOnly | ? { (Get-PnpDeviceProperty -InstanceId $_.InstanceId "
            f"-KeyName DEVPKEY_Device_Service).Data -eq '{service}' }} | "
            "% { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_HardwareIds).Data } | Select -Unique); "
            "if (-not $ids) { throw 'no matching device' }; "
            f"New-Item '{key}\\DenyDeviceIDs' -Force | Out-Null; "
            f"Set-ItemProperty '{key}' DenyDeviceIDs 1 -Type DWord; "
            "$i = 1; foreach ($id in $ids) { "
            f"Set-ItemProperty '{key}\\DenyDeviceIDs' \"$i\" $id -Type String; $i++ }}")

    def allow_device_installs(self):
        """Removes the policy created by block_device_installs (which refused to run if one existed)."""
        self.powershell(f"Remove-Item '{self.DEVICE_INSTALL_POLICY}' -Recurse -Force -ErrorAction SilentlyContinue")

    # --- what a user sees ---
    def observe(self):
        return json.loads(self.powershell(f"& '{GUEST_DIR}\\observe.ps1'"))


def from_environment():
    domain, ssh = os.environ.get("PR85_VM"), os.environ.get("PR85_SSH")
    if not (domain and ssh):
        return None
    return Machine(domain, ssh, os.environ.get("PR85_LIBVIRT_URI", "qemu:///system"),
                   shlex.split(os.environ.get("PR85_SSH_WRAPPER", "")))
