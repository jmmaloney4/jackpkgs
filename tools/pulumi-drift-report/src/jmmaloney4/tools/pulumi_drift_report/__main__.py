"""CLI entry point for the Pulumi drift report tool."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Sequence

from .report import render_text, report_to_json, run_drift_report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pulumi-drift-report",
        description="Report Pulumi preview/refresh changes for every stack under a checkout",
    )
    parser.add_argument(
        "root",
        nargs="?",
        type=Path,
        default=Path.cwd(),
        help="Root directory to scan for Pulumi projects (default: current directory)",
    )
    parser.add_argument(
        "--pulumi-bin",
        default="pulumi",
        help="Pulumi CLI executable to invoke (default: pulumi)",
    )
    parser.add_argument(
        "--mode",
        choices=("both", "preview", "refresh"),
        default="both",
        help="Which Pulumi operation(s) to run per stack",
    )
    parser.add_argument(
        "--stack",
        action="append",
        dest="stacks",
        help="Only inspect the named stack(s); may be passed multiple times",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="Render the final report as text or JSON",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    stack_filters = set(args.stacks) if args.stacks else None
    report = run_drift_report(
        args.root,
        pulumi_bin=args.pulumi_bin,
        mode=args.mode,
        stack_filters=stack_filters,
    )
    if args.format == "json":
        print(report_to_json(report), end="")
    else:
        print(render_text(report))

    has_errors = any(
        project.errors
        or any(stack.errors for stack in project.stacks)
        for project in report.projects
    ) or bool(report.errors)
    return 1 if has_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
