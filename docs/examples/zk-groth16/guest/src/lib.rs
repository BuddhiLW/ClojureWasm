wit_bindgen::generate!({
    world: "zk-groth16",
    path: "wit",
    generate_all,
});

use exports::hive::zk_groth16::tools::Guest as Tools;

use ark_bn254::{Bn254, Fr};
use ark_groth16::{Groth16, Proof, ProvingKey, VerifyingKey};
use ark_relations::{
    lc,
    r1cs::{ConstraintSynthesizer, ConstraintSystemRef, SynthesisError, Variable},
};
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_snark::SNARK;
use rand::SeedableRng;
use rand_chacha::ChaCha20Rng;
use std::cell::RefCell;

const GENERATION: &str = match option_env!("ZK_GEN") {
    Some(g) => g,
    None => "1",
};

/// `x^3 + x + 5 == y`, with `x` private and `y` public.
///
/// Three R1CS constraints. The circuit is deliberately tiny: the claim under
/// test is that a real proving system runs inside a zero-import component, not
/// that this particular statement is interesting.
#[derive(Clone)]
struct CubicCircuit {
    x: Option<Fr>,
}

impl ConstraintSynthesizer<Fr> for CubicCircuit {
    fn generate_constraints(self, cs: ConstraintSystemRef<Fr>) -> Result<(), SynthesisError> {
        let five = Fr::from(5u64);

        let x_val = self.x;
        let x = cs.new_witness_variable(|| x_val.ok_or(SynthesisError::AssignmentMissing))?;

        let x2_val = x_val.map(|v| v * v);
        let x2 = cs.new_witness_variable(|| x2_val.ok_or(SynthesisError::AssignmentMissing))?;
        cs.enforce_constraint(lc!() + x, lc!() + x, lc!() + x2)?;

        let x3_val = x2_val.and_then(|a| x_val.map(|b| a * b));
        let x3 = cs.new_witness_variable(|| x3_val.ok_or(SynthesisError::AssignmentMissing))?;
        cs.enforce_constraint(lc!() + x2, lc!() + x, lc!() + x3)?;

        let y_val = x3_val.and_then(|a| x_val.map(|b| a + b + five));
        let y = cs.new_input_variable(|| y_val.ok_or(SynthesisError::AssignmentMissing))?;
        cs.enforce_constraint(
            lc!() + x3 + x + (five, Variable::One),
            lc!() + Variable::One,
            lc!() + y,
        )?;

        Ok(())
    }
}

/// The trusted setup is deterministic in `seed`, so prove and verify can each
/// regenerate it rather than marshalling a proving key across the boundary.
/// Cached because the setup dominates the cost and the seed rarely changes;
/// wasm is single-threaded, so a `thread_local` is the whole synchronisation
/// story.
type Keys = (ProvingKey<Bn254>, VerifyingKey<Bn254>);

thread_local! {
    static SETUP: RefCell<Option<([u8; 32], Keys)>> = const { RefCell::new(None) };
}

fn seed32(seed: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let n = seed.len().min(32);
    out[..n].copy_from_slice(&seed[..n]);
    out
}

fn with_keys<T>(seed: &[u8], f: impl FnOnce(&Keys) -> T) -> Result<T, String> {
    let key = seed32(seed);
    SETUP.with(|cell| {
        let mut slot = cell.borrow_mut();
        let fresh = !matches!(slot.as_ref(), Some((s, _)) if *s == key);
        if fresh {
            let mut rng = ChaCha20Rng::from_seed(key);
            let keys = Groth16::<Bn254>::circuit_specific_setup(CubicCircuit { x: None }, &mut rng)
                .map_err(|e| format!("trusted setup failed: {e}"))?;
            *slot = Some((key, keys));
        }
        Ok(f(&slot.as_ref().expect("setup just populated").1))
    })
}

struct ZkGroth16;

impl Guest for ZkGroth16 {
    fn addon_id() -> String {
        "wasm.zk-groth16".into()
    }

    fn capabilities() -> Vec<String> {
        vec!["tools".into()]
    }

    fn tool_docs() -> Vec<ToolDoc> {
        let doc = |name: &str, description: &str| ToolDoc {
            name: name.into(),
            description: description.into(),
        };
        vec![
            doc("compute", "Return y = x^3 + x + 5, the public half of the statement."),
            doc(
                "prove",
                "Groth16-prove knowledge of a secret x with x^3 + x + 5 == y, revealing only y.",
            ),
            doc("verify", "Verify a Groth16 proof against the public input y."),
            doc(
                "probe-ambient",
                "Report which ambient host authorities (env, filesystem, clock) this guest can reach.",
            ),
        ]
    }

    fn health() -> Result<String, String> {
        Ok(format!("generation {GENERATION}"))
    }
}

