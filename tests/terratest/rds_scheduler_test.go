package test

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	mr "math/rand"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	awsv2 "github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmTypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"
	"github.com/stretchr/testify/require"
)

// TestRDSScheduler_RuntimeExecutions provisions disposable RDS/Aurora resources, applies the
// scheduler module, then manually triggers one SSM automation and one association (twice) to verify
// runtime behavior and idempotency.
func TestRDSScheduler_RuntimeExecutions(t *testing.T) {
	t.Parallel()

	// Seed the math/rand source used by jitter/backoff helper.
	mr.Seed(time.Now().UnixNano())

	region := pickAwsRegion(t)
	suffix := strings.ToLower(random.UniqueId())
	namePrefix := fmt.Sprintf("test-rds-scheduler-%s", suffix)
	scheduleTagKey := fmt.Sprintf("Schedule-%s", suffix)

	// Resolve automation role ARN. Use CI-provided ROLE_TO_ASSUME (set in the workflow).
	// Fall back to the repository default so local runs still work.
	automationRoleArn := os.Getenv("ROLE_TO_ASSUME")
	if automationRoleArn == "" {
		// Default used in other workflows; keep as last-resort fallback for local runs.
		automationRoleArn = "arn:aws:iam::741448916464:role/cc-ssm-rds-scheduled-stop-start-role-test-automation"
	}
	require.NotEmpty(t, automationRoleArn)

	tfOptsDB := &terraform.Options{
		TerraformDir: "./fixtures-db",
		Vars: map[string]any{
			"name_prefix":      namePrefix,
			"schedule_tag_key": scheduleTagKey,
		},
		EnvVars: map[string]string{
			"AWS_REGION": region,
		},
		RetryableTerraformErrors: map[string]string{
			"(?i)InvalidDBClusterStateFault:.*\\bis in (stopping|starting|stopped) state\\b": "retry: cluster is transitioning",
			"(?i)InvalidDBInstanceState:.*\\bis in (stopping|starting|stopped) state\\b":     "retry: instance is transitioning",
			"(?i)DBInstance is not in available state":                                       "retry: instance not available",
			// Retry when AWS reports the cluster/instance is being deleted — transient race vs prior cleanup
			"(?i)InvalidDBClusterStateFault:.*\\bis (being deleted|deleting)\\b":            "retry: cluster is being deleted",
			"(?i)unexpected state 'deleting'":                                                "retry: instance is deleting",
		},
		MaxRetries:         90,
		TimeBetweenRetries: 30 * time.Second,
		NoColor:            true,
	}

	tfOptsScheduler := &terraform.Options{
		TerraformDir: "./fixtures-scheduler",
		Vars: map[string]any{
			"name_prefix":         namePrefix,
			"automation_role_arn": automationRoleArn,
			"schedule_tag_key":    scheduleTagKey,
		},
		EnvVars: map[string]string{
			"AWS_REGION": region,
		},
		MaxRetries:         60,
		TimeBetweenRetries: 20 * time.Second,
		NoColor:            true,
	}

	applySucceeded := false
	defer destroyTwoPhaseWithRetry(t, tfOptsDB, tfOptsScheduler, region, &applySucceeded)
	preTestCleanupLeftovers(t, region, 4*time.Minute)

	// Copy fixtures to temp to avoid reusing local state between runs.
	tfOptsDB.TerraformDir = test_structure.CopyTerraformFolderToTemp(t, "./", "fixtures-db")
	tfOptsScheduler.TerraformDir = test_structure.CopyTerraformFolderToTemp(t, "./", "fixtures-scheduler")
	rewriteFixtureModuleSourceToRepoRoot(t, tfOptsScheduler.TerraformDir)

	terraform.Init(t, tfOptsDB)
	terraform.Apply(t, tfOptsDB)

	terraform.Init(t, tfOptsScheduler)
	terraform.Apply(t, tfOptsScheduler)
	applySucceeded = true

	documentName := terraform.Output(t, tfOptsScheduler, "ssm_document_name")
	require.NotEmpty(t, documentName)

	ctx := context.Background()
	ssmClient := newSSMClient(t, ctx, region)

	t.Run("aurora_stop_start_idempotent", func(t *testing.T) {
		execID := triggerAutomationExecutionWithRetry(t, ctx, ssmClient, documentName, "Stop", "Schedule", automationRoleArn)

		exec := waitForAutomationExecution(t, ctx, ssmClient, execID, 3*time.Minute)
		require.Equal(t, ssmTypes.AutomationExecutionStatusSuccess, exec.AutomationExecution.AutomationExecutionStatus)
		require.Equal(t, documentName, awsv2.ToString(exec.AutomationExecution.DocumentName))
		requireAutomationAssumeRole(t, exec, automationRoleArn)
		require.NotEmpty(t, exec.AutomationExecution.StepExecutions)
		requireAutomationOutputsShape(t, exec)

		execID2 := triggerAutomationExecutionWithRetry(t, ctx, ssmClient, documentName, "Stop", "Schedule", automationRoleArn)
		exec2 := waitForAutomationExecution(t, ctx, ssmClient, execID2, 3*time.Minute)
		require.Equal(t, ssmTypes.AutomationExecutionStatusSuccess, exec2.AutomationExecution.AutomationExecutionStatus)
		requireAutomationAssumeRole(t, exec2, automationRoleArn)
	})

	t.Run("aurora_no_eligible_tags_succeeds", func(t *testing.T) {
		execID := triggerAutomationExecutionWithRetry(t, ctx, ssmClient, documentName, "Stop", "Schedule_DOES_NOT_EXIST", automationRoleArn)
		exec := waitForAutomationExecution(t, ctx, ssmClient, execID, 3*time.Minute)
		require.Equal(t, ssmTypes.AutomationExecutionStatusSuccess, exec.AutomationExecution.AutomationExecutionStatus)
		require.Equal(t, documentName, awsv2.ToString(exec.AutomationExecution.DocumentName))
		requireAutomationAssumeRole(t, exec, automationRoleArn)
		requireAutomationOutputsShape(t, exec)

		processed, _ := getAutomationOutputsStringList(exec, "ProcessedClusters")
		require.Empty(t, processed)
	})

	t.Run("rds_association_execution_idempotent", func(t *testing.T) {
		startAssocID := findRDSAssociationByPrefixAndDocument(t, ctx, ssmClient, namePrefix, "AWS-StartRdsInstance")
		stopAssocID := findRDSAssociationByPrefixAndDocument(t, ctx, ssmClient, namePrefix, "AWS-StopRdsInstance")
		require.NotEmpty(t, startAssocID)
		require.NotEmpty(t, stopAssocID)

		rdsClient := newRDSClient(t, ctx, region)
		instanceID, initialStatus := findStandaloneRDSInstanceByPrefix(t, ctx, rdsClient, namePrefix)
		t.Logf("RDS association test setup: instance=%s initial_status=%s start_association=%s stop_association=%s", instanceID, initialStatus, startAssocID, stopAssocID)

		normalized := strings.ToLower(initialStatus)
		if normalized != "available" && normalized != "stopped" {
			t.Logf("Instance %s is in transitional status %q; waiting for a stable state (available/stopped)", instanceID, initialStatus)
			waitForDBInstanceStatus(t, ctx, rdsClient, instanceID, map[string]bool{"available": true, "stopped": true}, 15*time.Minute)
			_, initialStatus = findStandaloneRDSInstanceByPrefix(t, ctx, rdsClient, namePrefix)
			normalized = strings.ToLower(initialStatus)
			t.Logf("Instance %s reached stable status %q", instanceID, initialStatus)
		}

		if normalized == "available" {
			t.Logf("Instance %s is available, running stop then start associations", instanceID)
			require.NoError(t, runAssociationOnceWithRetry(t, ctx, ssmClient, stopAssocID, 3, 10*time.Minute))
			waitForDBInstanceStatus(t, ctx, rdsClient, instanceID, map[string]bool{"stopped": true}, 20*time.Minute)
			require.NoError(t, runAssociationOnceWithRetry(t, ctx, ssmClient, startAssocID, 3, 10*time.Minute))
			waitForDBInstanceStatus(t, ctx, rdsClient, instanceID, map[string]bool{"available": true}, 20*time.Minute)
			return
		}

		t.Logf("Instance %s is stopped, running start then stop associations", instanceID)
		require.NoError(t, runAssociationOnceWithRetry(t, ctx, ssmClient, startAssocID, 3, 10*time.Minute))
		waitForDBInstanceStatus(t, ctx, rdsClient, instanceID, map[string]bool{"available": true}, 20*time.Minute)
		require.NoError(t, runAssociationOnceWithRetry(t, ctx, ssmClient, stopAssocID, 3, 10*time.Minute))
		waitForDBInstanceStatus(t, ctx, rdsClient, instanceID, map[string]bool{"stopped": true}, 20*time.Minute)
	})
}

