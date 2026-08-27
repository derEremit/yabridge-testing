from types import SimpleNamespace

import pytest
from conftest import pytest_collection_finish


def test_zero_collection_is_an_explicit_failure() -> None:
    with pytest.raises(pytest.UsageError, match="no harness tests collected"):
        pytest_collection_finish(SimpleNamespace(items=[]))