impl Tools for ZkGroth16 {
    fn compute(x: u64) -> u64 {
        // Saturating, because a wrapped y would make `verify` fail for a reason
        // that has nothing to do with the proof.
        x.saturating_mul(x).saturating_mul(x).saturating_add(x).saturating_add(5)
    }

    fn prove(x: u64, seed: Vec<u8>) -> Result<Vec<u8>, String> {
        with_keys(&seed, |(pk, _)| {
            let mut rng = ChaCha20Rng::from_seed(seed32(&seed));
            let circuit = CubicCircuit { x: Some(Fr::from(x)) };
            let proof = Groth16::<Bn254>::prove(pk, circuit, &mut rng)
                .map_err(|e| format!("proving failed: {e}"))?;
            let mut bytes = Vec::new();
            proof
                .serialize_compressed(&mut bytes)
                .map_err(|e| format!("proof serialisation failed: {e}"))?;
            Ok(bytes)
        })?
    }

    fn verify(proof: Vec<u8>, y: u64, seed: Vec<u8>) -> Result<bool, String> {
        with_keys(&seed, |(_, vk)| {
            let proof = Proof::<Bn254>::deserialize_compressed(proof.as_slice())
                .map_err(|e| format!("proof deserialisation failed: {e}"))?;
            let pvk = Groth16::<Bn254>::process_vk(vk)
                .map_err(|e| format!("verifying-key preparation failed: {e}"))?;
            Groth16::<Bn254>::verify_with_processed_vk(&pvk, &[Fr::from(y)], &proof)
                .map_err(|e| format!("verification failed: {e}"))
        })?
    }

    fn echo_list() -> Result<Vec<String>, String> {
        Ok(vec!["alpha".into(), "beta".into()])
    }

    fn probe_one(which: u32) -> String {
        match which {
            0 => format!("env-vars={}", std::env::vars().count()),
            1 => format!("env-args={}", std::env::args().count()),
            2 => match std::fs::read_to_string("/etc/hostname") {
                Ok(s) => format!("fs-read=GRANTED({} bytes)", s.len()),
                Err(e) => format!("fs-read=denied({e})"),
            },
            3 => match std::fs::read_dir("/") {
                Ok(d) => format!("fs-list-root=GRANTED({} entries)", d.count()),
                Err(e) => format!("fs-list-root=denied({e})"),
            },
            4 => match std::fs::write("/tmp/hive-zk-escape", b"x") {
                Ok(()) => "fs-write=GRANTED".into(),
                Err(e) => format!("fs-write=denied({e})"),
            },
            5 => match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
                Ok(d) => format!("wall-clock=GRANTED({}s)", d.as_secs()),
                Err(e) => format!("wall-clock=denied({e})"),
            },
            n => format!("no such probe: {n}"),
        }
    }

    /// Only the authorities that FAIL SOFTLY belong here, which on
    /// wasm32-unknown-unknown is `env::args` and the whole of `std::fs`.
    ///
    /// `env::vars` and the wall clock are deliberately EXCLUDED: both panic on
    /// this target, and the release profile turns a panic into `unreachable`,
    /// so including either would abort the call and take the other four probes
    /// with it. Reach them one at a time through `probe-one` (5 is the clock,
    /// 0 is env-vars) when the trap itself is the thing being demonstrated.
    fn probe_ambient() -> Result<Vec<String>, String> {
        let mut seen = Vec::new();
        seen.push(format!("env-args={}", std::env::args().count()));
        seen.push(match std::fs::read_to_string("/etc/hostname") {
            Ok(s) => format!("fs-read=GRANTED({} bytes)", s.len()),
            Err(e) => format!("fs-read=denied({e})"),
        });
        seen.push(match std::fs::read_dir("/") {
            Ok(d) => format!("fs-list-root=GRANTED({} entries)", d.count()),
            Err(e) => format!("fs-list-root=denied({e})"),
        });
        seen.push(match std::fs::write("/tmp/hive-zk-escape", b"x") {
            Ok(()) => "fs-write=GRANTED".into(),
            Err(e) => format!("fs-write=denied({e})"),
        });
        Ok(seen)
    }

    /// Deliberately reaches for the wall clock, which on this target ABORTS the
    /// guest rather than returning an error: `std::time::SystemTime::now` has
    /// no implementation on wasm32-unknown-unknown and panics, and the release
    /// profile turns a panic into `unreachable`.
    ///
    /// It is exported so the capability boundary can be demonstrated rather
    /// than asserted. A caller that invokes this gets a trap, and the trap IS
    /// the evidence: the component holds no clock authority and cannot acquire
    /// one. The host survives; only the guest call dies.
    fn probe_clock() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }
}

export!(ZkGroth16);
