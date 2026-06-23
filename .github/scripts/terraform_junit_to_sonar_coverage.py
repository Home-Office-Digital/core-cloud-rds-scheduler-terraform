#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


RUN_BLOCK_PATTERN = re.compile(r'^\s*run\s+"([^"]+)"\s*\{')
RESOURCE_BLOCK_PATTERN = re.compile(r'^\s*resource\s+"(\w+)"\s+"(\w+)"\s*\{')
RESOURCE_REF_PATTERN = re.compile(r"\b(aws_\w+\.\w+)\b")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert Terraform JUnit XML into SonarQube generic coverage XML "
            "for *.tftest.hcl run blocks."
        )
    )
    parser.add_argument("--input", required=True, help="Path to the JUnit XML file.")
    parser.add_argument("--output", required=True, help="Path to the SonarQube coverage XML file.")
    return parser.parse_args()


def normalize_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", (value or "").strip().lower()).strip("_")


def resolve_tests_hcl_path(raw_path: str) -> str | None:
    normalized = (raw_path or "").strip().replace("\\", "/")
    if not normalized.endswith(".tftest.hcl"):
        return None

    parts = [part for part in normalized.split("/") if part]
    if "tests" not in parts:
        return None

    idx = parts.index("tests")
    return "/".join(parts[idx:])


def iter_test_cases(root: ET.Element) -> list[tuple[str, ET.Element]]:
    cases: list[tuple[str, ET.Element]] = []

    if root.tag == "testsuite":
        suites = [root]
    else:
        suites = root.findall(".//testsuite")

    for suite in suites:
        suite_name = suite.attrib.get("name", "")
        for case in suite.findall("testcase"):
            file_path = (case.attrib.get("classname") or case.attrib.get("file") or suite_name or "terraform-test")
            cases.append((file_path, case))

    return cases


def parse_run_blocks(path: Path) -> list[tuple[str, int]]:
    if not path.exists():
        return []

    run_blocks: list[tuple[str, int]] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = RUN_BLOCK_PATTERN.match(line)
        if match is not None:
            run_blocks.append((match.group(1), line_no))

    return run_blocks


def list_tf_source_files() -> list[Path]:
    root = Path(".")
    files: list[Path] = []
    for path in root.rglob("*.tf"):
        path_str = path.as_posix()
        if "/.terraform/" in f"/{path_str}/":
            continue
        files.append(path)
    return sorted(files)


def parse_resource_blocks(path: Path) -> list[tuple[str, int]]:
    blocks: list[tuple[str, int]] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = RESOURCE_BLOCK_PATTERN.match(line)
        if match is None:
            continue
        resource_address = f"{match.group(1)}.{match.group(2)}"
        blocks.append((resource_address, line_no))
    return blocks


def collect_resource_references_from_tests() -> set[str]:
    references: set[str] = set()
    tests_dir = Path("tests")
    if not tests_dir.exists():
        return references

    for test_file in sorted(tests_dir.rglob("*.tftest.hcl")):
        content = test_file.read_text(encoding="utf-8")
        references.update(RESOURCE_REF_PATTERN.findall(content))
    return references


def is_case_passed(case: ET.Element) -> bool:
    return (
        case.find("failure") is None
        and case.find("error") is None
        and case.find("skipped") is None
    )


def run_name_covered(run_name: str, passed_case_tokens: set[str]) -> bool:
    run_token = normalize_name(run_name)
    if not run_token:
        return False

    if run_token in passed_case_tokens:
        return True

    return any(
        token.endswith(f"_{run_token}")
        or token.startswith(f"{run_token}_")
        or f"_{run_token}_" in token
        for token in passed_case_tokens
    )


def write_report(report: ET.Element, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if hasattr(ET, "indent"):
        ET.indent(report)
    ET.ElementTree(report).write(output_path, encoding="utf-8", xml_declaration=True)


def collect_cases_by_source(root: ET.Element) -> dict[str, list[ET.Element]]:
    cases_by_source: dict[str, list[ET.Element]] = defaultdict(list)
    for raw_file_path, case in iter_test_cases(root):
        mapped_file_path = resolve_tests_hcl_path(raw_file_path)
        if mapped_file_path is not None:
            cases_by_source[mapped_file_path].append(case)
    return cases_by_source


def add_file_coverage(report: ET.Element, source_path: str, cases: list[ET.Element]) -> tuple[int, int]:
    run_blocks = parse_run_blocks(Path(source_path))
    if not run_blocks:
        return 0, 0

    passed_case_tokens = {normalize_name(case.attrib.get("name", "")) for case in cases if is_case_passed(case)}

    file_element = ET.SubElement(report, "file", path=source_path)
    file_coverable = 0
    file_covered = 0

    for run_name, line_no in run_blocks:
        covered = run_name_covered(run_name, passed_case_tokens)

        ET.SubElement(
            file_element,
            "lineToCover",
            lineNumber=str(line_no),
            covered="true" if covered else "false",
        )
        file_coverable += 1
        if covered:
            file_covered += 1

    print(f"{source_path}: {file_covered}/{file_coverable} run blocks covered")
    return file_coverable, file_covered


def add_tf_source_coverage(report: ET.Element, referenced_resources: set[str], any_tests_passed: bool) -> tuple[int, int]:
    total_coverable = 0
    total_covered = 0

    for tf_file in list_tf_source_files():
        blocks = parse_resource_blocks(tf_file)
        if not blocks:
            continue

        tf_path = tf_file.as_posix()
        file_element = ET.SubElement(report, "file", path=tf_path)
        file_coverable = 0
        file_covered = 0

        for resource_address, line_no in blocks:
            covered = any_tests_passed and resource_address in referenced_resources
            ET.SubElement(
                file_element,
                "lineToCover",
                lineNumber=str(line_no),
                covered="true" if covered else "false",
            )
            file_coverable += 1
            if covered:
                file_covered += 1

        total_coverable += file_coverable
        total_covered += file_covered

        print(f"{tf_path}: {file_covered}/{file_coverable} resources covered")

    return total_coverable, total_covered


def build_report(input_path: Path, output_path: Path) -> None:
    report = ET.Element("coverage", version="1")

    if not input_path.exists():
        write_report(report, output_path)
        print(f"Input report not found: {input_path}", file=sys.stderr)
        return

    root = ET.parse(input_path).getroot()
    cases_by_source = collect_cases_by_source(root)
    referenced_resources = collect_resource_references_from_tests()
    any_tests_passed = any(is_case_passed(case) for cases in cases_by_source.values() for case in cases)

    total_coverable = 0
    total_covered = 0

    for source_path in sorted(cases_by_source):
        file_coverable, file_covered = add_file_coverage(report, source_path, cases_by_source[source_path])
        total_coverable += file_coverable
        total_covered += file_covered

    tf_coverable, tf_covered = add_tf_source_coverage(report, referenced_resources, any_tests_passed)
    total_coverable += tf_coverable
    total_covered += tf_covered

    write_report(report, output_path)

    if total_coverable == 0:
        print("No run blocks found for coverage mapping.")
    else:
        print(f"Overall run-block coverage: {total_covered}/{total_coverable}")
