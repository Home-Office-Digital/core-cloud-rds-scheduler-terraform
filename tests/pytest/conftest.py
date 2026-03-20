def _short_test_name(nodeid: str) -> str:
    """Return a concise test name from a full nodeid."""
    return nodeid.rsplit("::", 1)[-1]


def pytest_runtest_logreport(report):
    """Print a concise terraform-like line for each test result (call phase).

    Avoid accessing reporter or config to keep the hook robust across pytest
    runner configurations and plugins.
    """
    if getattr(report, "when", None) != "call":
        return

    name = _short_test_name(getattr(report, "nodeid", ""))
    if getattr(report, "passed", False):
        status = "pass"
    elif getattr(report, "skipped", False):
        status = "skipped"
    else:
        status = "fail"

    # Print directly to stdout; pytest captures and displays this alongside its own output.
    print(f'  run "{name}"... {status}')