func requireAutomationOutputsShape(t *testing.T, exec *ssm.GetAutomationExecutionOutput) {
	t.Helper()

	// The top-level AutomationExecution.Outputs isn't guaranteed to be populated in all
	// GetAutomationExecution responses. Step-level outputs are more reliable for our
	// single-step runbook.
	keys := []string{"ProcessedClusters", "SkippedClusters", "FailedClusters"}
	for _, k := range keys {
		require.True(t, automationExecutionHasOutputKey(exec, k), "automation outputs missing %s", k)
	}
}

func requireAutomationAssumeRole(t *testing.T, exec *ssm.GetAutomationExecutionOutput, expectedRoleArn string) {
	t.Helper()
	actual, ok := getAutomationParamFirst(exec, "AutomationAssumeRole")
	require.True(t, ok, "automation parameters missing AutomationAssumeRole")
	require.Equal(t, expectedRoleArn, actual)
}

func getAutomationParamFirst(exec *ssm.GetAutomationExecutionOutput, key string) (string, bool) {
	if exec == nil || exec.AutomationExecution == nil || exec.AutomationExecution.Parameters == nil {
		return "", false
	}
	v, ok := exec.AutomationExecution.Parameters[key]
	if !ok || len(v) == 0 {
		return "", false
	}
	return v[0], true
}

func getAutomationOutputsStringList(exec *ssm.GetAutomationExecutionOutput, key string) ([]string, bool) {
	if exec == nil || exec.AutomationExecution == nil {
		return nil, false
	}

	// Prefer top-level outputs if present.
	if exec.AutomationExecution.Outputs != nil {
		if v, ok := exec.AutomationExecution.Outputs[key]; ok {
			return v, true
		}
	}

	// Fall back to step-level outputs.
	for _, step := range exec.AutomationExecution.StepExecutions {
		if step.Outputs == nil {
			continue
		}
		if v, ok := step.Outputs[key]; ok {
			return v, true
		}
	}

	return nil, false
}

