import pytest

from petahour.mocks.server import MockServer
from petahour.tee import AttestationError, SimulatedHost, request_attestation, verify_eat
from petahour.telemetry import features, merkle_root, simulate
from petahour.zk_model import QuantizedModel
from petahour import zk_bridge


@pytest.fixture(scope="module")
def mock():
    with MockServer(port=8801) as server:
        yield server


def test_genuine_host_passes_and_token_is_signed(mock):
    host = SimulatedHost("h1")
    bundle, nonce, random_part = request_attestation(host, mock.base_url)
    result = verify_eat(bundle, nonce, random_part, host.tee_address, mock.base_url)
    assert result.overall["x-nvidia-overall-att-result"] is True
    assert len(result.gpus) == host.gpu_count


def test_compromised_host_is_rejected(mock):
    host = SimulatedHost("h2", compromised=True)
    bundle, nonce, random_part = request_attestation(host, mock.base_url)
    with pytest.raises(AttestationError, match="overall attestation result"):
        verify_eat(bundle, nonce, random_part, host.tee_address, mock.base_url)


def test_token_cannot_vouch_for_another_key(mock):
    host, impostor = SimulatedHost("h3"), SimulatedHost("h4")
    bundle, nonce, random_part = request_attestation(host, mock.base_url)
    with pytest.raises(AttestationError, match="not bound"):
        verify_eat(bundle, nonce, random_part, impostor.tee_address, mock.base_url)


def test_stale_token_is_rejected(mock):
    host = SimulatedHost("h5")
    bundle, _, random_part = request_attestation(host, mock.base_url)
    other_nonce, _ = host.new_nonce()
    with pytest.raises(AttestationError, match="nonce mismatch"):
        verify_eat(bundle, other_nonce, random_part, host.tee_address, mock.base_url)


def test_tampered_token_fails_signature_check(mock):
    import jwt

    host = SimulatedHost("h6")
    bundle, nonce, random_part = request_attestation(host, mock.base_url)
    head, body, sig = bundle[0][1].split(".")
    bundle[0][1] = ".".join([head, body[:-2] + "AA", sig])
    with pytest.raises(jwt.exceptions.PyJWTError):
        verify_eat(bundle, nonce, random_part, host.tee_address, mock.base_url)


def test_merkle_root_changes_with_any_record():
    records = simulate(24, seed=1)
    assert merkle_root(records) == merkle_root(simulate(24, seed=1))
    assert merkle_root(records) != merkle_root(simulate(24, seed=2))


def test_features_are_in_circuit_range():
    for profile in ("healthy", "degraded", "idle-fraud"):
        assert all(0 <= f < 2**14 for f in features(simulate(24, profile, seed=4)))


def test_model_passes_healthy_and_fails_faults():
    model = QuantizedModel.from_json(zk_bridge.model_json())
    for seed in range(20):
        assert model.passes(features(simulate(24, "healthy", seed=seed)))
        assert model.passes(features(simulate(24, "partial", seed=seed)))
        assert not model.passes(features(simulate(24, "degraded", seed=seed)))
        assert not model.passes(features(simulate(24, "idle-fraud", seed=seed)))


def test_honest_partial_delivery_can_be_proven():
    """Regression: an honest seller reporting a real outage must not be slashable."""
    feats = features(simulate(24, "partial", seed=3))
    assert feats[0] < 9000
    assert QuantizedModel.from_json(zk_bridge.model_json()).passes(feats)
    proof = zk_bridge.prove(feats, 42, feats[0], 9)
    assert int(proof["publicSignals"][3]) == feats[0]


def test_partial_delivery_cannot_be_rounded_up():
    feats = features(simulate(24, "partial", seed=3))
    with pytest.raises(zk_bridge.ProofUnavailable):
        zk_bridge.prove(feats, 42, 10_000, 9)


def test_prover_refuses_a_false_claim():
    bad = features(simulate(24, "degraded", seed=1))
    with pytest.raises(zk_bridge.ProofUnavailable):
        zk_bridge.prove(bad, 42, 10_000, 1)


def test_proof_cannot_overclaim_uptime_on_healthy_telemetry():
    good = features(simulate(24, "healthy", seed=1))
    with pytest.raises(zk_bridge.ProofUnavailable):
        zk_bridge.prove(good, 42, good[0] + 1, 1)


def test_python_and_circuit_agree_on_the_integer_forward_pass():
    model = QuantizedModel.from_json(zk_bridge.model_json())
    good = features(simulate(24, "healthy", seed=1))
    assert model.passes(good)
    proof = zk_bridge.prove(good, 42, good[0], 7)
    assert int(proof["publicSignals"][2]) == model.threshold
