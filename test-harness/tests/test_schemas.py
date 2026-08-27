from datetime import timezone

from yabridge_test.schemas import (
    CompatibilityMatrix,
    DisplayServer,
    Environment,
)
from yabridge_test.schemas import (
    TestReport as HarnessTestReport,
)


def _minimal_environment() -> Environment:
    return Environment(
        distro="test",
        kernel="test",
        desktop="test",
        display_server=DisplayServer.X11,
        wine_version="test",
        yabridge_version="test",
    )


def test_test_report_timestamp_is_timezone_aware_utc() -> None:
    report = HarnessTestReport(environment=_minimal_environment())
    assert report.timestamp.tzinfo is not None
    assert report.timestamp.tzinfo == timezone.utc


def test_compatibility_matrix_generated_at_is_timezone_aware_utc() -> None:
    matrix = CompatibilityMatrix(rows=[], columns=[], data={})
    assert matrix.generated_at.tzinfo is not None
    assert matrix.generated_at.tzinfo == timezone.utc
