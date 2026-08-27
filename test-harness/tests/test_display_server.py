import pytest

from yabridge_test.environment import detect_display_environment
from yabridge_test.schemas import DisplayServer


@pytest.mark.parametrize(
    ("env", "session", "xwayland"),
    [
        (
            {
                "XDG_SESSION_TYPE": "wayland",
                "WAYLAND_DISPLAY": "wayland-0",
                "DISPLAY": ":0",
            },
            DisplayServer.WAYLAND,
            True,
        ),
        (
            {"XDG_SESSION_TYPE": "wayland", "WAYLAND_DISPLAY": "wayland-0"},
            DisplayServer.WAYLAND,
            False,
        ),
        ({"XDG_SESSION_TYPE": "x11", "DISPLAY": ":0"}, DisplayServer.X11, False),
    ],
)
def test_display_session_is_separate_from_xwayland(
    env: dict[str, str],
    session: DisplayServer,
    xwayland: bool,
) -> None:
    assert detect_display_environment(env) == (session, xwayland)
