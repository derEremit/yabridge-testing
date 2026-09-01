"""CLI interface for yabridge test harness."""

import json
import sys
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn

import click
from rich.console import Console
from rich.panel import Panel
from rich.table import Table

from . import __version__
from .environment import collect_environment
from .probe.runner import ProbeOptions, WineChildWindowTest
from .probe.scenarios import SCENARIO_NAMES
from .sanitize import payload_for_submit
from .schemas import ResultSummary, SingleTestResult, SubmitResponse, TestReport, TestResult
from .session_report import build_session_report
from .submit import DEFAULT_API_URL, ResultSubmitter, SubmitError, load_report, save_report
from .tests import PluginLoadTest, PointerBackendSanity

console = Console()


def exit_for_results(
    results: Sequence[SingleTestResult], *, submission_failed: bool = False
) -> NoReturn | None:
    """Exit with code 1 when results or submission indicate an unsuccessful run."""
    summary = ResultSummary.from_results(results)
    if summary.unsuccessful or submission_failed:
        sys.exit(1)
    return None


@click.group()
@click.version_option(version=__version__)
def main() -> None:
    """Yabridge Test Harness - Wine 10 testing infrastructure CLI."""
    pass


def _display_results(results: Sequence[SingleTestResult]) -> None:
    for result in results:
        if result.result == TestResult.PASS:
            icon = "[green]✓[/green]"
        elif result.result == TestResult.FAIL:
            icon = "[red]✗[/red]"
        elif result.result == TestResult.SKIP:
            icon = "[yellow]○[/yellow]"
        else:
            icon = "[red]![/red]"
        console.print(f"{icon} {result.name}: {result.details or result.result.value}")


def _print_draft_response(response: SubmitResponse) -> bool:
    """Print a draft-submit result. Returns True when the POST succeeded."""
    if not response.success:
        console.print(f"[red]✗ {response.message or 'Submission failed'}[/red]")
        return False
    console.print(f"[green]✓ {response.message}[/green]")
    if response.report_id:
        console.print(f"  Draft ID: {response.report_id}")
    completion_url = response.completion_url or response.url
    if completion_url:
        console.print()
        console.print("[bold cyan]Edit your report at:[/bold cyan]")
        # Plain print: rich wraps long lines to the terminal width, and a
        # secret URL broken across lines gets copied truncated — an invalid
        # token that reads as "link no longer usable".
        print(f"  {completion_url}")
        console.print()
        console.print(
            "[dim]The report stays private until you publish it on that page.[/dim]"
        )
    return True


def _maybe_submit(
    report: TestReport,
    *,
    server: str,
    submit: bool,
    dry_run: bool = False,
) -> bool:
    """POST a draft or print a sanitized payload. True when submission failed."""
    if dry_run:
        console.print(json.dumps(payload_for_submit(report), indent=2, default=str))
        return False
    if not submit:
        return False
    console.print(f"\nSubmitting draft to {server}...")
    submitter = ResultSubmitter(api_url=server)
    try:
        response = submitter.submit(report)
    except SubmitError as exc:
        console.print(f"[red]✗ Submission error: {exc}[/red]")
        return True
    return not _print_draft_response(response)


@main.command()
@click.option("--scenario", type=click.Choice(SCENARIO_NAMES))
@click.option("--headless/--no-headless", default=True, show_default=True)
@click.option(
    "--allow-pointer-warp",
    is_flag=True,
    help="Explicitly permit pointer movement on an existing DISPLAY",
)
@click.option(
    "--yabridge-lib",
    type=click.Path(path_type=Path),
    envvar="YABRIDGE_PROBE_LIB",
)
@click.option("--wine-prefix", type=click.Path(path_type=Path))
@click.option("--samples", type=click.IntRange(min=1), default=1, show_default=True)
@click.option("--tolerance", type=click.IntRange(min=0), default=2, show_default=True)
@click.option("--json", "as_json", is_flag=True, help="Output machine-readable JSON")
@click.option("--submit/--no-submit", default=False, help="Submit a sanitized draft")
@click.option("--dry-run", is_flag=True, help="Print the sanitized draft JSON and do not POST")
@click.option("--server", default=DEFAULT_API_URL, help="API server URL")
def probe(
    scenario: str | None,
    headless: bool,
    allow_pointer_warp: bool,
    yabridge_lib: Path | None,
    wine_prefix: Path | None,
    samples: int,
    tolerance: int,
    as_json: bool,
    submit: bool,
    dry_run: bool,
    server: str,
) -> None:
    """Run measured bridged Wine child-window coordinate scenarios."""
    options = ProbeOptions(
        scenario=scenario,
        headless=headless,
        yabridge_lib=yabridge_lib,
        wine_prefix=wine_prefix,
        samples=samples,
        tolerance=tolerance,
        allow_pointer_warp=allow_pointer_warp,
    )
    if not as_json:
        click.echo("Running bridged coordinate probe...", err=True)
    results = WineChildWindowTest(options).run_all()
    summary = ResultSummary.from_results(results)
    if as_json:
        click.echo(
            json.dumps(
                {
                    "tests": [result.model_dump(mode="json") for result in results],
                    "summary": summary.model_dump(mode="json"),
                },
                indent=2,
            )
        )
    else:
        _display_results(results)
        console.print(
            f"Passed: {summary.passed}  Failed: {summary.failed}  "
            f"Errors: {summary.errors}  Skipped: {summary.skipped}"
        )
    submission_failed = False
    if submit or dry_run:
        report = TestReport(
            timestamp=datetime.now(timezone.utc),
            environment=collect_environment(),
            tests=results,
            session_type="probe",
        )
        submission_failed = _maybe_submit(
            report, server=server, submit=submit, dry_run=dry_run
        )
    exit_for_results(results, submission_failed=submission_failed)


