import os
from pathlib import Path

import pytest

from machine import from_environment


def _setting(name):
    value = os.environ.get(name)
    if not value:
        pytest.skip(f"{name} not set (see test/acceptance/README.md)")
    return value


@pytest.fixture
def machine():
    vm = from_environment()
    if vm is None:
        pytest.skip("PR85_VM / PR85_SSH not set (see test/acceptance/README.md)")
    yield vm
    vm.shutdown()


@pytest.fixture
def new_msi():
    return Path(_setting("PR85_MSI"))


@pytest.fixture
def next_msi():
    return Path(_setting("PR85_MSI_NEXT"))


@pytest.fixture
def healthy_old_release():
    return _setting("PR85_SNAPSHOT_HEALTHY")


@pytest.fixture
def interrupted_old_release():
    return _setting("PR85_SNAPSHOT_DAMAGED")
