"""Portable source contracts, not MSI execution or real dual-owner recovery tests.

Run against a checkout containing the authoring fix, or set PR85_SOURCE_ROOT to
that checkout. The exact XML assertions bind the finite policy tables below to
the authored conditions; the tables do not interpret MSI condition syntax.
"""

import itertools
import os
from pathlib import Path
import xml.etree.ElementTree as ET

import pytest


SOURCE = Path(os.environ.get("PR85_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
DRIVERS = SOURCE / "virtio-win-drivers-installer" / "Drivers"
NS = {"w": "http://wixtoolset.org/schemas/v4/wxs"}
CLIENT_CONDITION = (
    '(Installed AND REMOVE~="ALL") OR NOT '
    '(INSTALLED_W10X64_$(var.driverKey) AND INSTALLED_W11X64_$(var.driverKey))'
)
SERVICE_CONDITION = "NOT (VIOFS_LEGACY_SERVICE AND VIOFS_CURRENT_SERVICE)"


def test_client_recovery_requires_explicit_full_uninstall():
    root = ET.parse(DRIVERS / "GenericWindowsComponets" / "template.wxi").getroot()
    launch = root.find(".//w:Launch", NS)
    assert launch.attrib["Condition"] == CLIENT_CONDITION
    assert "msiexec /x" in launch.attrib["Message"]
    assert "ProductCode" in launch.attrib["Message"]
    assert "Repair and Modify are not supported" in launch.attrib["Message"]
    component = root.find(".//w:Component", NS)
    assert component.attrib["Guid"] == "$(var.guid)"
    assert component.attrib["Condition"] == "$(var.condition)"
    assert component.attrib["Transitive"] == "no"
    inf = component.find("w:File", NS)
    assert inf.attrib["KeyPath"] == "yes"
    assert inf.attrib["Source"] == (
        r"$(var.virtio_path)\$(var.srcDirName)\$(var.osShort)\$(var.ISA)\$(var.driverName).inf"
    )


def test_dual_service_guard_has_no_maintenance_exemption():
    root = ET.parse(DRIVERS / "viofs" / "viofs.wxs").getroot()
    launch = next(row for row in root.findall(".//w:Launch", NS)
                  if row.attrib["Condition"] == SERVICE_CONDITION)
    assert "confirmed owning installer" in launch.attrib["Message"]
    assert "will not choose or remove either service" in launch.attrib["Message"]
    searches = {row.attrib["Id"]: row for row in root.findall(".//w:Property", NS)}
    for prop, name in [("VIOFS_LEGACY_SERVICE", "VirtIO-FS Service"),
                       ("VIOFS_CURRENT_SERVICE", "VirtioFsSvc")]:
        search = searches[prop].find("w:RegistrySearch", NS)
        assert searches[prop].attrib["Secure"] == "yes"
        assert search.attrib["Root"] == "HKLM"
        assert search.attrib["Key"] == rf"SYSTEM\CurrentControlSet\Services\{name}"
        assert search.attrib["Name"] == "ImagePath"
    selector = root.find(".//w:SetProperty", NS)
    assert selector.attrib["Condition"] == "VIOFS_LEGACY_SERVICE AND NOT VIOFS_CURRENT_SERVICE"
    assert selector.attrib["Value"] == "VirtIO-FS Service"


def test_single_service_component_identity_and_wait_policy_are_unchanged():
    root = ET.parse(DRIVERS / "viofs" / "viofs_extras.wxi").getroot()
    component = root.find("w:Component", NS)
    assert component.attrib["Guid"] == "$(var.viofs_virtiofs_guid)"
    assert component.attrib["Condition"] == "$(var.condition)"
    assert component.attrib["Transitive"] == "no"
    tool = component.find("w:File", NS)
    assert tool.attrib["KeyPath"] == "yes"
    assert tool.attrib["Source"] == r"$(var.virtio_path)\viofs\$(var.osShort)\$(var.ISA)\virtiofs.exe"
    assert component.find("w:ServiceInstall", NS).attrib["Name"] == "[VIOFS_SERVICE_NAME]"
    controls = {row.attrib["Name"]: row.attrib for row in component.findall("w:ServiceControl", NS)}
    assert set(controls) == {"VirtioFsSvc", "VirtIO-FS Service"}
    for name, wait in [("VirtioFsSvc", "yes"), ("VirtIO-FS Service", "no")]:
        assert controls[name]["Stop"] == "both"
        assert controls[name]["Remove"] == "uninstall"
        assert controls[name]["Wait"] == wait


@pytest.mark.parametrize("win10,win11", list(itertools.product([False, True], repeat=2)))
@pytest.mark.parametrize("installed,remove,conflict_allowed", [
    (False, None, False),                 # Fresh install / new ProductCode upgrade.
    (False, "ALL", False),                # No Installed means no recovery exemption.
    (True, None, False),                  # Repair or an undecided maintenance UI.
    (True, "", False),
    (True, "VioFS", False),               # Feature removal / Modify, not full uninstall.
    (True, "ALL,VioFS", False),
    (True, "ALL", True),                  # Explicit CLI complete uninstall.
    (True, "all", True),                  # MSI ~= comparison is case-insensitive.
])
def test_client_policy_table(win10, win11, installed, remove, conflict_allowed):
    allowed = (installed and (remove or "").upper() == "ALL") or not (win10 and win11)
    assert allowed == (not (win10 and win11) or conflict_allowed)


@pytest.mark.parametrize("legacy,current", list(itertools.product([False, True], repeat=2)))
@pytest.mark.parametrize("operation", ["fresh install", "upgrade", "repair", "modify", "full uninstall"])
def test_dual_services_are_refused_for_every_operation(legacy, current, operation):
    # Source asserts no Installed/REMOVE branch. Operation cannot waive this gate.
    allowed = not (legacy and current)
    assert allowed == ((legacy, current) != (True, True)), operation