func automationExecutionHasOutputKey(exec *ssm.GetAutomationExecutionOutput, key string) bool {
	_, ok := getAutomationOutputsStringList(exec, key)
	return ok
}

// runAssociationOnceWithRetry triggers an SSM association once and waits for completion,
// retrying on transient failures.
func runAssociationOnceWithRetry(t *testing.T, ctx context.Context, client *ssm.Client, associationID string, maxAttempts int, timeout time.Duration) error {
	t.Helper()

	if maxAttempts <= 0 {
		maxAttempts = 1
	}

	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		t.Logf("Running SSM association %s (attempt %d/%d)", associationID, attempt, maxAttempts)
		execID, err := triggerAssociationExecution(ctx, client, associationID)
		if err != nil {
			lastErr = err
			t.Logf("StartAssociationsOnce failed for association %s on attempt %d/%d: %v", associationID, attempt, maxAttempts, err)
			// SSM commonly throttles in constrained accounts.
			errStr := err.Error()
			if strings.Contains(errStr, "ThrottlingException") || strings.Contains(strings.ToLower(errStr), "rate exceeded") {
				sleepWithJitter(attempt, 2*time.Second, 30*time.Second)
				continue
			}
		} else {
			if execID == "" {
				lastErr = fmt.Errorf("StartAssociationsOnce returned empty execution id")
				t.Logf("Association %s returned an empty execution ID on attempt %d/%d", associationID, attempt, maxAttempts)
			} else if werr := waitForAssociationExecutionE(ctx, client, associationID, execID, timeout); werr == nil {
				t.Logf("Association %s execution %s succeeded on attempt %d/%d", associationID, execID, attempt, maxAttempts)
				return nil
			} else {
				t.Logf("Association %s execution %s failed on attempt %d/%d: %v", associationID, execID, attempt, maxAttempts, werr)
				lastErr = werr
			}
		}

		sleepWithJitter(attempt, 1*time.Second, 30*time.Second)
	}

	return lastErr
}

// triggerAutomationExecutionWithRetry starts the Aurora scheduler automation document, retrying on
// common SSM throttling errors.
//
// Inputs:
// - ctx/ssmClient: AWS SDK client + context
// - documentName: SSM Automation document name (created by the module)
// - action: "Start" or "Stop"
// - scheduleTagKey: tag key used for opt-in discovery (usually "Schedule")
// - automationRoleArn: role ARN that Automation should assume
//
// Output:
// - returns the AutomationExecutionId (fails the test if it can't be started).
func triggerAutomationExecutionWithRetry(t *testing.T, ctx context.Context, ssmClient *ssm.Client, documentName, action, scheduleTagKey, automationRoleArn string) string {
	t.Helper()
	const maxAttempts = 12
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		execID, err := triggerAutomationExecution(ctx, ssmClient, documentName, action, scheduleTagKey, automationRoleArn)
		if err == nil {
			return execID
		}

		errStr := err.Error()
		if strings.Contains(errStr, "ThrottlingException") || strings.Contains(strings.ToLower(errStr), "rate exceeded") {
			// On throttling, back off a bit more aggressively with jitter.
			t.Logf("StartAutomationExecution throttled (attempt %d/%d), backing off with jitter: %v", attempt, maxAttempts, err)
			sleepWithJitter(attempt, 2*time.Second, 60*time.Second)
			continue
		}

		require.NoError(t, err)
	}

	t.Fatalf("StartAutomationExecution throttled for %d attempts", maxAttempts)
	return ""
}

// destroyTwoPhaseWithRetry destroys the two Terraform roots created by this test.
//
// It always destroys the scheduler fixture first (so SSM stops/start schedules are removed), then the
// DB fixture (which deletes the RDS instance + Aurora cluster).
//
// Inputs:
// - tfOptsDB: Terraform options for fixtures-db
// - tfOptsScheduler: Terraform options for fixtures-scheduler
// - region: AWS region
// - applySucceeded: whether the test made it past apply (controls whether we do long deletion prep)
func destroyTwoPhaseWithRetry(t *testing.T, tfOptsDB, tfOptsScheduler *terraform.Options, region string, applySucceeded *bool) {
	t.Helper()

	// If apply never succeeded, we may not have created the scheduler stack.
	// Still attempt best-effort cleanup for both roots.
	if tfOptsScheduler != nil && tfOptsScheduler.TerraformDir != "" {
		if !terraformWasInitialized(tfOptsScheduler.TerraformDir) {
			// If credentials are missing/expired, we can fail before init runs.
			// Don't attempt destroy in that case; it adds noisy errors like "Module not installed".
			return
		}
		// Ensure Aurora is deletable before destroying DB root (there can be concurrent stop/start churn).
		// Destroying scheduler first reduces the chance that new stop executions will race the DB deletion.
		destroyWithRetry(t, tfOptsScheduler, region, applySucceeded)
	}

	if tfOptsDB != nil && tfOptsDB.TerraformDir != "" {
		destroyWithRetry(t, tfOptsDB, region, applySucceeded)
	}
}