@main.command()
@click.option("--json", "as_json", is_flag=True, help="Output as JSON")
@click.option("--output", "-o", type=click.Path(), help="Save to file")
def info(as_json: bool, output: str | None) -> None:
    """Capture and display system environment information."""
    console.print("[bold]Collecting environment information...[/bold]")

    try:
        env = collect_environment()
    except Exception as e:
        console.print(f"[red]Error collecting environment: {e}[/red]")
        sys.exit(1)

    if as_json or output:
        env_dict = env.model_dump(mode="json")
        json_str = json.dumps(env_dict, indent=2, default=str)

        if output:
            Path(output).write_text(json_str)
            console.print(f"[green]Saved to {output}[/green]")

        if as_json:
            console.print(json_str)
    else:
        # Pretty print
        table = Table(title="System Environment", show_header=False, box=None)
        table.add_column("Key", style="cyan")
        table.add_column("Value", style="white")

        table.add_row("Distribution", env.distro)
        table.add_row("Kernel", env.kernel)
        table.add_row("Desktop", f"{env.desktop} {env.desktop_version or ''}")
        table.add_row("Display Server", env.display_server.value)
        if env.compositor:
            table.add_row("Compositor", env.compositor)
        table.add_row("Wine Version", env.wine_version)
        table.add_row("Wine Staging", "Yes" if env.wine_staging else "No")
        if env.wine_patches:
            table.add_row("Wine Patches", ", ".join(env.wine_patches))
        table.add_row("Yabridge Version", env.yabridge_version)
        if env.yabridge_commit:
            table.add_row("Yabridge Commit", env.yabridge_commit[:12])
        if env.yabridge_branch:
            table.add_row("Yabridge Branch", env.yabridge_branch)
        table.add_row("DPI Scale", str(env.dpi_scale))
        if env.monitors:
            monitors_str = ", ".join(
                f"{m.width}x{m.height}{'*' if m.primary else ''}" for m in env.monitors
            )
            table.add_row("Monitors", monitors_str)
        if env.cpu:
            table.add_row("CPU", env.cpu[:50] + "..." if len(env.cpu) > 50 else env.cpu)
        if env.gpu:
            table.add_row("GPU", env.gpu[:50] + "..." if len(env.gpu) > 50 else env.gpu)
        if env.ram_gb:
            table.add_row("RAM", f"{env.ram_gb} GB")

        console.print(table)


@main.command()
@click.option("--output", "-o", type=click.Path(), help="Save results to file")
def validate(output: str | None) -> None:
    """Run mouse coordinate validation tests."""
    console.print("[bold]Running mouse coordinate tests...[/bold]\n")

    results = PointerBackendSanity().run_all()
    results.extend(WineChildWindowTest().run_all())

    # Display results
    _display_results(results)

    # Create report if output requested
    if output:
        env = collect_environment()
        report = TestReport(
            timestamp=datetime.now(timezone.utc),
            environment=env,
            tests=results,
            session_type="probe",
        )
        save_report(report, output)
        console.print(f"\n[green]Results saved to {output}[/green]")

    exit_for_results(results)


@main.command()
@click.argument("plugin_path", type=click.Path(exists=True))
@click.option("--output", "-o", type=click.Path(), help="Save results to file")
def plugin(plugin_path: str, output: str | None) -> None:
    """Test a specific plugin."""
    console.print(f"[bold]Testing plugin: {plugin_path}[/bold]\n")

    test = PluginLoadTest(plugin_path)
    plugin_info = test.get_plugin_info()

    if plugin_info:
        console.print(
            Panel(
                f"Name: {plugin_info.name}\n"
                f"Type: {plugin_info.type.value}\n"
                f"Path: {plugin_info.path}",
                title="Plugin Info",
            )
        )

    results = test.run_all()

    # Display results
    console.print("\n[bold]Test Results:[/bold]")
    for result in results:
        if result.result == TestResult.PASS:
            icon = "[green]✓[/green]"
        elif result.result == TestResult.FAIL:
            icon = "[red]✗[/red]"
        elif result.result == TestResult.SKIP:
            icon = "[yellow]○[/yellow]"
        else:
            icon = "[red]![/red]"

        console.print(f"{icon} {result.name}: {result.details or result.result.value}")

    # Create report if output requested
    if output:
        env = collect_environment(plugin_path)
        report = TestReport(
            timestamp=datetime.now(timezone.utc),
            environment=env,
            plugin=plugin_info,
            tests=results,
            session_type="plugin",
        )
        save_report(report, output)
        console.print(f"\n[green]Results saved to {output}[/green]")

    exit_for_results(results)


