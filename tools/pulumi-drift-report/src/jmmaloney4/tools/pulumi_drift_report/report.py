"""Pulumi drift report orchestration and rendering."""

from __future__ import annotations

import json
import os
import re
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any

from .models import DriftReport, ProjectReport, ResourceChange, RunReport, StackReport

try:  # optional at runtime; Nix packaging provides it, regex remains a fallback
    import yaml
except ImportError:  # pragma: no cover - fallback for minimal environments
    yaml = None

IGNORED_DIR_NAMES = {
    ".direnv",
    ".git",
    ".venv",
    "build",
    "dist",
    "node_modules",
    "result",
    "__pycache__",
}

PULUMI_SKIP_UPDATE_CHECK = "1"

_PULUMI_CONFIG_FILENAMES = ("Pulumi.yaml", "Pulumi.yml")


_PROJECT_NAME_RE = re.compile(r"^name:\s*(?:(?P<dq>\".*?\")|(?P<sq>'.*?')|(?P<bare>[^#\s]+))\s*(?:#.*)?$")


def discover_pulumi_projects(root: Path) -> list[Path]:
    """Find directories containing a Pulumi project file under *root*."""
    projects: list[Path] = []
    root = root.resolve()
    for current_root, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in IGNORED_DIR_NAMES)
        if any(filename in filenames for filename in _PULUMI_CONFIG_FILENAMES):
            projects.append(Path(current_root))
    return sorted(projects)


def read_project_name(project_dir: Path) -> str | None:
    """Extract the project name from a Pulumi project file if possible."""
    for filename in _PULUMI_CONFIG_FILENAMES:
        config = project_dir / filename
        try:
            text = config.read_text(encoding="utf-8")
        except FileNotFoundError:
            continue
        if yaml is not None:
            try:
                document = yaml.safe_load(text)
            except Exception:  # pragma: no cover - fallback for malformed config
                document = None
            if isinstance(document, dict):
                name = document.get("name")
                if isinstance(name, str) and name.strip():
                    return name.strip().strip('"')
        for line in text.splitlines():
            match = _PROJECT_NAME_RE.match(line.strip())
            if not match:
                continue
            value = match.group("dq") or match.group("sq") or match.group("bare")
            if value is None:
                return None
            return value.strip().strip("\"'")
    return None


def _base_env() -> dict[str, str]:
    env = dict(os.environ)
    env.setdefault("PULUMI_SKIP_UPDATE_CHECK", PULUMI_SKIP_UPDATE_CHECK)
    return env


def _pulumi_command(
    pulumi_bin: str,
    project_dir: Path,
    *args: str,
) -> list[str]:
    return [pulumi_bin, "-C", str(project_dir), *args]


def run_pulumi_json(
    pulumi_bin: str,
    project_dir: Path,
    *args: str,
) -> subprocess.CompletedProcess[str]:
    """Run a Pulumi CLI command and capture stdout/stderr."""
    return subprocess.run(
        _pulumi_command(pulumi_bin, project_dir, *args),
        capture_output=True,
        check=False,
        env=_base_env(),
        text=True,
    )


def list_stacks(pulumi_bin: str, project_dir: Path) -> list[str]:
    """Return all stack names for the current Pulumi project."""
    result = run_pulumi_json(
        pulumi_bin,
        project_dir,
        "stack",
        "ls",
        "--json",
        "--non-interactive",
    )
    if result.returncode != 0:
        raise RuntimeError((result.stderr or result.stdout or "pulumi stack ls failed").strip())

    document = parse_document(result.stdout)
    if not isinstance(document, list):
        raise RuntimeError("pulumi stack ls returned unexpected JSON")

    names: list[str] = []
    for item in document:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if isinstance(name, str) and name:
            names.append(name)
    return sorted(names)


def _parse_json_lines(stdout: str) -> list[Any]:
    records: list[Any] = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if not records:
        raise json.JSONDecodeError("Expected JSONL records", stdout, 0)
    return records


def parse_document(stdout: str) -> Any:
    """Parse Pulumi's JSON output, supporting JSON and JSONL forms."""
    stripped = stdout.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return _parse_json_lines(stripped)


def _parse_urn(urn: str) -> tuple[str | None, str | None]:
    if not urn.startswith("urn:pulumi:"):
        return None, None
    parts = urn.split("::")
    if len(parts) < 4:
        return None, None
    return parts[-2] or None, parts[-1] or None


def _step_to_change(step: dict[str, Any]) -> ResourceChange | None:
    op = str(step.get("op") or step.get("operation") or step.get("kind") or "unknown")
    if op.lower() in {"same", "unchanged", "no-op", "read"}:
        return None

    urn = step.get("urn")
    if not isinstance(urn, str) or not urn:
        for state_key in ("newState", "oldState"):
            state = step.get(state_key)
            if isinstance(state, dict):
                candidate = state.get("urn")
                if isinstance(candidate, str) and candidate:
                    urn = candidate
                    break
    if not isinstance(urn, str) or not urn:
        return None

    resource_type, name = _parse_urn(urn)
    detail: dict[str, Any] = {}
    for key in ("reason", "detailedDiff"):
        value = step.get(key)
        if value is not None:
            detail[key] = value

    return ResourceChange(
        operation=op,
        urn=urn,
        resource_type=resource_type,
        name=name,
        detail=detail,
    )