func terraformWasInitialized(terraformDir string) bool {
	// Terraform init creates .terraform/ and .terraform.lock.hcl.
	if terraformDir == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(terraformDir, ".terraform")); err == nil {
		return true
	}
	if _, err := os.Stat(filepath.Join(terraformDir, ".terraform.lock.hcl")); err == nil {
		return true
	}
	return false
}

// rewriteFixtureModuleSourceToRepoRoot rewrites `source = "../../.."` in a temp-copied fixture
// so it points at the real repo root on disk.
//
// Terratest copies Terraform folders to a temp dir; relative module paths then break. This keeps the
// fixture self-contained while still testing the module under development.
//
// Input:
// - tempTerraformDir: the temp directory containing the copied fixture's `main.tf`
func rewriteFixtureModuleSourceToRepoRoot(t *testing.T, tempTerraformDir string) {
	t.Helper()

	wd, err := os.Getwd()
	require.NoError(t, err)
	repoRoot := filepath.Clean(filepath.Join(wd, "..", ".."))

	fixtureMain := filepath.Join(tempTerraformDir, "main.tf")
	b, err := os.ReadFile(fixtureMain)
	require.NoError(t, err)
	s := string(b)

	p := regexp.MustCompile(`(?m)^\s*source\s*=\s*"\.\./\.\./\.\."\s*$`)
	if !p.MatchString(s) {
		t.Fatalf("expected to find module source = \"../../..\" in %s", fixtureMain)
	}
	s = p.ReplaceAllString(s, fmt.Sprintf(`	source = %q`, repoRoot))

	err = os.WriteFile(fixtureMain, []byte(s), 0o644)
	require.NoError(t, err)
}

// preTestCleanupLeftovers best-effort cleans up resources from previous runs.
func preTestCleanupLeftovers(t *testing.T, region string, timeout time.Duration) {
	t.Helper()

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	require.NoError(t, err)
	rdsClient := rds.NewFromConfig(cfg)

	deadline := time.Now().Add(timeout)

	// 1) Aurora clusters: start if stopped, wait until available, then delete.
	clustersOut, err := rdsClient.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{})
	if err == nil {
		for _, c := range clustersOut.DBClusters {
			if time.Now().After(deadline) {
				return
			}

			id := awsv2.ToString(c.DBClusterIdentifier)
			if !strings.HasPrefix(id, "test-rds-scheduler-") {
				continue
			}

			if arn := awsv2.ToString(c.DBClusterArn); arn != "" {
				if ok, known := hasFixtureTag(ctx, rdsClient, arn); known && !ok {
					continue
				}
			}

			status := strings.ToLower(awsv2.ToString(c.Status))
			if status == "stopped" {
				_, _ = rdsClient.StartDBCluster(ctx, &rds.StartDBClusterInput{DBClusterIdentifier: awsv2.String(id)})
			}

			waitForClusterStatus(ctx, rdsClient, id, map[string]bool{"available": true, "deleting": true}, time.Until(deadline))

			_, _ = rdsClient.DeleteDBCluster(ctx, &rds.DeleteDBClusterInput{
				DBClusterIdentifier: awsv2.String(id),
				SkipFinalSnapshot:   awsv2.Bool(true),
			})

			// Wait for deletion to complete before returning so tests won't race with in-progress deletes.
			// Limit wait to a short window per-resource to avoid large pre-test delays.
			_ = waitForClusterDeletion(ctx, rdsClient, id, 5*time.Minute)
		}
	}

	// 2) Standalone DB instances (non-Aurora): delete any old test instances.
	instOut, err := rdsClient.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{})
	if err == nil {
		for _, i := range instOut.DBInstances {
			if time.Now().After(deadline) {
				return
			}
			id := awsv2.ToString(i.DBInstanceIdentifier)
			if !strings.HasPrefix(id, "test-rds-scheduler-") {
				continue
			}

			if i.DBClusterIdentifier != nil && awsv2.ToString(i.DBClusterIdentifier) != "" {
				continue
			}

			if arn := awsv2.ToString(i.DBInstanceArn); arn != "" {
				if ok, known := hasFixtureTag(ctx, rdsClient, arn); known && !ok {
					continue
				}
			}

			_, _ = rdsClient.DeleteDBInstance(ctx, &rds.DeleteDBInstanceInput{
				DBInstanceIdentifier: awsv2.String(id),
				SkipFinalSnapshot:    awsv2.Bool(true),
			})

			// Wait for instance deletion to complete to avoid create/delete races in subsequent test runs.
			_ = waitForInstanceDeletion(ctx, rdsClient, id, 3*time.Minute)
		}
	}
}

// waitForClusterDeletion polls DescribeDBClusters until the cluster no longer exists or timeout.
func waitForClusterDeletion(ctx context.Context, client *rds.Client, clusterID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for cluster %s deletion", clusterID)
		}
		out, err := client.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{DBClusterIdentifier: &clusterID})
		if err != nil {
			// If not found, deletion completed.
			if strings.Contains(err.Error(), "DBClusterNotFoundFault") {
				return nil
			}
			// Unknown error: wait a bit and retry.
			time.Sleep(5 * time.Second)
			continue
		}
		if len(out.DBClusters) == 0 {
			return nil
		}
		// If cluster is in deleting state, keep waiting.
		status := strings.ToLower(awsv2.ToString(out.DBClusters[0].Status))
		if status == "deleting" {
			time.Sleep(5 * time.Second)
			continue
		}
		// Otherwise, break and return: resource still exists in another state.
		time.Sleep(2 * time.Second)
	}
}

