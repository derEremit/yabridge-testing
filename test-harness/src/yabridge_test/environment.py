"""System environment detection for yabridge testing."""

import os
import re
import subprocess
from collections.abc import Mapping
from pathlib import Path
from typing import overload

import psutil

from .provenance import StagingIdentity, resolve_test_root
from .schemas import DisplayServer, Environment, MonitorInfo


@overload
def run_command(cmd: list[str], default: str = "") -> str: ...


@overload
def run_command(cmd: list[str], default: None) -> str | None: ...


def run_command(cmd: list[str], default: str | None = "") -> str | None:
    """Run a command and return stdout, or default on failure."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.stdout.strip() if result.returncode == 0 else default
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return default


def detect_distro() -> tuple[str, str]:
    """Detect Linux distribution name and kernel version."""
    # Try /etc/os-release first
    distro = "Unknown Linux"
    try:
        with open("/etc/os-release") as f:
            os_release = {}
            for line in f:
                if "=" in line:
                    key, _, value = line.partition("=")
                    os_release[key.strip()] = value.strip().strip('"')

            if "PRETTY_NAME" in os_release:
                distro = os_release["PRETTY_NAME"]
            elif "NAME" in os_release:
                distro = os_release["NAME"]
                if "VERSION" in os_release:
                    distro += f" {os_release['VERSION']}"
    except FileNotFoundError:
        # Fallback to lsb_release
        distro = run_command(["lsb_release", "-ds"], "Unknown Linux")

    kernel = run_command(["uname", "-r"], "unknown")
    return distro, kernel


def detect_desktop_environment() -> tuple[str, str | None, str | None]:
    """Detect desktop environment, version, and compositor."""
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "")

    # Normalize desktop name
    desktop_lower = desktop.lower()
    compositor = None
    version = None

    if "gnome" in desktop_lower:
        desktop = "GNOME"
        version = run_command(["gnome-shell", "--version"], None)
        if version:
            match = re.search(r"(\d+\.\d+)", version)
            version = match.group(1) if match else version
        compositor = "Mutter"

    elif "kde" in desktop_lower or "plasma" in desktop_lower:
        desktop = "KDE Plasma"
        version = run_command(["plasmashell", "--version"], None)
        if version:
            match = re.search(r"(\d+\.\d+)", version)
            version = match.group(1) if match else version
        compositor = "KWin"

    elif "sway" in desktop_lower:
        desktop = "Sway"
        version = run_command(["sway", "--version"], None)
        if version:
            match = re.search(r"(\d+\.\d+)", version)
            version = match.group(1) if match else version
        compositor = "Sway"

    elif "i3" in desktop_lower:
        desktop = "i3"
        version = run_command(["i3", "--version"], None)
        if version:
            match = re.search(r"(\d+\.\d+)", version)
            version = match.group(1) if match else version

    elif "xfce" in desktop_lower:
        desktop = "XFCE"
        version = run_command(["xfce4-session", "--version"], None)
        if version:
            match = re.search(r"(\d+\.\d+)", version)
            version = match.group(1) if match else version

    elif "cinnamon" in desktop_lower:
        desktop = "Cinnamon"
        version = run_command(["cinnamon", "--version"], None)
        if version:
            match = re.search(r"(\d+\.\d+)", version)
            version = match.group(1) if match else version

    elif not desktop:
        desktop = "Unknown"

    return desktop, version, compositor


def detect_display_environment(
    environ: Mapping[str, str],
) -> tuple[DisplayServer, bool]:
    """Detect native session type and XWayland availability separately."""
    session_type = environ.get("XDG_SESSION_TYPE", "").lower()
    wayland_display = environ.get("WAYLAND_DISPLAY", "")
    display = environ.get("DISPLAY", "")

    if session_type == "wayland" or wayland_display:
        return DisplayServer.WAYLAND, bool(display)

    if session_type == "x11" or display:
        return DisplayServer.X11, False

    return DisplayServer.X11, False


def detect_display_server() -> DisplayServer:
    """Detect native display session type."""
    display_server, _ = detect_display_environment(os.environ)
    return display_server


def find_wine_prefix_from_plugin(plugin_path: str | Path | None) -> str | None:
    """Find Wine prefix by searching upward from plugin path for dosdevices.

    This mimics yabridge's own prefix detection logic:
    1. Search upward from the plugin's Windows path for a 'dosdevices' directory
    2. The parent of 'dosdevices' is the Wine prefix
    3. Falls back to WINEPREFIX env var, then ~/.wine

    Args:
        plugin_path: Path to the Windows plugin (.dll/.vst3/.clap) or None

    Returns:
        The detected Wine prefix path, or None if not found
    """
    if plugin_path is None:
        return None

    path = Path(plugin_path).resolve()

    # Search upward for dosdevices directory (yabridge's detection method)
    current = path.parent
    while current != current.parent:  # Stop at filesystem root
        dosdevices = current / "dosdevices"
        if dosdevices.is_dir():
            # Parent of dosdevices is the Wine prefix
            return str(current)
        current = current.parent

    return None


def detect_wine_prefix(plugin_path: str | Path | None = None) -> str:
    """Detect Wine prefix, optionally using plugin path for auto-detection.

    Priority:
    1. Auto-detect from plugin path (if provided) using yabridge's method
    2. WINEPREFIX environment variable
    3. Default ~/.wine

    Args:
        plugin_path: Optional path to the Windows plugin being tested

    Returns:
        The Wine prefix path
    """
    # Try to detect from plugin path first (yabridge's method)
    if plugin_path:
        detected = find_wine_prefix_from_plugin(plugin_path)
        if detected:
            return detected

    # Fall back to WINEPREFIX env var or default
    return os.environ.get("WINEPREFIX", str(Path.home() / ".wine"))


def detect_wine_version(
    plugin_path: str | Path | None = None,
) -> tuple[str, bool, list[str], str | None, str]:
    """Detect Wine version, staging status, patches, variant, and prefix.

    Args:
        plugin_path: Optional path to the Windows plugin being tested.
                     Used for automatic prefix detection (yabridge-style).
    """
    wine_version = run_command(["wine", "--version"], "unknown")

    # Detect Wine variant (staging, tkg, ge, proton, etc.)
    version_lower = wine_version.lower()
    is_staging = "staging" in version_lower

    wine_variant = None
    if "staging" in version_lower:
        wine_variant = "staging"
    elif "tkg" in version_lower:
        wine_variant = "tkg"
    elif "ge" in version_lower or "glorious" in version_lower:
        wine_variant = "ge"
    elif "proton" in version_lower:
        wine_variant = "proton"

    # Extract version number
    if wine_version.startswith("wine-"):
        wine_version = wine_version[5:]

    # Get Wine prefix (using yabridge-style detection if plugin path provided)
    wine_prefix = detect_wine_prefix(plugin_path)

    # Try to detect patches (this is heuristic)
    patches: list[str] = []

    # Check yabridge logs for patch indicators
    yabridge_log = Path.home() / ".local" / "share" / "yabridge" / "yabridge.log"
    if yabridge_log.exists():
        try:
            content = yabridge_log.read_text()
            if "MR8669" in content:
                patches.append("MR8669")
        except OSError:
            pass

    return wine_version, is_staging, patches, wine_variant, wine_prefix


def detect_wine_dpi(wine_prefix: str | None = None) -> int | None:
    """Detect Wine DPI setting from a Wine prefix.

    Args:
        wine_prefix: Wine prefix path. If None, uses WINEPREFIX env var or ~/.wine
    """
    if wine_prefix is None:
        wine_prefix = os.environ.get("WINEPREFIX", str(Path.home() / ".wine"))

    user_reg = Path(wine_prefix) / "user.reg"

    if not user_reg.exists():
        return None

    try:
        content = user_reg.read_text()
        # Look for LogPixels in registry
        match = re.search(r'"LogPixels"=dword:([0-9a-fA-F]+)', content)
        if match:
            return int(match.group(1), 16)
    except OSError:
        pass

    return None


def detect_gpu_driver() -> str | None:
    """Detect GPU driver in use (nvidia, amd, intel)."""
    # Check for nvidia
    if Path("/proc/driver/nvidia/version").exists():
        return "nvidia"

    # Check lsmod for driver
    lsmod = run_command(["lsmod"])
    if "nvidia" in lsmod:
        return "nvidia"
    elif "amdgpu" in lsmod:
        return "amdgpu"
    elif "radeon" in lsmod:
        return "radeon"
    elif "i915" in lsmod:
        return "intel"

    # Fallback: check glxinfo
    glxinfo = run_command(["glxinfo"])
    if "NVIDIA" in glxinfo:
        return "nvidia"
    elif "AMD" in glxinfo or "Radeon" in glxinfo:
        return "amd"
    elif "Intel" in glxinfo:
        return "intel"

    return None


def detect_yabridge(test_root: Path | None = None) -> tuple[str, str | None, str | None]:
    """Detect yabridge version, commit, and branch."""
    version = "unknown"
    commit = None
    branch = None

    yabridgectl_output = run_command(["yabridgectl", "--version"])
    if yabridgectl_output:
        match = re.search(r"yabridgectl\s+(\S+)", yabridgectl_output)
        if match:
            version = match.group(1)

    if test_root is not None:
        identity = StagingIdentity.load(test_root)
        if identity is not None:
            return version, identity.commit, identity.ref

    for build_info_path in [
        Path("/opt/yabridge/BUILD_INFO"),
        Path.home() / ".local" / "share" / "yabridge" / "BUILD_INFO",
    ]:
        if build_info_path.exists():
            try:
                content = build_info_path.read_text()
                for line in content.splitlines():
                    if line.startswith("Commit:"):
                        commit = line.split(":", 1)[1].strip()
                    elif line.startswith("Branch:"):
                        branch = line.split(":", 1)[1].strip()
            except OSError:
                pass
            break

    return version, commit, branch


def detect_dpi_scale() -> float:
    """Detect DPI scaling factor."""
    scale = 1.0

    # Try GNOME
    gsettings_scale = run_command(
        ["gsettings", "get", "org.gnome.desktop.interface", "text-scaling-factor"]
    )
    if gsettings_scale:
        try:
            scale = float(gsettings_scale)
        except ValueError:
            pass

    # Try KDE
    if scale == 1.0:
        kde_scale = os.environ.get("QT_SCALE_FACTOR", "")
        if kde_scale:
            try:
                scale = float(kde_scale)
            except ValueError:
                pass

    # Try GDK
    if scale == 1.0:
        gdk_scale = os.environ.get("GDK_SCALE", "")
        if gdk_scale:
            try:
                scale = float(gdk_scale)
            except ValueError:
                pass

    return scale


def detect_monitors() -> list[MonitorInfo]:
    """Detect monitor configuration."""
    monitors: list[MonitorInfo] = []

    # Try xrandr
    xrandr_output = run_command(["xrandr", "--query"])
    if xrandr_output:
        for line in xrandr_output.splitlines():
            # Match connected monitors with resolution
            match = re.search(
                r"^(\S+)\s+connected\s+(?:primary\s+)?(\d+)x(\d+)\+(\d+)\+(\d+)",
                line,
            )
            if match:
                monitors.append(
                    MonitorInfo(
                        name=match.group(1),
                        width=int(match.group(2)),
                        height=int(match.group(3)),
                        position_x=int(match.group(4)),
                        position_y=int(match.group(5)),
                        primary="primary" in line,
                    )
                )

    # Fallback: try to get at least primary resolution
    if not monitors:
        try:
            import shutil

            if shutil.which("wlr-randr"):
                # Wayland with wlroots
                wlr_output = run_command(["wlr-randr"])
                # Basic parsing - this could be improved
                for line in wlr_output.splitlines():
                    match = re.search(r"(\d+)x(\d+)", line)
                    if match:
                        monitors.append(
                            MonitorInfo(
                                width=int(match.group(1)),
                                height=int(match.group(2)),
                            )
                        )
                        break
        except Exception:
            pass

    return monitors


def detect_hardware() -> tuple[str | None, str | None, float | None]:
    """Detect CPU, GPU, and RAM."""
    cpu = None
    gpu = None
    ram_gb = None

    # CPU
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    cpu = line.split(":", 1)[1].strip()
                    break
    except FileNotFoundError:
        pass

    # GPU (via lspci)
    lspci_output = run_command(["lspci"])
    if lspci_output:
        for line in lspci_output.splitlines():
            if "VGA" in line or "3D" in line:
                # Extract GPU name after the colon
                if ":" in line:
                    gpu = line.split(":", 2)[-1].strip()
                    break

    # RAM
    try:
        ram_gb = round(psutil.virtual_memory().total / (1024**3), 1)
    except Exception:
        pass

    return cpu, gpu, ram_gb


def collect_environment(plugin_path: str | Path | None = None) -> Environment:
    """Collect all environment information.

    Args:
        plugin_path: Optional path to the Windows plugin being tested.
                     Used for automatic Wine prefix detection (yabridge-style).
                     If the plugin is inside a Wine prefix (has dosdevices in path),
                     that prefix will be used instead of WINEPREFIX env var.
    """
    distro, kernel = detect_distro()
    desktop, desktop_version, compositor = detect_desktop_environment()
    display_server, xwayland_available = detect_display_environment(os.environ)
    wine_version, wine_staging, wine_patches, wine_variant, wine_prefix = (
        detect_wine_version(plugin_path)
    )
    wine_dpi = detect_wine_dpi(wine_prefix)
    test_root = resolve_test_root(os.environ)
    yabridge_version, yabridge_commit, yabridge_branch = detect_yabridge(test_root)
    dpi_scale = detect_dpi_scale()
    monitors = detect_monitors()
    cpu, gpu, ram_gb = detect_hardware()
    gpu_driver = detect_gpu_driver()

    return Environment(
        distro=distro,
        kernel=kernel,
        desktop=desktop,
        desktop_version=desktop_version,
        display_server=display_server,
        xwayland_available=xwayland_available,
        compositor=compositor,
        wine_version=wine_version,
        wine_staging=wine_staging,
        wine_patches=wine_patches,
        wine_variant=wine_variant,
        wine_prefix=wine_prefix,
        wine_dpi=wine_dpi,
        yabridge_version=yabridge_version,
        yabridge_commit=yabridge_commit,
        yabridge_branch=yabridge_branch,
        dpi_scale=dpi_scale,
        monitors=monitors,
        cpu=cpu,
        gpu=gpu,
        gpu_driver=gpu_driver,
        ram_gb=ram_gb,
    )
