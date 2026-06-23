#!/usr/bin/env python3
import argparse
import xml.etree.ElementTree as ET

# Simple converter from Terraform junit xml to SonarQube generic test report
# This is a minimal implementation sufficient for terraform test outputs used by the action.

parser = argparse.ArgumentParser()
parser.add_argument('--input', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()

root = ET.parse(args.input).getroot()

testsuites = ET.Element('testExecutions')
for suite in root.findall('testsuite'):
    for case in suite.findall('testcase'):
        test_case = ET.SubElement(testsuites, 'testCase')
        # use classname + name as the full name
        classname = case.get('classname', '')
        name = case.get('name', '')
        ET.SubElement(test_case, 'name').text = f"{classname}.{name}" if classname else name
        # duration
        time = case.get('time', '0')
        ET.SubElement(test_case, 'duration').text = str(int(float(time) * 1000))
        # result
        if case.find('failure') is not None or case.find('error') is not None:
            ET.SubElement(test_case, 'status').text = 'FAILED'
        else:
            ET.SubElement(test_case, 'status').text = 'PASSED'

ET.ElementTree(testsuites).write(args.output, encoding='utf-8', xml_declaration=True)