// waitForInstanceDeletion polls DescribeDBInstances until the instance no longer exists or timeout.
func waitForInstanceDeletion(ctx context.Context, client *rds.Client, instanceID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for instance %s deletion", instanceID)
		}
		out, err := client.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{DBInstanceIdentifier: &instanceID})
		if err != nil {
			// If not found, deletion completed.
			if strings.Contains(err.Error(), "DBInstanceNotFound") || strings.Contains(err.Error(), "DBInstanceNotFoundFault") {
				return nil
			}
			time.Sleep(5 * time.Second)
			continue
		}
		if len(out.DBInstances) == 0 {
			return nil
		}
		// If instance is deleting, keep waiting.
		status := strings.ToLower(awsv2.ToString(out.DBInstances[0].DBInstanceStatus))
		if status == "deleting" {
			time.Sleep(5 * time.Second)
			continue
		}
		time.Sleep(2 * time.Second)
	}
}

// hasFixtureTag checks for Fixture=terratest. If tag-listing fails (permissions), it returns (false, false)
// meaning "unknown" so callers can choose to proceed based on name-prefix alone.
func hasFixtureTag(ctx context.Context, client *rds.Client, resourceArn string) (has bool, known bool) {
	out, err := client.ListTagsForResource(ctx, &rds.ListTagsForResourceInput{ResourceName: awsv2.String(resourceArn)})
	if err != nil {
		return false, false
	}
	for _, tag := range out.TagList {
		if awsv2.ToString(tag.Key) == "Fixture" && awsv2.ToString(tag.Value) == "terratest" {
			return true, true
		}
	}
	return false, true
}

// waitForClusterStatus polls DescribeDBClusters until the cluster enters any desired state or the
// timeout expires.
//
// Inputs:
// - desired: map of lowercase status => true (e.g. {"available": true, "deleting": true})
// - timeout: max duration to wait (best-effort; returns silently on timeout)
func waitForClusterStatus(ctx context.Context, client *rds.Client, clusterID string, desired map[string]bool, timeout time.Duration) {
	deadline := time.Now().Add(timeout)
	for {
		if time.Now().After(deadline) {
			return
		}
		out, err := client.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{DBClusterIdentifier: awsv2.String(clusterID)})
		if err != nil || len(out.DBClusters) == 0 {
			return
		}
		st := strings.ToLower(awsv2.ToString(out.DBClusters[0].Status))
		if desired[st] {
			return
		}
		time.Sleep(5 * time.Second)
	}
}

// destroyWithRetry runs `terraform destroy` with retries for known transient errors.
//
// If applySucceeded is true and an `aurora_cluster_id` output is available, it first attempts to
// ensure the cluster is in a deletable state (Aurora clusters in stopped/stopping states can fail
// deletion).
func destroyWithRetry(t *testing.T, tfOpts *terraform.Options, region string, applySucceeded *bool) {
	t.Helper()

	var err error

	if applySucceeded != nil && *applySucceeded {
		auroraClusterID, err := terraform.OutputE(t, tfOpts, "aurora_cluster_id")
		if err == nil && auroraClusterID != "" {
			// If the test stopped the cluster, delete may fail until it is available again.
			ensureAuroraClusterAvailableForDeletion(t, region, auroraClusterID, 20*time.Minute)
		}
	}

	maxRetries := tfOpts.MaxRetries
	if maxRetries <= 0 {
		maxRetries = 30
	}
	interval := tfOpts.TimeBetweenRetries
	if interval <= 0 {
		interval = 20 * time.Second
	}

	_, err = retry.DoWithRetryE(t, "terraform destroy", maxRetries, interval, func() (string, error) {
		out, err := terraform.DestroyE(t, tfOpts)
		if err == nil {
			return out, nil
		}

		errStr := err.Error()
		for pattern := range tfOpts.RetryableTerraformErrors {
			if ok, _ := regexpMatchString(pattern, errStr); ok {
				return "retryable destroy error: " + errStr, err
			}
		}
		return "non-retryable destroy error: " + errStr, retry.FatalError{Underlying: err}
	})
	require.NoError(t, err)
}

// ensureAuroraClusterAvailableForDeletion makes a best-effort attempt to get an Aurora cluster into
// a state where deletion will succeed.
//
// It polls the cluster status and, if stopped/stopping, attempts to start it and then waits until it
// becomes available (or is already deleting/gone).
func ensureAuroraClusterAvailableForDeletion(t *testing.T, region, clusterID string, timeout time.Duration) {
	t.Helper()

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	require.NoError(t, err)
	rdsClient := rds.NewFromConfig(cfg)

	deadline := time.Now().Add(timeout)
	for {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for aurora cluster %s to become available for deletion", clusterID)
		}

		out, err := rdsClient.DescribeDBClusters(ctx, &rds.DescribeDBClustersInput{
			DBClusterIdentifier: &clusterID,
		})
		if err != nil {
			// If it doesn't exist, we're good.
			if strings.Contains(err.Error(), "DBClusterNotFoundFault") {
				return
			}
			// Unknown error; keep trying a bit in case it's eventual consistency.
			time.Sleep(20 * time.Second)
			continue
		}
		if len(out.DBClusters) == 0 {
			return
		}

		status := strings.ToLower(awsv2.ToString(out.DBClusters[0].Status))
		switch status {
		case "available":
			return
		case "deleting":
			return
		case "stopped", "stopping":
			_, _ = retryStartDBCluster(ctx, rdsClient, clusterID)
		case "starting":
			// wait
		default:
			// Other transient states: keep waiting.
		}

		time.Sleep(20 * time.Second)
	}
}

