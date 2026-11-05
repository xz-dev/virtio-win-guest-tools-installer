"""Host policy checks only. Windows MSI/API integration remains a separate gate."""
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("source", ["driver_ownership_test.cpp", "driver_transaction_test.cpp", "driver_alias_prefix_test.cpp", "driver_section_test.cpp"])
def test_portable_driver_contracts(tmp_path, source):
    executable = tmp_path / "driver-ownership-test"
    subprocess.run([
        os.environ.get("CXX", "c++"), "-std=c++14", "-Wall", "-Wextra", "-Werror",
        str(ROOT / "test" / source), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)


def test_failure_fixture_preserves_shipping_execute_condition():
    # Source guard only; generated table equality is checked separately against real MSIs.
    tree = ET.parse(ROOT / "test/fixtures/pr85-driver-failure.wxi")
    execute = tree.find(".//{http://schemas.microsoft.com/wix/2006/wi}InstallExecute")
    assert execute.text.strip() == "NOT Installed"


def test_optional_probe_support_file_shares_driver_component():
    path = ROOT / "test/fixtures/pr85-native-driver-transaction.wxs"
    tree = ET.parse(path)
    ns = {"w": "http://schemas.microsoft.com/wix/2006/wi"}
    component = tree.find(".//w:Component[@Id='PR85FixtureDriver']", ns)
    files = {node.attrib["Id"]: node for node in component.findall("w:File", ns)}
    assert "PR85FixtureInf" in files
    assert files["PR85FixtureSupport"].attrib["Source"] == (
        "$(var.DriverFixtureSource)\\$(var.DriverFixtureSupportFile)"
    )
    assert len(tree.findall(".//w:Component", ns)) == 1
    # Explicit conditional source authoring; generated MSI/cabinet completeness is a separate build gate.
    assert '<?ifdef var.DriverFixtureSupportFile ?>' in path.read_text()
