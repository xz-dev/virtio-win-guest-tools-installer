"""User-visible outcomes; no assertions about C++ branches or internal package IDs."""
import pytest


@pytest.mark.parametrize("full", [False, True], ids=["retain-agent-only", "retain-full"])
def test_upgrade_and_repair_retain_the_actually_installed_variant(guest, full):
    guest.install(guest.old, int(full))
    guest.agent(full, guest.settings["old_version"])

    # With ordinary prerequisites available, the opposite request must still be refused.
    guest.blocked(guest.new, (f"QgaVssEnabled={int(not full)}",))
    guest.agent(full, guest.settings["old_version"])

    sens = guest.start_type("SENS")
    try:
        if not full:
            guest.set_start_type("SENS", 4)
        guest.install(guest.new)  # No variant argument: discover the old installed flavor.
        guest.agent(full, guest.settings["new_version"])
        guest.blocked(guest.new, ("/repair", f"QgaVssEnabled={int(not full)}"))
        code, _ = guest.run(guest.new, ("/repair",))
        assert code in (0, 3010)
        guest.agent(full, guest.settings["new_version"])
        assert guest.start_type("SENS") == (sens if full else 4)
    finally:
        if not guest.auth_failed and not guest.pending:
            guest.set_start_type("SENS", sens)


def test_only_explicit_modify_switches_both_directions(guest):
    guest.install(guest.new, 0)
    guest.agent(False, guest.settings["new_version"])
    for full in (True, False):
        code, _ = guest.run(guest.new, ("/modify", f"QgaVssEnabled={int(full)}"))
        assert code in (0, 3010)
        guest.agent(full, guest.settings["new_version"])
    guest.blocked(guest.new, ("/repair", "QgaVssEnabled=1"))
    guest.agent(False, guest.settings["new_version"])


@pytest.mark.parametrize("service", ["SENS", "COMSysApp"])
def test_disabled_dependencies_refuse_full_but_do_not_block_agent_only(guest, service):
    previous = guest.start_type(service)
    assert previous in (2, 3), "Start with the normal enabled service policy"
    try:
        # Configuration only: stopping a COM+ service under a running Agent is a separate
        # known failure scenario, not a prerequisite for testing the installer's policy gate.
        guest.set_start_type(service, 4)
        guest.blocked(guest.new, ("QgaVssEnabled=1",))
        guest.install(guest.new, 0)
        guest.agent(False, guest.settings["new_version"])
        guest.blocked(guest.new, ("/modify", "QgaVssEnabled=1"))
        code, _ = guest.run(guest.new, ("/repair",))
        assert code in (0, 3010)
        guest.agent(False, guest.settings["new_version"])
        assert guest.start_type(service) == 4
        code, _ = guest.run(guest.new, ("/uninstall",))
        assert code in (0, 3010)
        guest.current = None
        assert not guest.state()["products"]

        guest.set_start_type(service, previous)
        guest.install(guest.new, 1)
        guest.agent(True, guest.settings["new_version"])
        guest.set_start_type(service, 4)
        for arguments in (("/repair",), ("/modify", "QgaVssEnabled=0"), ("/uninstall",)):
            guest.blocked(guest.new, arguments)
            assert guest.start_type(service) == 4
            assert len(guest.state()["products"]) == 1
    finally:
        if not guest.auth_failed and not guest.pending:
            guest.set_start_type(service, previous)