// retryStartDBCluster attempts to start an Aurora cluster with retry/backoff.
//
// This is used during teardown because SSM schedules (or manual test executions) can leave the
// cluster stopped, which often blocks deletion.
func retryStartDBCluster(ctx context.Context, client *rds.Client, clusterID string) (string, error) {
	// Best-effort start with small backoff. Safe to call even if cluster is already starting.
	const maxAttempts = 12
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		_, err := client.StartDBCluster(ctx, &rds.StartDBClusterInput{DBClusterIdentifier: awsv2.String(clusterID)})
		if err == nil {
			return "start initiated", nil
		}

		errStr := err.Error()
		// regexpMatchString compiles an inline-regex pattern (supports (?i)) and checks if it matches `s`.
		// It's used to test terraform error strings against RetryableTerraformErrors patterns.
		// Common: cluster is already starting/available.
		if strings.Contains(errStr, "InvalidDBClusterStateFault") {
			// Treat as retryable; state may flip to startable.
		} else if strings.Contains(errStr, "Throttling") || strings.Contains(strings.ToLower(errStr), "rate exceeded") {
			// retry
		} else if strings.Contains(errStr, "DBClusterNotFoundFault") {
			return "cluster not found", nil
		} else {
			// Unknown error: still retry a bit because this is a teardown helper.
		}

		sleep := time.Duration(attempt*attempt) * time.Second
		time.Sleep(sleep)
	}
	return "start not confirmed", fmt.Errorf("failed to StartDBCluster after retries for %s", clusterID)
}

// regexpMatchString is a small wrapper so we don't have to keep compiled regexes around.
func regexpMatchString(pattern, s string) (bool, error) {
	// Go's regexp supports inline flags like (?i)
	re, err := regexp.Compile(pattern)
	if err != nil {
		return false, err
	}
	return re.MatchString(s), nil
}

// pickAwsRegion chooses the AWS region for the test from env vars, defaulting to eu-west-2.
func pickAwsRegion(t *testing.T) string {
	t.Helper()
	if r := os.Getenv("AWS_REGION"); r != "" {
		return r
	}
	if r := os.Getenv("AWS_DEFAULT_REGION"); r != "" {
		return r
	}
	return "eu-west-2"
}

// newSSMClient constructs an SSM client in the given region.
func newSSMClient(t *testing.T, ctx context.Context, region string) *ssm.Client {
	t.Helper()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	require.NoError(t, err)
	return ssm.NewFromConfig(cfg)
}

// newRDSClient constructs an RDS client in the given region.
func newRDSClient(t *testing.T, ctx context.Context, region string) *rds.Client {
	t.Helper()
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	require.NoError(t, err)
	return rds.NewFromConfig(cfg)
}

// triggerAutomationExecution starts the given automation document once.
//
// Inputs:
// - documentName: SSM Automation document name
// - action: "Start" or "Stop"
// - scheduleTagKey: tag key used by the document's discovery logic
// - assumeRoleArn: role for automation to assume
//
// Output:
// - returns the AutomationExecutionId.
func triggerAutomationExecution(ctx context.Context, client *ssm.Client, documentName, action, scheduleTagKey, assumeRoleArn string) (string, error) {
	out, err := client.StartAutomationExecution(ctx, &ssm.StartAutomationExecutionInput{
		DocumentName: awsv2.String(documentName),
		Parameters: map[string][]string{
			"Action":               {action},
			"ScheduleTagKey":       {scheduleTagKey},
			"AutomationAssumeRole": {assumeRoleArn},
			"TargetKey":            {"placeholder"},
		},
	})
	if err != nil {
		return "", err
	}
	if awsv2.ToString(out.AutomationExecutionId) == "" {
		return "", fmt.Errorf("StartAutomationExecution returned empty AutomationExecutionId")
	}
	return awsv2.ToString(out.AutomationExecutionId), nil
}

// waitForAutomationExecution polls GetAutomationExecution until it succeeds or fails.
//
// Output:
// - returns the final execution state on success; fatal-fails the test on failure/timeout.
func waitForAutomationExecution(t *testing.T, ctx context.Context, client *ssm.Client, execID string, timeout time.Duration) *ssm.GetAutomationExecutionOutput {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for automation execution %s", execID)
		}

		out, err := client.GetAutomationExecution(ctx, &ssm.GetAutomationExecutionInput{
			AutomationExecutionId: awsv2.String(execID),
		})
		require.NoError(t, err)
		require.NotNil(t, out.AutomationExecution)

		switch out.AutomationExecution.AutomationExecutionStatus {
		case ssmTypes.AutomationExecutionStatusSuccess:
			return out
		case ssmTypes.AutomationExecutionStatusFailed,
			ssmTypes.AutomationExecutionStatusCancelled,
			ssmTypes.AutomationExecutionStatusTimedout:
			// Enhanced: log step-level details for easier debugging
			if steps := out.AutomationExecution.StepExecutions; len(steps) > 0 {
				t.Logf("Automation execution %s failed. Step details:", execID)
				for _, step := range steps {
					t.Logf("  Step: %s | Status: %s | FailureDetails: %v | Outputs: %v", awsv2.ToString(step.StepName), step.StepStatus, step.FailureDetails, step.Outputs)
				}
			}

			// Also dump the full GetAutomationExecution output to ensure any nested FailureDetails
			// or other fields are captured in the test log output for post-mortem.
			dumpAutomationExecutionJSON(t, execID, out)
			t.Fatalf("automation execution %s ended with status %s", execID, out.AutomationExecution.AutomationExecutionStatus)
		default:
		}

		time.Sleep(5 * time.Second)
	}
}

