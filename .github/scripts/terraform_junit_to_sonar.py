#!/usr/bin/env python3

from __future__ import annotations

import argparse
import shutil
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
import re


FAILURE_ANCHOR_DIR = Path("tests/sonar-testcases")
LEGACY_FAILURE_ANCHOR_DIR = Path("tests/.sonar-failure-anchors")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert Terraform JUnit XML into SonarQube generic test execution XML."
    )
    parser.add_argument("--input", required=True, help="Path to the JUnit XML file.")
    parser.add_argument("--output", required=True, help="Path to the SonarQube XML file.")
    return parser.parse_args()


def duration_to_millis(value: str | None) -> str:
    if not value:
        return "0"

    try:
        return str(max(0, round(float(value) * 1000)))
    except ValueError:
        return "0"


def first_text(element: ET.Element | None, fallback: str) -> str:
    if element is None:
        return fallback

    text = (element.text or "").strip()
    message = (element.attrib.get("message") or "").strip()
    combined = "\n".join(part for part in [message, text] if part)
    return combined or fallback


def _safe_case_token(case_name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9]+", "_", (case_name or "unnamed").strip())
    return normalized.strip("_") or "unnamed"


def _reset_failure_anchor_dir() -> None:
    if FAILURE_ANCHOR_DIR.exists():
        shutil.rmtree(FAILURE_ANCHOR_DIR)
    if LEGACY_FAILURE_ANCHOR_DIR.exists():
        shutil.rmtree(LEGACY_FAILURE_ANCHOR_DIR)


def _failure_anchor_path(source_file: str, test_name: str) -> str:
    source_name = Path(source_file).name
    source_stem = source_name
    source_extension = ""
    if source_name.endswith(".tftest.hcl"):
        source_stem = source_name[: -len(".tftest.hcl")]
        source_extension = ".tftest.hcl"
    else:
        split_name = Path(source_name)
        source_stem = split_name.stem
        source_extension = split_name.suffix

    return str(FAILURE_ANCHOR_DIR / f"{_safe_case_token(test_name)}_{source_stem}{source_extension}")


def _ensure_failure_anchor_file(path_str: str, source_file: str, test_name: str) -> None:
    path = Path(path_str)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "# Generated for SonarQube failure visibility\n"
        f"# Source test file: {source_file}\n"
        f"# Failed testcase: {test_name}\n",
        encoding="utf-8",
    )


def build_case_name(file_path: str, case_name: str, failed: bool) -> str:
    normalized_case_name = (case_name or "unnamed").strip()
    if not failed:
        return f"{file_path} / {normalized_case_name}"

    file_name = Path(file_path).name
    file_stem = file_name
    file_extension = ""
    if file_name.endswith(".tftest.hcl"):
        file_stem = file_name[: -len(".tftest.hcl")]
        file_extension = ".tftest.hcl"
    else:
        split_name = Path(file_name)
        file_stem = split_name.stem
        file_extension = split_name.suffix

    return f"{_safe_case_token(normalized_case_name)}_{file_stem}{file_extension}"


def extract_line_reference(details: str) -> str | None:
    match = re.search(r"line\s+(\d+)", details, flags=re.IGNORECASE)
    if match is None:
        return None
    return match.group(1)


def failure_message(file_path: str, case_name: str, failure: ET.Element | None) -> str:
    details = first_text(failure, "Test failed")
    line_reference = extract_line_reference(details)
    line_suffix = f" line={line_reference}" if line_reference is not None else ""
    return f"FAILED: {case_name} ({file_path}{line_suffix}) | {details}"


def with_test_context(file_path: str, case_name: str, details: str) -> str:
    first_line = f"testcase={case_name} file={file_path}"
    if details:
        return f"{first_line}\n{details}"
    return first_line


def attach_outcome(test_case: ET.Element, outcome_tag: str, file_path: str, case_name: str, details: str) -> None:
    context = with_test_context(file_path, case_name, details)
    outcome = ET.SubElement(test_case, outcome_tag, message=context)
    outcome.text = context


def iter_test_cases(root: ET.Element) -> list[tuple[str, str, ET.Element]]:
    cases: list[tuple[str, str, ET.Element]] = []

    if root.tag == "testsuite":
        suites = [root]
    else:
        suites = root.findall(".//testsuite")

    for suite in suites:
        suite_name = suite.attrib.get("name", "")
        for case in suite.findall("testcase"):
            file_path = (case.attrib.get("classname") or case.attrib.get("file") or suite_name or "terraform-test")
            cases.append((file_path, suite_name, case))

    return cases


def resolve_tests_hcl_path(raw_path: str) -> str | None:
    normalized = (raw_path or "").strip().replace("\\", "/")
    if not normalized.endswith(".tftest.hcl"):
        return None
    parts = [part for part in normalized.split("/") if part]
    if "tests" in parts:
        idx = parts.index("tests")
        return "/".join(parts[idx:])
    return None


def build_report(input_path: Path, output_path: Path) -> None:
    report = ET.Element("testExecutions", version="1")
    _reset_failure_anchor_dir()

    if not input_path.exists():
        output_path.parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(report).write(output_path, encoding="utf-8", xml_declaration=True)
        print(f"Input report not found: {input_path}", file=sys.stderr)
        return

    root = ET.parse(input_path).getroot()
    files: dict[str, ET.Element] = {}
    counts_by_file: dict[str, int] = defaultdict(int)

    cases_by_source: dict[str, list[ET.Element]] = defaultdict(list)
    for file_path, _suite_name, case in iter_test_cases(root):
        mapped_file_path = resolve_tests_hcl_path(file_path)
        if mapped_file_path is None:
            continue
        cases_by_source[mapped_file_path].append(case)

    for mapped_file_path, cases in cases_by_source.items():
        for case in cases:
            case_name = case.attrib.get("name", "unnamed")
            failure = case.find("failure")
            error = case.find("error")
            skipped = case.find("skipped")
            failed_or_errored = failure is not None or error is not None

            report_file_path = mapped_file_path
            if failed_or_errored:
                report_file_path = _failure_anchor_path(mapped_file_path, case_name)
                _ensure_failure_anchor_file(report_file_path, mapped_file_path, case_name)

            file_element = files.get(report_file_path)
            if file_element is None:
                file_element = ET.SubElement(report, "file", path=report_file_path)
                files[report_file_path] = file_element

            display_case_name = build_case_name(mapped_file_path, case_name, failed_or_errored)

            test_case = ET.SubElement(file_element, "testCase", name=display_case_name, duration=duration_to_millis(case.attrib.get("time")))

            if failure is not None:
                ET.SubElement(test_case, "failure", message=failure_message(mapped_file_path, case_name, failure))
            elif error is not None:
                attach_outcome(test_case, "error", mapped_file_path, case_name, first_text(error, "Test errored"))
            elif skipped is not None:
                attach_outcome(test_case, "skipped", mapped_file_path, case_name, first_text(skipped, "Test skipped"))

            counts_by_file[report_file_path] += 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if hasattr(ET, "indent"):
        ET.indent(report)
    ET.ElementTree(report).write(output_path, encoding="utf-8", xml_declaration=True)

    if counts_by_file:
        print("Sonar test file summary:")
        for path in sorted(counts_by_file):
            print(f"  {path}: {counts_by_file[path]} tests")
    else:
        print("No tests/*.hcl testcases were found in JUnit input.")
