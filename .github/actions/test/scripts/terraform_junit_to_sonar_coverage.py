#!/usr/bin/env python3
import argparse
import xml.etree.ElementTree as ET

# Minimal converter that creates a Sonar generic coverage XML from Terraform junit output.
# This doesn't attempt to compute real coverage; it creates a placeholder root element
# as Sonar accepts coverage roots. This mirrors upstream action behavior minimally.

parser = argparse.ArgumentParser()
parser.add_argument('--input', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()

root = ET.Element('coverage')
# no actual coverage details; Sonar will accept an empty coverage root in many setups
ET.ElementTree(root).write(args.output, encoding='utf-8', xml_declaration=True)
