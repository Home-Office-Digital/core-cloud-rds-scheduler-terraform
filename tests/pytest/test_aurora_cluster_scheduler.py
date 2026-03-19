import importlib.util
import pathlib
import types
import sys
from types import SimpleNamespace


def load_module():
    # Locate repository root by walking upwards until scripts/aurora_cluster_scheduler.py is found
    p = pathlib.Path(__file__).resolve().parent
    root = None
    while True:
        candidate = p / "scripts" / "aurora_cluster_scheduler.py"
        if candidate.exists():
            root = p
            break
        if p.parent == p:
            raise RuntimeError("Repository root with scripts/aurora_cluster_scheduler.py not found")
        p = p.parent

    module_path = root / "scripts" / "aurora_cluster_scheduler.py"
    spec = importlib.util.spec_from_file_location("aurora_cluster_scheduler", str(module_path))
    module = importlib.util.module_from_spec(spec)
    # Ensure a dummy boto3 is available during import so tests can run without real boto3
    if "boto3" not in sys.modules:
        import types as _types

        fake_boto3 = _types.ModuleType("boto3")
        # provide a default client factory; tests will monkeypatch as needed
        fake_boto3.client = lambda *args, **kwargs: None
        sys.modules["boto3"] = fake_boto3

    spec.loader.exec_module(module)
    return module


class FakeExceptions(SimpleNamespace):
    pass


def test_is_multi_az_db_cluster_true():
    # Objective: ensure non-Aurora MySQL clusters with DBClusterInstanceClass are detected as Multi-AZ
    # Setup: cluster dict uses Engine 'mysql5.7' and includes 'DBClusterInstanceClass'
    # Expected: is_multi_az_db_cluster returns True
    mod = load_module()
    cluster = {"Engine": "mysql5.7", "DBClusterInstanceClass": "db.r5.large"}
    assert mod.is_multi_az_db_cluster(cluster) is True


def test_is_multi_az_db_cluster_false():
    # Objective: ensure Aurora engine types are not flagged as Multi-AZ DB Cluster
    # Setup: cluster dict uses Engine 'aurora-mysql' and no instance class
    # Expected: is_multi_az_db_cluster returns False
    mod = load_module()
    cluster = {"Engine": "aurora-mysql",}
    assert mod.is_multi_az_db_cluster(cluster) is False


def test_is_stoppable_cluster_unstoppable_engine():
    # Objective: validate clusters with unstoppable engine modes are skipped
    # Setup: cluster with EngineMode 'serverless'
    # Expected: is_stoppable_cluster returns False
    mod = load_module()
    cluster = {"DBClusterIdentifier": "c1", "EngineMode": "serverless"}
    assert mod.is_stoppable_cluster(cluster) is False


def test_has_schedule_tag_true_and_false(monkeypatch):
    # Objective: verify tag lookup succeeds when tag exists and handles exceptions
    # Setup: FakeClient returns TagList with Schedule; BadClient raises exception
    # Expected: has_schedule_tag returns True for good client and False for exception
    mod = load_module()

    class FakeClient:
        def list_tags_for_resource(self, resource_name=None, **kwargs):
            # Accept either positional or the AWS-style keyword 'ResourceName'
            _ = resource_name if resource_name is not None else kwargs.get("ResourceName")
            return {"TagList": [{"Key": "Schedule", "Value": "*"}]}

    c = FakeClient()
    assert mod.has_schedule_tag(c, "arn:aws:rds:us-east-1:1:cluster:c1", "Schedule") is True

    class BadClient:
        def list_tags_for_resource(self, resource_name=None, **kwargs):
            # Intentionally raise a specific error type for the test
            _ = resource_name if resource_name is not None else kwargs.get("ResourceName")
            raise RuntimeError("boom")

    assert mod.has_schedule_tag(BadClient(), "arn", "Schedule") is False


