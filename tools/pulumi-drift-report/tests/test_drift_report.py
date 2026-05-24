from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from jmmaloney4.tools.pulumi_drift_report import (  # noqa: E402, I001
    discover_pulumi_projects,
    render_text,
    run_drift_report,
)  # type: ignore[import-not-found]


@pytest.fixture()
def pulumi_checkout(tmp_path: Path) -> Path:
    root = tmp_path / "checkout"
    root.mkdir()
    (root / "Pulumi.yaml").write_text(
        "name: demo-project\nruntime: nodejs\n",
        encoding="utf-8",
    )
    ignored = root / "node_modules" / "nested"
    ignored.mkdir(parents=True)
    (ignored / "Pulumi.yaml").write_text(
        "name: ignored\nruntime: nodejs\n",
        encoding="utf-8",
    )
    return root


@pytest.fixture()
def fake_pulumi_bin(tmp_path: Path) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    script = bin_dir / "pulumi"
    script.write_text(
        """#!/usr/bin/env python3
from __future__ import annotations

import json
import sys

args = sys.argv[1:]
if "stack" in args and "ls" in args:
    print(json.dumps([{"name": "dev"}]))
elif "preview" in args:
    print(
        json.dumps(
            {
                "steps": [
                    {
                        "op": "update",
                        "urn": "urn:pulumi:dev::demo-project::pkg:index:Thing::example",
                        "type": "pkg:index:Thing",
                    }
                ]
            }
        )
    )
elif "refresh" in args:
    print(json.dumps({"steps": []}))
else:
    print(json.dumps({"steps": []}))
""",
        encoding="utf-8",
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return bin_dir


def test_discover_projects_ignores_node_modules(pulumi_checkout: Path) -> None:
    projects = discover_pulumi_projects(pulumi_checkout)
    assert projects == [pulumi_checkout]


def test_run_drift_report_renders_preview_and_refresh(
    pulumi_checkout: Path,
    fake_pulumi_bin: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PATH", f"{fake_pulumi_bin}:{os.environ['PATH']}")
    report = run_drift_report(pulumi_checkout, pulumi_bin="pulumi")
    text = render_text(report)

    assert "Pulumi drift report for" in text
    assert "demo-project" in text
    assert "Stack dev" in text
    assert "preview: 1 update" in text
    assert "refresh: no changes" in text
    assert "urn:pulumi:dev::demo-project::pkg:index:Thing::example" in text
    assert not report.errors
    assert report.projects[0].stacks[0].preview is not None
    assert report.projects[0].stacks[0].preview.resource_changes[0].operation == "update"


def test_cli_json_output(
    pulumi_checkout: Path,
    fake_pulumi_bin: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setenv("PATH", f"{fake_pulumi_bin}:{os.environ['PATH']}")
    from jmmaloney4.tools.pulumi_drift_report.__main__ import main

    exit_code = main([str(pulumi_checkout), "--pulumi-bin", "pulumi", "--format", "json"])
    captured = capsys.readouterr()

    assert exit_code == 0
    data = json.loads(captured.out)
    assert data["root"] == str(pulumi_checkout)
    assert data["projects"][0]["stacks"][0]["preview"]["resource_changes"][0]["operation"] == "update"
