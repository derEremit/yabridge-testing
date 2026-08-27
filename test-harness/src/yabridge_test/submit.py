"""API submission for test results."""

import json
from pathlib import Path

import httpx

from .schemas import SubmitResponse, TestReport

DEFAULT_API_URL = "https://yabridge-tests.fly.dev"


class SubmitError(Exception):
    """Error during result submission."""

    pass


class ResultSubmitter:
    """Submit test results to the collection API."""

    def __init__(
        self,
        api_url: str = DEFAULT_API_URL,
        api_key: str | None = None,
        timeout: int = 30,
    ) -> None:
        base_url = api_url.rstrip("/")
        # Ensure we have the /api/v1 suffix
        if not base_url.endswith("/api/v1"):
            base_url = f"{base_url}/api/v1"
        self.api_url = base_url
        self.api_key = api_key
        self.timeout = timeout

    def _get_headers(self) -> dict[str, str]:
        """Get request headers."""
        headers = {
            "Content-Type": "application/json",
            "User-Agent": "yabridge-test/0.1.0",
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def submit(self, report: TestReport) -> SubmitResponse:
        """Submit a test report as a draft to the API.

        Creates a draft submission that requires web form completion.

        Args:
            report: The test report to submit

        Returns:
            SubmitResponse with completion URL for finishing submission

        Raises:
            SubmitError: If submission fails
        """
        url = f"{self.api_url}/drafts"

        try:
            with httpx.Client(timeout=self.timeout) as client:
                response = client.post(
                    url,
                    json=report.model_dump(mode="json"),
                    headers=self._get_headers(),
                )

                if response.status_code == 201:
                    data = response.json()
                    return SubmitResponse(
                        success=True,
                        message="Draft created. Please complete your submission.",
                        report_id=data.get("draft_id"),
                        url=data.get("completion_url"),
                        completion_url=data.get("completion_url"),
                        completion_token=data.get("completion_token"),
                    )
                elif response.status_code == 400:
                    return SubmitResponse(
                        success=False,
                        message=f"Invalid request: {response.text}",
                    )
                elif response.status_code == 401:
                    return SubmitResponse(
                        success=False,
                        message="Authentication required",
                    )
                elif response.status_code == 429:
                    return SubmitResponse(
                        success=False,
                        message="Rate limited. Please try again later.",
                    )
                else:
                    return SubmitResponse(
                        success=False,
                        message=f"Server error ({response.status_code}): {response.text}",
                    )

        except httpx.ConnectError as e:
            raise SubmitError(f"Could not connect to API: {e}") from e
        except httpx.TimeoutException as e:
            raise SubmitError(f"Request timed out: {e}") from e
        except httpx.HTTPError as e:
            raise SubmitError(f"HTTP error: {e}") from e

    def submit_from_file(self, file_path: str | Path) -> SubmitResponse:
        """Submit results from a JSON file.

        Args:
            file_path: Path to JSON file containing TestReport

        Returns:
            SubmitResponse with success status

        Raises:
            SubmitError: If file reading or submission fails
        """
        path = Path(file_path)

        if not path.exists():
            raise SubmitError(f"File not found: {path}")

        try:
            with open(path) as f:
                data = json.load(f)
            report = TestReport.model_validate(data)
            return self.submit(report)
        except json.JSONDecodeError as e:
            raise SubmitError(f"Invalid JSON: {e}") from e
        except Exception as e:
            raise SubmitError(f"Failed to parse report: {e}") from e

    def check_connection(self) -> bool:
        """Check if API is reachable.

        Returns:
            True if API responds, False otherwise
        """
        try:
            with httpx.Client(timeout=5) as client:
                response = client.get(f"{self.api_url}/health")
                return response.status_code == 200
        except httpx.HTTPError:
            return False


def save_report(report: TestReport, file_path: str | Path) -> None:
    """Save a test report to a JSON file.

    Args:
        report: The test report to save
        file_path: Output file path
    """
    path = Path(file_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    with open(path, "w") as f:
        json.dump(report.model_dump(mode="json"), f, indent=2, default=str)


def load_report(file_path: str | Path) -> TestReport:
    """Load a test report from a JSON file.

    Args:
        file_path: Path to JSON file

    Returns:
        Parsed TestReport

    Raises:
        FileNotFoundError: If file doesn't exist
        ValueError: If file is not valid
    """
    path = Path(file_path)

    with open(path) as f:
        data = json.load(f)

    return TestReport.model_validate(data)
