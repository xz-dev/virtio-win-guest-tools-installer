"""What the driver installer promises a user, checked on a real Windows VM.

Every scenario starts from a VM snapshot, does what a user or admin would do, and judges only what
Windows shows afterwards: installed products, driver packages, devices and their drivers, services.
"""
SUCCESS = (0, 3010)          # 3010 = success, reboot required
FAILED = 1603
CANCELLED = 1602


def every_device_is_still_there_with_a_working_driver(start, now):
    """Every virtio device present at the start is still present, and each has a working driver."""
    assert start["devices"], "the test machine has no virtio devices"
    missing = set(start["devices"]) - set(now["devices"])
    broken = {i: d for i, d in now["devices"].items() if d["status"] != "OK" or not d["driverVersion"]}
    return not missing and not broken


def every_driver_service_runs_from_an_existing_file(state):
    return all(s["state"] == "Running" and s["imageExists"] for s in state["services"].values())


def product_was_replaced(before, after):
    return after["products"] != before["products"] and len(after["products"]) == 1


def installed_user_tools_remain_available(before, after):
    """An upgrade must not lose user tools or services while the kernel drivers still work."""
    tools = {name for name in before["files"] if name.lower().endswith(".exe")}
    missing_tools = tools - set(after["files"])
    expected_services = set(before["userServices"])
    if "VirtIO-FS Service" in expected_services and "VirtioFsSvc" in after["userServices"]:
        expected_services.remove("VirtIO-FS Service")
        expected_services.add("VirtioFsSvc")
    missing_services = expected_services - set(after["userServices"])
    broken_services = {name for name, service in after["userServices"].items() if not service["imageExists"]}
    return not missing_tools and not missing_services and not broken_services


# --- upgrade ---

def test_upgrade_from_an_older_release_leaves_every_device_working(machine, healthy_old_release, new_msi):
    machine.start_from(healthy_old_release)
    before = machine.observe()

    assert machine.install(new_msi) in SUCCESS
    machine.reboot()

    after = machine.observe()
    assert product_was_replaced(before, after)
    assert every_device_is_still_there_with_a_working_driver(before, after)
    assert every_driver_service_runs_from_an_existing_file(after)
    assert installed_user_tools_remain_available(before, after)


def test_upgrade_repairs_a_machine_whose_earlier_upgrade_was_interrupted(machine, interrupted_old_release, new_msi):
    machine.start_from(interrupted_old_release)    # some devices have no driver here
    before = machine.observe()

    assert machine.install(new_msi) in SUCCESS
    machine.reboot()

    after = machine.observe()
    assert product_was_replaced(before, after)
    assert every_device_is_still_there_with_a_working_driver(before, after)
    assert every_driver_service_runs_from_an_existing_file(after)
    assert installed_user_tools_remain_available(before, after)


def test_a_later_release_upgrades_this_one(machine, healthy_old_release, new_msi, next_msi):
    machine.start_from(healthy_old_release)
    start = machine.observe()
    assert machine.install(new_msi) in SUCCESS
    machine.reboot()
    before = machine.observe()

    assert machine.install(next_msi) in SUCCESS
    machine.reboot()

    after = machine.observe()
    assert product_was_replaced(before, after)
    assert every_device_is_still_there_with_a_working_driver(start, after)
    assert installed_user_tools_remain_available(before, after)


# --- failure and cancel leave the machine as it was ---

def test_a_failed_upgrade_changes_nothing(machine, healthy_old_release, new_msi):
    machine.start_from(healthy_old_release)
    before = machine.observe()

    machine.block_device_installs("BALLOON")    # admin policy blocks installing drivers for the balloon device
    try:
        assert machine.install(new_msi) == FAILED
    finally:
        machine.allow_device_installs()
    machine.reboot()

    assert machine.observe() == before


def test_cancelling_at_the_last_step_changes_nothing_and_a_retry_works(machine, interrupted_old_release, new_msi):
    machine.start_from(interrupted_old_release)
    before = machine.observe()

    assert machine.install_and_cancel_at(new_msi, "InstallFinalize") == CANCELLED
    machine.reboot()
    assert machine.observe() == before

    assert machine.install(new_msi) in SUCCESS
    machine.reboot()
    assert every_device_is_still_there_with_a_working_driver(before, machine.observe())


# --- maintenance and removal ---

def test_removing_and_adding_back_a_driver_feature_keeps_its_device_working(machine, healthy_old_release, new_msi):
    machine.start_from(healthy_old_release)
    start = machine.observe()
    assert machine.install(new_msi) in SUCCESS
    machine.reboot()

    assert machine.change_features(new_msi, "REMOVE=FE_balloon_driver") in SUCCESS
    machine.reboot()
    # The balloon device falls back to the older driver that is still in the driver store.
    assert every_device_is_still_there_with_a_working_driver(start, machine.observe())

    assert machine.change_features(new_msi, "ADDLOCAL=FE_balloon_driver") in SUCCESS
    machine.reboot()
    after = machine.observe()
    assert every_device_is_still_there_with_a_working_driver(start, after)
    assert every_driver_service_runs_from_an_existing_file(after)


def test_uninstall_leaves_no_device_without_a_driver(machine, healthy_old_release, new_msi):
    machine.start_from(healthy_old_release)
    start = machine.observe()
    assert machine.install(new_msi) in SUCCESS
    machine.reboot()

    assert machine.uninstall(new_msi) in SUCCESS
    machine.reboot()

    after = machine.observe()
    assert after["products"] == []
    assert after["userServices"] == {}
    assert every_device_is_still_there_with_a_working_driver(start, after)