def _steps_from_document(document: Any) -> list[dict[str, Any]]:
    if isinstance(document, dict):
        steps = document.get("steps")
        if isinstance(steps, list):
            return [step for step in steps if isinstance(step, dict)]
        if any(key in document for key in ("op", "urn", "operation", "kind")):
            return [document]
        return []

    if isinstance(document, list):
        steps: list[dict[str, Any]] = []
        for item in document:
            if not isinstance(item, dict):
                continue
            nested_steps: Any = item.get("steps")
            if isinstance(nested_steps, list):
                steps.extend(step for step in nested_steps if isinstance(step, dict))
                continue
            if any(key in item for key in ("op", "urn", "operation", "kind")):
                steps.append(item)
        return steps
    return []


def _summary_from_changes(changes: list[ResourceChange]) -> dict[str, int]:
    counts = Counter(change.operation for change in changes)
    return dict(sorted(counts.items()))


def _run_operation(
    pulumi_bin: str,
    project_dir: Path,
    stack_name: str,
    operation: str,
) -> RunReport:
    args: list[str] = [
        operation,
        "--json",
        "--stack",
        stack_name,
        "--non-interactive",
        "--suppress-progress",
        "--suppress-outputs",
    ]
    if operation == "preview":
        args.append("--refresh")
    elif operation == "refresh":
        args.append("--preview-only")
    else:
        raise ValueError(f"unsupported operation: {operation}")

    result = run_pulumi_json(pulumi_bin, project_dir, *args)
    if result.returncode != 0:
        error = (result.stderr or result.stdout or f"pulumi {operation} failed").strip()
        return RunReport(
            operation=operation,
            command=_pulumi_command(pulumi_bin, project_dir, *args),
            exit_code=result.returncode,
            stderr=result.stderr,
            error=error,
        )

    try:
        document = parse_document(result.stdout)
    except (json.JSONDecodeError, RuntimeError) as exc:
        return RunReport(
            operation=operation,
            command=_pulumi_command(pulumi_bin, project_dir, *args),
            exit_code=result.returncode,
            stderr=result.stderr,
            error=f"Failed to parse Pulumi output: {exc}",
        )

    steps = _steps_from_document(document)
    changes: list[ResourceChange] = []
    for step in steps:
        change = _step_to_change(step)
        if change is not None:
            changes.append(change)
    changes.sort(key=lambda change: (change.urn, change.operation))

    return RunReport(
        operation=operation,
        command=_pulumi_command(pulumi_bin, project_dir, *args),
        exit_code=result.returncode,
        summary=_summary_from_changes(changes),
        resource_changes=changes,
        stderr=result.stderr,
    )


def run_drift_report(
    root: Path,
    pulumi_bin: str = "pulumi",
    mode: str = "both",
    stack_filters: set[str] | None = None,
) -> DriftReport:
    """Generate a full report for every Pulumi project under *root*."""
    projects: list[ProjectReport] = []
    project_paths = discover_pulumi_projects(root)
    for project_dir in project_paths:
        project_name = read_project_name(project_dir)
        project_report = ProjectReport(project_dir=project_dir, project_name=project_name)
        try:
            stacks = list_stacks(pulumi_bin, project_dir)
        except RuntimeError as exc:
            project_report.errors.append(str(exc))
            projects.append(project_report)
            continue

        if stack_filters is not None:
            stacks = [stack for stack in stacks if stack in stack_filters]

        for stack_name in stacks:
            stack_report = StackReport(
                project_dir=project_dir,
                project_name=project_name,
                stack_name=stack_name,
            )
            if mode in {"preview", "both"}:
                stack_report.preview = _run_operation(pulumi_bin, project_dir, stack_name, "preview")
                if stack_report.preview.error is not None:
                    stack_report.errors.append(stack_report.preview.error)
            if mode in {"refresh", "both"}:
                stack_report.refresh = _run_operation(pulumi_bin, project_dir, stack_name, "refresh")
                if stack_report.refresh.error is not None:
                    stack_report.errors.append(stack_report.refresh.error)
            project_report.stacks.append(stack_report)
        projects.append(project_report)
    return DriftReport(root=root, projects=projects)


def render_text(report: DriftReport) -> str:
    """Render a human-friendly report."""
    lines: list[str] = []
    lines.append(f"Pulumi drift report for {report.root}")
    if not report.projects:
        lines.append("No Pulumi projects found.")
        return "\n".join(lines)

    for project in report.projects:
        header = str(project.project_dir)
        if project.project_name:
            header += f" ({project.project_name})"
        lines.append(header)
        for error in project.errors:
            lines.append(f"  ERROR: {error}")
        for stack in project.stacks:
            lines.append(f"  Stack {stack.stack_name}")
            for error in stack.errors:
                lines.append(f"    ERROR: {error}")
            for label, run in (("preview", stack.preview), ("refresh", stack.refresh)):
                if run is None:
                    continue
                if run.error is not None:
                    lines.append(f"    {label}: failed ({run.error})")
                    continue
                if not run.resource_changes:
                    lines.append(f"    {label}: no changes")
                    continue
                summary = ", ".join(f"{count} {op}" for op, count in sorted(run.summary.items()))
                lines.append(f"    {label}: {summary}")
                for change in run.resource_changes:
                    suffix = f" [{change.resource_type}]" if change.resource_type else ""
                    lines.append(f"      {change.operation}: {change.urn}{suffix}")
    if report.errors:
        lines.append("Global errors:")
        lines.extend(f"  - {error}" for error in report.errors)
    return "\n".join(lines)


def report_to_json(report: DriftReport) -> str:
    return json.dumps(report.to_dict(), indent=2, sort_keys=True) + "\n"
