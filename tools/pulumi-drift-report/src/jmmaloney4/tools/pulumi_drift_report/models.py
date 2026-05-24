"""Data models for the Pulumi drift report tool."""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class ResourceChange:
    """A single Pulumi resource step that requires attention."""

    operation: str
    urn: str
    resource_type: str | None = None
    name: str | None = None
    detail: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class RunReport:
    """The result of one Pulumi CLI operation for one stack."""

    operation: str
    command: list[str]
    exit_code: int
    summary: dict[str, int] = field(default_factory=dict)
    resource_changes: list[ResourceChange] = field(default_factory=list)
    stderr: str = ""
    error: str | None = None

    @property
    def has_changes(self) -> bool:
        return bool(self.resource_changes)

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["has_changes"] = self.has_changes
        return data


@dataclass(slots=True)
class StackReport:
    """A stack-level report containing preview and/or refresh results."""

    project_dir: Path
    project_name: str | None
    stack_name: str
    preview: RunReport | None = None
    refresh: RunReport | None = None
    errors: list[str] = field(default_factory=list)

    @property
    def has_changes(self) -> bool:
        return any(
            report is not None and report.has_changes
            for report in (self.preview, self.refresh)
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "project_dir": str(self.project_dir),
            "project_name": self.project_name,
            "stack_name": self.stack_name,
            "preview": None if self.preview is None else self.preview.to_dict(),
            "refresh": None if self.refresh is None else self.refresh.to_dict(),
            "errors": list(self.errors),
            "has_changes": self.has_changes,
        }


@dataclass(slots=True)
class ProjectReport:
    """A Pulumi project and all inspected stacks."""

    project_dir: Path
    project_name: str | None
    stacks: list[StackReport] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "project_dir": str(self.project_dir),
            "project_name": self.project_name,
            "stacks": [stack.to_dict() for stack in self.stacks],
            "errors": list(self.errors),
        }


@dataclass(slots=True)
class DriftReport:
    """The full report for a root checkout."""

    root: Path
    projects: list[ProjectReport] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def has_changes(self) -> bool:
        return any(stack.has_changes for project in self.projects for stack in project.stacks)

    def to_dict(self) -> dict[str, Any]:
        return {
            "root": str(self.root),
            "projects": [project.to_dict() for project in self.projects],
            "errors": list(self.errors),
            "has_changes": self.has_changes,
        }
