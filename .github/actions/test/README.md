Local fork of Home-Office-Digital/core-cloud-workflow-terraform-actions/actions/test

Differences:
- Adds a new `test-directory` input that is passed to `terraform test -test-directory` when provided.
- Intended for use in repos where tests live in a different directory than the module under test.

Usage in workflow:

uses: ./.github/actions/test
with:
  working-directory: .
  test-directory: tests/plan
  sonar-host-url: ${{ secrets.SONAR_HOST_URL }}
  sonar-token: ${{ secrets.SONAR_TOKEN }}