def test_perform_action_with_retry_success(monkeypatch):
    # Objective: ensure perform_action_with_retry calls API and returns new status on success
    # Setup: FakeClient implements start_db_cluster and describe_db_clusters returning 'starting'
    # Expected: function returns 'starting' without raising
    mod = load_module()

    class FakeClient:
        def __init__(self):
            self.calls = 0

        class exceptions:
            class InvalidDBClusterStateFault(Exception):
                pass

        def start_db_cluster(self, db_cluster_identifier=None, **kwargs):
            # Accept the AWS 'DBClusterIdentifier' kwarg name as well
            _ = db_cluster_identifier if db_cluster_identifier is not None else kwargs.get("DBClusterIdentifier")
            self.calls += 1

        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier if db_cluster_identifier is not None else kwargs.get("DBClusterIdentifier")
            return {"DBClusters": [{"Status": "starting"}]}

    fake = FakeClient()
    monkeypatch.setattr(mod, "time", types.SimpleNamespace(sleep=lambda *_: None))
    status = mod.perform_action_with_retry(fake, "c1", mod.ACTION_START)
    assert status == "starting"


def test_perform_action_with_retry_transient_then_success(monkeypatch):
    # Objective: validate transient errors are retried and eventual success returns status
    # Setup: FakeClient raises transient Exception on first two start attempts, succeeds on third
    # Expected: perform_action_with_retry returns 'starting'
    mod = load_module()

    class FakeClient:
        def __init__(self):
            self.calls = 0

        class exceptions:
            class InvalidDBClusterStateFault(Exception):
                pass

        def start_db_cluster(self, db_cluster_identifier=None, **kwargs):
            # Accept the AWS 'DBClusterIdentifier' kwarg name as well
            _ = db_cluster_identifier if db_cluster_identifier is not None else kwargs.get("DBClusterIdentifier")
            self.calls += 1
            if self.calls < 3:
                # Use a specific exception type for transient failures
                raise RuntimeError("transient")

        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier if db_cluster_identifier is not None else kwargs.get("DBClusterIdentifier")
            return {"DBClusters": [{"Status": "starting"}]}

    fake = FakeClient()
    monkeypatch.setattr(mod, "time", types.SimpleNamespace(sleep=lambda *_: None))
    status = mod.perform_action_with_retry(fake, "c1", mod.ACTION_START)
    assert status == "starting"


