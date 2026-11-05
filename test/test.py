import os
import subprocess
import pytest
import msi_values

MSIx64_PATH = "../tmp/virtio-win-drivers-installer/virtio-win-gt-x64.msi"
MSIx86_PATH = "../tmp/virtio-win-drivers-installer/virtio-win-gt-x86.msi"


def run_command(command):
    try:
        return subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True
        ).stdout.decode()
    except subprocess.CalledProcessError as e:
        raise Exception(
            "command: '{}' failed with '{}'".format(" ".join(e.cmd), e.stdout)
        )


class Table:
    def __init__(self, name, table_raw_content):
        self.name = name
        self.colum_names_to_index = self._map_colum_names_to_index(table_raw_content)
        self._parse_raw_content(table_raw_content[1:])

    def _map_colum_names_to_index(self, content):
        return dict(zip(range(len(content[0])), content[0]))

    def _parse_raw_content(self, content):
        self.rows = {}
        for row in content:
            self.rows[row[0]] = row[1:]

    def get_row(self, row_pk):
        return self.rows[row_pk]


class MSI(object):
    def __init__(self, msi_file, arch, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.msi_file = msi_file
        self.arch = arch

        if not os.path.exists(self.msi_file):
            pytest.fail("msi was not generated: %s" % os.path.abspath(self.msi_file))

        self.init_tables()

    def init_tables(self):
        def _get_table_list():
            return filter(
                lambda table: not table.startswith("_"),
                run_command(["msiinfo", "tables", self.msi_file]).splitlines(),
            )

        def _get_table_content(table_name):
            table_content = run_command(
                ["msiinfo", "export", self.msi_file, table_name]
            ).splitlines()
            return [row.split("\t") for row in [table_content[0]] + table_content[3:]]

        self.tables = {}
        msi_table_list = _get_table_list()
        for table_name in msi_table_list:
            table_content = _get_table_content(table_name)
            self.tables[table_name] = Table(table_name, table_content)

    def get_table(self, table_name):
        return self.tables.get(table_name)

    def get_arch(self):
        return self.arch


@pytest.fixture(scope="session")
def get_msis():
    return [MSI(MSIx64_PATH, "x64"), MSI(MSIx86_PATH, "x86")]


def _generic_msi_value_test(msis, table, expected):
    for msi in msis:
        msi_table = msi.get_table(table)
        expected_values = expected[msi.get_arch()]
        for comp_id in expected_values.keys():
            for val in expected_values[comp_id]:
                assert val in msi_table.get_row(comp_id)


def test_component_ids(get_msis):
    """
    Component IDs must remain stable only while resolved resources and ownership
    remain compatible. Late major upgrades rely on those component rules; changing
    a GUID or this expectation alone does not establish a safe migration.
    """
    _, expected_values = msi_values.get_expected_componentids()
    _generic_msi_value_test(get_msis, "Component", expected_values)


def test_upgrade_code(get_msis):
    """
    Upgradecode is used by msi to detect previus product versions
    in general it shouldn't change, if it does change please make
    sure that the previus product get uninstalled first to prevent
    problems and update the expected value
    """
    _, expected_values = msi_values.get_expected_upgrade_code()
    _generic_msi_value_test(get_msis, "Property", expected_values)


def test_allusers(get_msis):
    _, expected_values = msi_values.get_expected_allusers_property()
    _generic_msi_value_test(get_msis, "Property", expected_values)


def test_old_wgt_uninstall_path(get_msis):
    _, expected_values = msi_values.get_expected_RegLocator()
    _generic_msi_value_test(get_msis, "RegLocator", expected_values)


def test_upgrade_ownership_handoff_is_transactional(get_msis):
    for msi in get_msis:
        sequence = msi.get_table("InstallExecuteSequence")
        assert "InstallExecute" in sequence.rows, msi.get_arch()
        initialize, execute, remove, finalize = (
            int(sequence.get_row(action)[1])
            for action in (
                "InstallInitialize", "InstallExecute",
                "RemoveExistingProducts", "InstallFinalize",
            )
        )
        assert initialize < execute < remove < finalize, msi.get_arch()
        assert initialize < int(sequence.get_row("ProcessDriverPackages")[1]) < execute
        assert sequence.get_row("InstallExecute")[0].strip() == "NOT Installed"
        validate = int(sequence.get_row("InstallValidate")[1])
        admission = sequence.get_row("CheckLegacyDriverOwnership")
        assert validate < int(admission[1]) < initialize
        assert admission[0].split() == ["VersionNT", ">=", "603"]
        admission_type = int(msi.get_table("CustomAction").get_row("CheckLegacyDriverOwnership")[0])
        assert admission_type & 0x3F == 1  # Native immediate checked action.
        assert admission_type & (0xC0 | 0x400) == 0
        uninstall = int(sequence.get_row("ProcessDriverUninstallPackages")[1])
        assert initialize < uninstall < int(sequence.get_row("RemoveFiles")[1])
        assert int(sequence.get_row("RemoveFiles")[1]) < int(sequence.get_row("InstallFiles")[1])
        cleanup = sequence.get_row("CleanupDriverTransactions")
        assert finalize < int(cleanup[1])
        cleanup_type = int(msi.get_table("CustomAction").get_row("CleanupDriverTransactions")[0])
        assert cleanup_type & 0x3F == 1 and cleanup_type & 0x700 == 0


@pytest.mark.parametrize("action", ["InstallDriverPackages", "UninstallDriverPackages"])
def test_driver_forward_actions_check_errors(get_msis, action):
    for msi in get_msis:
        action_type = int(msi.get_table("CustomAction").get_row(action)[0])
        assert action_type & 0x3F == 1, (msi.get_arch(), action)  # Native DLL.
        assert action_type & 0x400, (msi.get_arch(), action)  # Deferred script.
        # Continue (0x40) and async (0x80) would bypass synchronous error checking.
        assert action_type & 0xC0 == 0, (msi.get_arch(), action)


def test_inverse_actions_require_rollback_enabled(get_msis):
    for msi in get_msis:
        actions = msi.get_table("CustomAction")
        sequence = msi.get_table("InstallExecuteSequence")
        # Schedulers queue these at runtime, not through sequence rows.
        for inverse in ("RollbackInstall", "RollbackUninstall"):
            row = actions.get_row(inverse)
            assert int(row[0]) & 0x500 == 0x500
            assert row[2] == "RollbackDriverPackages"
        begin = actions.get_row("BeginDriverTransaction")
        assert begin[2] == "BeginDriverPackages"
        assert int(begin[0]) & 0x400 and int(begin[0]) & 0xC0 == 0
        conditions = msi.get_table("LaunchCondition")
        assert conditions is not None, msi.get_arch()
        # Require a standalone standard-property gate, not an OR branch that
        # allows maintenance/uninstall to bypass inverses. Runtime tests exercise it.
        assert any(
            condition.replace("(", " ").replace(")", " ").split()
            == ["NOT", "RollbackDisabled"]
            for condition in conditions.rows
        ), msi.get_arch()
        launch = sequence.get_row("LaunchConditions")
        assert not launch[0].strip(), msi.get_arch()
        assert int(launch[1]) < int(sequence.get_row("InstallInitialize")[1])


@pytest.mark.parametrize("arch", ["x64", "x86"])
@pytest.mark.parametrize("boundary", ["BEFORE", "AFTER"])
def test_generated_fault_fixture_preserves_execute_condition(get_msis, arch, boundary):
    path = os.environ.get("PR85_FAULT_{}_{}".format(boundary, arch.upper()))
    if not path:
        pytest.skip("new-source fault MSI path not supplied")
    fixture = MSI(path, arch)
    shipping = next(msi for msi in get_msis if msi.get_arch() == arch)
    assert fixture.get_table("InstallExecuteSequence").get_row("InstallExecute")[0] == (
        shipping.get_table("InstallExecuteSequence").get_row("InstallExecute")[0]
    ) == "NOT Installed"


def test_shipping_package_has_no_test_failure_hook(get_msis):
    for msi in get_msis:
        assert not any(action.startswith("PR85_") for action in msi.get_table("CustomAction").rows), msi.get_arch()