func findRDSAssociationByPrefixAndDocument(t *testing.T, ctx context.Context, client *ssm.Client, namePrefix, documentName string) string {
	t.Helper()

	// Only return AWS-managed RDS associations for the requested document.
	var nextToken *string
	for {
		out, err := client.ListAssociations(ctx, &ssm.ListAssociationsInput{
			MaxResults: awsv2.Int32(50),
			NextToken:  nextToken,
		})
		require.NoError(t, err)

		for _, a := range out.Associations {
			if !strings.HasPrefix(awsv2.ToString(a.AssociationName), namePrefix) {
				continue
			}
			name := awsv2.ToString(a.Name)
			if name == documentName {
				return awsv2.ToString(a.AssociationId)
			}
		}

		if out.NextToken == nil || awsv2.ToString(out.NextToken) == "" {
			break
		}
		nextToken = out.NextToken
	}

	t.Fatalf("no RDS association found with prefix %q and document %q", namePrefix, documentName)
	return ""
}

func findStandaloneRDSInstanceByPrefix(t *testing.T, ctx context.Context, client *rds.Client, namePrefix string) (instanceID, status string) {
	t.Helper()

	out, err := client.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{})
	require.NoError(t, err)

	for _, i := range out.DBInstances {
		id := awsv2.ToString(i.DBInstanceIdentifier)
		if !strings.HasPrefix(id, namePrefix) {
			continue
		}
		if i.DBClusterIdentifier != nil && awsv2.ToString(i.DBClusterIdentifier) != "" {
			continue
		}
		return id, awsv2.ToString(i.DBInstanceStatus)
	}

	t.Fatalf("no standalone RDS instance found with prefix %q", namePrefix)
	return "", ""
}

func waitForDBInstanceStatus(t *testing.T, ctx context.Context, client *rds.Client, instanceID string, desired map[string]bool, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)

	for {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for DB instance %s to reach one of %v", instanceID, desired)
		}

		out, err := client.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
			DBInstanceIdentifier: awsv2.String(instanceID),
		})
		require.NoError(t, err)
		require.NotEmpty(t, out.DBInstances)

		current := strings.ToLower(awsv2.ToString(out.DBInstances[0].DBInstanceStatus))
		t.Logf("DB instance %s current status: %s (waiting for %v)", instanceID, current, desired)
		if desired[current] {
			return
		}

		time.Sleep(15 * time.Second)
	}
}

// dumpAutomationExecutionJSON marshals the GetAutomationExecution output and logs it.
func dumpAutomationExecutionJSON(t *testing.T, execID string, out *ssm.GetAutomationExecutionOutput) {
	t.Helper()
	if out == nil {
		t.Logf("no GetAutomationExecution output to dump for %s", execID)
		return
	}
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Logf("failed to marshal GetAutomationExecution output for %s: %v", execID, err)
		return
	}
	t.Logf("Full GetAutomationExecution JSON for %s:\n%s", execID, string(b))
}

// sleepWithJitter sleeps using exponential backoff with full jitter.
// attempt is 1-based. min and max bound the sleep duration.
func sleepWithJitter(attempt int, min, max time.Duration) {
	// Exponential base (2^attempt), scaled and jittered.
	// Use float64 for safe math, but clamp to max.
	exp := math.Pow(2, float64(attempt-1))
	// base sleep is min * exp, but clamp to max.
	base := time.Duration(float64(min) * exp)
	if base > max {
		base = max
	}
	// Add jitter: random between 0 and base
	jitter := time.Duration(mr.Int63n(int64(base) + 1))
	sleep := base + jitter
	if sleep > max {
		sleep = max
	}
	time.Sleep(sleep)
}

// triggerAssociationExecution causes an association to run immediately via StartAssociationsOnce
// and then returns the most recent execution ID found for it.
func triggerAssociationExecution(ctx context.Context, client *ssm.Client, associationID string) (string, error) {
	_, err := client.StartAssociationsOnce(ctx, &ssm.StartAssociationsOnceInput{
		AssociationIds: []string{associationID},
	})
	if err != nil {
		return "", err
	}
	return findLatestAssociationExecutionID(ctx, client, associationID)
}

// findLatestAssociationExecutionID returns the newest execution ID for an association.
//
// Note: SSM returns executions in descending order (newest first) for this API.
func findLatestAssociationExecutionID(ctx context.Context, client *ssm.Client, associationID string) (string, error) {
	out, err := client.DescribeAssociationExecutions(ctx, &ssm.DescribeAssociationExecutionsInput{
		AssociationId: awsv2.String(associationID),
		MaxResults:    awsv2.Int32(50),
	})
	if err != nil {
		return "", err
	}
	if len(out.AssociationExecutions) == 0 {
		return "", fmt.Errorf("no association executions found for %s", associationID)
	}
	return awsv2.ToString(out.AssociationExecutions[0].ExecutionId), nil
}