def test_perform_action_with_retry_transient_fail(monkeypatch):
    # Objective: verify repeated transient failures propagate the last exception
    # Setup: FakeClient always raises Exception from start_db_cluster
    # Expected: perform_action_with_retry raises the same Exception
    mod = load_module()

    class FakeClient:
        def __init__(self):
            # No initialization necessary for this fake client
            return None

        class exceptions:
            class InvalidDBClusterStateFault(Exception):
                pass

        def start_db_cluster(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            raise RuntimeError("always fail")

        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            return {"DBClusters": [{"Status": "starting"}]}

    fake = FakeClient()
    monkeypatch.setattr(mod, "time", types.SimpleNamespace(sleep=lambda *_: None))
    try:
        mod.perform_action_with_retry(fake, "c1", mod.ACTION_START)
        assert False, "should have raised"
    except Exception as exc:
        assert str(exc) == "always fail"


def test_perform_action_with_retry_invalid_state_fault(monkeypatch):
    # Objective: ensure InvalidDBClusterStateFault is not retried and is re-raised immediately
    # Setup: FakeClient.stop_db_cluster raises InvalidDBClusterStateFault
    # Expected: perform_action_with_retry re-raises the InvalidDBClusterStateFault
    mod = load_module()

    class FakeClient:
        def __init__(self):
            # No-op constructor for this fake client used in process_cluster tests
            return None

        class exceptions:
            class InvalidDBClusterStateFault(Exception):
                pass

        def stop_db_cluster(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            raise FakeClient.exceptions.InvalidDBClusterStateFault("bad state")

    fake = FakeClient()
    monkeypatch.setattr(mod, "time", types.SimpleNamespace(sleep=lambda *_: None))
    try:
        mod.perform_action_with_retry(fake, "c1", mod.ACTION_STOP)
        assert False, "should have re-raised InvalidDBClusterStateFault"
    except Exception as exc:
        assert "bad state" in str(exc)


def test_process_cluster_start_and_stop(monkeypatch):
    # Objective: test process_cluster handles valid start/stop transitions and marks processed
    # Setup: Fake clients return STATUS_STOPPED or STATUS_AVAILABLE; perform_action_with_retry patched
    # Expected: process_cluster returns outcome 'processed' for both start and stop paths
    mod = load_module()

    # Start from stopped -> processed
    class FakeClientStart:
        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            return {"DBClusters": [{"Status": mod.STATUS_STOPPED}]}

    monkeypatch.setattr(mod, "perform_action_with_retry", lambda c, cid, action: mod.STATUS_STARTING)
    res = mod.process_cluster(FakeClientStart(), "c1", mod.ACTION_START)
    assert res["outcome"] == "processed"

    # Stop from available -> processed
    class FakeClientStop:
        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            return {"DBClusters": [{"Status": mod.STATUS_AVAILABLE}]}

    monkeypatch.setattr(mod, "perform_action_with_retry", lambda c, cid, action: mod.STATUS_STOPPING)
    res2 = mod.process_cluster(FakeClientStop(), "c2", mod.ACTION_STOP)
    assert res2["outcome"] == "processed"


def test_process_cluster_invalid_transitions(monkeypatch):
    # Objective: validate invalid state transitions are skipped with appropriate outcome
    # Setup: Fake clients return STATUS_AVAILABLE for start and 'foo' for stop
    # Expected: process_cluster returns outcome 'skipped' for invalid transitions
    mod = load_module()

    class FakeClient:
        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            return {"DBClusters": [{"Status": mod.STATUS_AVAILABLE}]}

    # Attempt to start when already available -> skipped
    res = mod.process_cluster(FakeClient(), "c1", mod.ACTION_START)
    assert res["outcome"] == "skipped"

    class FakeClient2:
        def describe_db_clusters(self, db_cluster_identifier=None, **kwargs):
            _ = db_cluster_identifier
            return {"DBClusters": [{"Status": "foo"}]}

    res2 = mod.process_cluster(FakeClient2(), "c2", mod.ACTION_STOP)
    assert res2["outcome"] == "skipped"


def test_handler_end_to_end(monkeypatch):
    # Objective: end-to-end handler flow: discovery, filtering by tag, and processing
    # Setup: paginator yields three clusters (stoppable+tagged, unstoppable, stoppable+untagged)
    # Process cluster patched to return 'processed' for the stoppable one
    # Expected: handler returns one ProcessedClusters entry and no skipped/failed clusters
    mod = load_module()

    # Create clusters: one stoppable and tagged, one unstoppble, one stoppable not tagged
    cluster_stoppable = {"DBClusters": [{"DBClusterIdentifier": "c-stoppable", "EngineMode": "provisioned", "DBClusterArn": "arn:1"}]}
    cluster_unstoppable = {"DBClusters": [{"DBClusterIdentifier": "c-unstoppable", "EngineMode": "serverless", "DBClusterArn": "arn:2"}]}
    cluster_not_tagged = {"DBClusters": [{"DBClusterIdentifier": "c-not-tagged", "EngineMode": "provisioned", "DBClusterArn": "arn:3"}]}

    class Paginator:
        def __init__(self):
            self.pages = [cluster_stoppable, cluster_unstoppable, cluster_not_tagged]

        def paginate(self):
            for p in self.pages:
                yield p

    class FakeClient:
        def __init__(self):
            # No initialization required for this fake client; methods drive behavior
            return None

        def get_paginator(self, name):
            return Paginator()

        def list_tags_for_resource(self, resource_name=None, **kwargs):
            _ = resource_name if resource_name is not None else kwargs.get("ResourceName")
            if _ == "arn:1":
                return {"TagList": [{"Key": "Schedule", "Value": "*"}]}
            if _ == "arn:3":
                return {"TagList": []}
            return {"TagList": []}

    fake = FakeClient()

    # Patch boto3.client used inside handler
    monkeypatch.setattr(mod.boto3, "client", lambda *args, **kwargs: fake)

    # Patch process_cluster to return processed for c-stoppable
    def fake_process(_, cid, action):
        if cid == "c-stoppable":
            return {"cluster_id": cid, "outcome": "processed", "message": "ok", "status": "starting"}
        return {"cluster_id": cid, "outcome": "failed", "message": "bad", "status": ""}

    monkeypatch.setattr(mod, "process_cluster", fake_process)
    monkeypatch.setattr(mod, "time", types.SimpleNamespace(sleep=lambda *_: None))

    out = mod.handler({"Action": "Stop", "ScheduleTagKey": "Schedule"}, None)
    assert out["ProcessedClusters"] == ["c-stoppable"]
    assert out["SkippedClusters"] == []
    assert out["FailedClusters"] == []