@main.command()
@click.option("--host", "-h", default=None, help="DAW host name (e.g., ardour, carla)")
@click.option("--plugin", "-p", type=click.Path(exists=True), help="Plugin to test")
@click.option("--output", "-o", type=click.Path(), help="Save results to file")
@click.option("--submit/--no-submit", default=False, help="Submit a sanitized draft")
@click.option("--dry-run", is_flag=True, help="Print the sanitized draft JSON and do not POST")
@click.option("--server", default=DEFAULT_API_URL, help="API server URL")
def suite(
    host: str | None,
    plugin: str | None,
    output: str | None,
    submit: bool,
    dry_run: bool,
    server: str,
) -> None:
    """Run full test suite."""
    console.print("[bold]Running yabridge test suite...[/bold]\n")

    # Collect environment
    console.print("Collecting environment...")
    env = collect_environment(plugin) if plugin else collect_environment()

    all_results = []

    # Run pointer prerequisite and measured bridged coordinate scenarios.
    console.print("\nRunning pointer and bridged coordinate tests...")
    all_results.extend(PointerBackendSanity().run_all())
    all_results.extend(WineChildWindowTest().run_all())

    # Run plugin tests if specified
    plugin_info = None
    if plugin:
        console.print(f"\nTesting plugin: {plugin}")
        plugin_test = PluginLoadTest(plugin)
        plugin_info = plugin_test.get_plugin_info()
        all_results.extend(plugin_test.run_all())

    # Create report
    report = TestReport(
        timestamp=datetime.now(timezone.utc),
        environment=env,
        host=host,
        plugin=plugin_info,
        tests=all_results,
        session_type="suite",
    )

    # Display summary
    console.print("\n[bold]Test Summary:[/bold]")
    summary = ResultSummary.from_results(all_results)

    console.print(f"  [green]Passed: {summary.passed}[/green]")
    console.print(f"  [red]Failed: {summary.failed}[/red]")
    console.print(f"  [red]Errors: {summary.errors}[/red]")
    console.print(f"  [yellow]Skipped: {summary.skipped}[/yellow]")
    console.print(f"  Native session: {env.display_server.value}")
    console.print(f"  XWayland available: {'Yes' if env.xwayland_available else 'No'}")

    # Save to file
    if output:
        save_report(report, output)
        console.print(f"\n[green]Results saved to {output}[/green]")

    submission_failed = _maybe_submit(
        report, server=server, submit=submit, dry_run=dry_run
    )

    exit_for_results(all_results, submission_failed=submission_failed)


@main.command()
@click.option("--file", "-f", type=click.Path(exists=True), help="Results file to submit")
@click.option(
    "--session",
    is_flag=True,
    help="Submit isolated-DAW session notes (environment + run-manifest scalars)",
)
@click.option("--notes", help="Notes to include on the draft")
@click.option(
    "--notes-file",
    type=click.Path(exists=True),
    help="Read notes from a file (ignored when --notes is set)",
)
@click.option("--dry-run", is_flag=True, help="Print the sanitized draft JSON and do not POST")
@click.option("--server", default=DEFAULT_API_URL, help="API server URL")
@click.option("--api-key", envvar="YABRIDGE_API_KEY", help="API key for authentication")
def submit(
    file: str | None,
    session: bool,
    notes: str | None,
    notes_file: str | None,
    dry_run: bool,
    server: str,
    api_key: str | None,
) -> None:
    """Submit a sanitized draft. Prints an edit URL. Never publishes."""
    if session and file:
        raise click.UsageError("Use --session or --file, not both")

    session_notes = notes
    if session_notes is None and notes_file:
        session_notes = Path(notes_file).read_text(encoding="utf-8")

    if session:
        report = build_session_report(notes=session_notes)
    elif file:
        report = load_report(file)
        if session_notes:
            report = report.model_copy(update={"notes": session_notes})
    else:
        console.print("Running tests...")
        env = collect_environment()
        results = PointerBackendSanity().run_all()
        results.extend(WineChildWindowTest().run_all())
        report = TestReport(
            timestamp=datetime.now(timezone.utc),
            environment=env,
            tests=results,
            notes=session_notes,
            session_type="probe",
        )

    if dry_run:
        click.echo(json.dumps(payload_for_submit(report), indent=2, default=str))
        return

    submitter = ResultSubmitter(api_url=server, api_key=api_key)
    console.print(f"Connecting to {server}...")
    if not submitter.check_connection():
        console.print("[yellow]Warning: Could not verify API connection[/yellow]")

    console.print("Submitting sanitized draft...")
    try:
        response = submitter.submit(report)
    except SubmitError as exc:
        console.print(f"[red]Error: {exc}[/red]")
        sys.exit(1)

    if not _print_draft_response(response):
        sys.exit(1)


if __name__ == "__main__":
    main()