// waitForAssociationExecutionE polls DescribeAssociationExecutions until the given execution reaches
// Success or a terminal failure status.
//
// Output:
// - returns nil on success, or an error describing the terminal status.
func waitForAssociationExecutionE(ctx context.Context, client *ssm.Client, associationID, executionID string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if time.Now().After(deadline) {
			diag := associationExecutionDiagnostics(ctx, client, associationID, executionID)
			if diag != "" {
				return fmt.Errorf("timed out waiting for association execution %s/%s. diagnostics: %s", associationID, executionID, diag)
			}
			return fmt.Errorf("timed out waiting for association execution %s/%s", associationID, executionID)
		}

		executions, err := listAssociationExecutions(ctx, client, associationID)
		if err != nil {
			return err
		}

		for _, exec := range executions {
			if awsv2.ToString(exec.ExecutionId) != executionID {
				continue
			}

			s := awsv2.ToString(exec.Status)
			switch s {
			case "Success":
				return nil
			case "Failed", "TimedOut", "Cancelled":
				return associationExecutionTerminalError(ctx, client, associationID, executionID, s, awsv2.ToString(exec.DetailedStatus))
			default:
			}
		}

		sleepWithJitter(1, 5*time.Second, 30*time.Second)
	}
}

func listAssociationExecutions(ctx context.Context, client *ssm.Client, associationID string) ([]ssmTypes.AssociationExecution, error) {
	out, err := client.DescribeAssociationExecutions(ctx, &ssm.DescribeAssociationExecutionsInput{
		AssociationId: awsv2.String(associationID),
		MaxResults:    awsv2.Int32(50),
	})
	if err != nil {
		return nil, err
	}
	return out.AssociationExecutions, nil
}

func associationExecutionDiagnostics(ctx context.Context, client *ssm.Client, associationID, executionID string) string {
	// Best-effort: pull the execution record plus a larger slice of targets.
	out, err := client.DescribeAssociationExecutions(ctx, &ssm.DescribeAssociationExecutionsInput{
		AssociationId: awsv2.String(associationID),
		MaxResults:    awsv2.Int32(50),
	})
	if err != nil {
		return fmt.Sprintf("DescribeAssociationExecutions error: %v", err)
	}

	status := "(not found in DescribeAssociationExecutions results)"
	detailed := ""
	for _, exec := range out.AssociationExecutions {
		if awsv2.ToString(exec.ExecutionId) != executionID {
			continue
		}
		status = awsv2.ToString(exec.Status)
		detailed = awsv2.ToString(exec.DetailedStatus)
		break
	}

	tgtOut, tgtErr := client.DescribeAssociationExecutionTargets(ctx, &ssm.DescribeAssociationExecutionTargetsInput{
		AssociationId: awsv2.String(associationID),
		ExecutionId:   awsv2.String(executionID),
		MaxResults:    awsv2.Int32(50),
	})
	if tgtErr != nil {
		return fmt.Sprintf("status=%s detailed=%s; DescribeAssociationExecutionTargets error: %v", status, detailed, tgtErr)
	}
	if tgtOut == nil || len(tgtOut.AssociationExecutionTargets) == 0 {
		return fmt.Sprintf("status=%s detailed=%s; targets=0", status, detailed)
	}

	lines := make([]string, 0, 5)
	for i, tgt := range tgtOut.AssociationExecutionTargets {
		if i >= 5 {
			break
		}
		lines = append(lines, fmt.Sprintf(
			"target %s/%s status=%s detailed=%s",
			awsv2.ToString(tgt.ResourceType),
			awsv2.ToString(tgt.ResourceId),
			awsv2.ToString(tgt.Status),
			awsv2.ToString(tgt.DetailedStatus),
		))
	}

	return fmt.Sprintf("status=%s detailed=%s; %s", status, detailed, strings.Join(lines, "; "))
}

func associationExecutionTerminalError(ctx context.Context, client *ssm.Client, associationID, executionID, status, detailedStatus string) error {
	if detailedStatus == "" {
		detailedStatus = status
	}

	// Best-effort: fetch execution *target* details (often contains more context).
	// Note: this is frequently empty for tag-targeted associations when there are no managed instances.
	out, err := client.DescribeAssociationExecutionTargets(ctx, &ssm.DescribeAssociationExecutionTargetsInput{
		AssociationId: awsv2.String(associationID),
		ExecutionId:   awsv2.String(executionID),
		MaxResults:    awsv2.Int32(10),
	})
	if err != nil || out == nil || len(out.AssociationExecutionTargets) == 0 {
		return fmt.Errorf("association execution %s/%s ended with status %s (%s)", associationID, executionID, status, detailedStatus)
	}

	// Include multiple target status lines to make failures actionable.
	lines := make([]string, 0, 10)
	for i, tgt := range out.AssociationExecutionTargets {
		if i >= 10 {
			break
		}
		lines = append(lines, fmt.Sprintf(
			"target %s/%s status=%s detailed=%s",
			awsv2.ToString(tgt.ResourceType),
			awsv2.ToString(tgt.ResourceId),
			awsv2.ToString(tgt.Status),
			awsv2.ToString(tgt.DetailedStatus),
		))
	}

	return fmt.Errorf(
		"association execution %s/%s ended with status %s (%s): %s",
		associationID,
		executionID,
		status,
		detailedStatus,
		strings.Join(lines, "; "),
	)
}
