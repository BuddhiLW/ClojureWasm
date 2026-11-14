//! Groth16 zkSNARK functions for clojurust, registered as the `zk` namespace.
//!
//! | Symbol | Signature | Description |
//! |---|---|---|
//! | `zk/compute` | `(compute x)` | `y = x^3 + x + 5`, the public half |
//! | `zk/prove` | `(prove x seed)` | Proof that the caller knows `x`, as a byte vector |
//! | `zk/verify` | `(verify proof y seed)` | Check a proof against public `y` |
//! | `zk/ambient` | `(ambient)` | What host authority this code actually holds |
//!
//! The circuit and the arkworks feature set are identical to the Wasm guest in
//! `../../zk-groth16/guest`. `zk/ambient` is the function whose
//! answer DIFFERS between the two, and that difference is the whole point.

use std::sync::Mutex;

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

use cljrs_interop::{IntoValue, Registry, Value, wrap_fn0, wrap_fn1, wrap_fn2, wrap_fn3};

/// `x^3 + x + 5 == y`, with `x` private and `y` public. Three R1CS constraints.
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

type Keys = (ProvingKey<Bn254>, VerifyingKey<Bn254>);

/// The setup is deterministic in the seed, so both `prove` and `verify`
/// regenerate it rather than marshalling a proving key through Clojure.
/// `Mutex` rather than the guest's `thread_local`: cljrs is genuinely
/// multi-threaded, which is one of the real differences between the two hosts.
static SETUP: Mutex<Option<([u8; 32], Keys)>> = Mutex::new(None);

fn seed32(seed: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    let n = seed.len().min(32);
    out[..n].copy_from_slice(&seed[..n]);
    out
}

/// Accepts a Clojure vector of integers 0..=255, the same shape the Wasm side
/// receives as `list<u8>`.
fn to_bytes(v: &Value) -> Result<Vec<u8>, String> {
    match v {
        Value::Vector(vec) => {
            let mut bytes = Vec::with_capacity(vec.get().count());
            for elem in vec.get().iter() {
                match elem {
                    Value::Long(n) if (0..=255).contains(n) => bytes.push(*n as u8),
                    Value::Long(n) => return Err(format!("byte out of range 0-255: {n}")),
                    other => {
                        return Err(format!(
                            "byte vector must contain integers 0-255, got {}",
                            other.type_name()
                        ));
                    }
                }
            }
            Ok(bytes)
        }
        other => Err(format!("expected a byte vector, got {}", other.type_name())),
    }
}

fn to_byte_vec(bytes: &[u8]) -> Vec<Value> {
    bytes.iter().map(|b| Value::Long(*b as i64)).collect()
}

fn with_keys<T>(seed: &[u8], f: impl FnOnce(&Keys) -> T) -> Result<T, String> {
    let key = seed32(seed);
    let mut slot = SETUP.lock().map_err(|_| "setup lock poisoned".to_string())?;
    let fresh = !matches!(slot.as_ref(), Some((s, _)) if *s == key);
    if fresh {
        let mut rng = ChaCha20Rng::from_seed(key);
        let keys = Groth16::<Bn254>::circuit_specific_setup(CubicCircuit { x: None }, &mut rng)
            .map_err(|e| format!("trusted setup failed: {e}"))?;
        *slot = Some((key, keys));
    }
    Ok(f(&slot.as_ref().expect("setup just populated").1))
}

pub fn register(registry: &mut Registry) {
    registry.define(
        "zk/compute",
        wrap_fn1("zk/compute", |x: i64| -> Result<i64, String> {
            Ok(x.saturating_mul(x).saturating_mul(x).saturating_add(x).saturating_add(5))
        }),
    );

    registry.define(
        "zk/prove",
        wrap_fn2("zk/prove", |x: i64, seed: Value| -> Result<Vec<Value>, String> {
            let seed = to_bytes(&seed)?;
            let x = u64::try_from(x).map_err(|_| "x must be non-negative".to_string())?;
            with_keys(&seed, |(pk, _)| {
                let mut rng = ChaCha20Rng::from_seed(seed32(&seed));
                let circuit = CubicCircuit { x: Some(Fr::from(x)) };
                let proof = Groth16::<Bn254>::prove(pk, circuit, &mut rng)
                    .map_err(|e| format!("proving failed: {e}"))?;
                let mut bytes = Vec::new();
                proof
                    .serialize_compressed(&mut bytes)
                    .map_err(|e| format!("proof serialisation failed: {e}"))?;
                Ok(to_byte_vec(&bytes))
            })?
        }),
    );

    registry.define(
        "zk/verify",
        wrap_fn3(
            "zk/verify",
            |proof: Value, y: i64, seed: Value| -> Result<bool, String> {
                let seed = to_bytes(&seed)?;
                let proof_bytes = to_bytes(&proof)?;
                let y = u64::try_from(y).map_err(|_| "y must be non-negative".to_string())?;
                with_keys(&seed, |(_, vk)| {
                    let proof = Proof::<Bn254>::deserialize_compressed(proof_bytes.as_slice())
                        .map_err(|e| format!("proof deserialisation failed: {e}"))?;
                    let pvk = Groth16::<Bn254>::process_vk(vk)
                        .map_err(|e| format!("verifying-key preparation failed: {e}"))?;
                    Groth16::<Bn254>::verify_with_processed_vk(&pvk, &[Fr::from(y)], &proof)
                        .map_err(|e| format!("verification failed: {e}"))
                })?
            },
        ),
    );

    // The contrast function. On the Wasm guest the filesystem answers
    // "operation not supported" and the clock ABORTS the call; here every one
    // of these succeeds, because a native dylib inherits the whole authority of
    // the cljrs process.
    registry.define(
        "zk/ambient",
        wrap_fn0("zk/ambient", || -> Result<Vec<Value>, String> {
            let mut seen: Vec<Value> = Vec::new();
            seen.push(format!("env-vars={}", std::env::vars().count()).into_value());
            seen.push(
                match std::fs::read_to_string("/etc/hostname") {
                    Ok(s) => format!("fs-read=GRANTED({} bytes)", s.trim().len()),
                    Err(e) => format!("fs-read=denied({e})"),
                }
                .into_value(),
            );
            seen.push(
                match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
                    Ok(d) => format!("wall-clock=GRANTED({}s)", d.as_secs()),
                    Err(e) => format!("wall-clock=denied({e})"),
                }
                .into_value(),
            );
            Ok(seen)
        }),
    );

    registry.env().mark_loaded("zk");
}

/// C-ABI entry point loaded by `cljrs build-native` / `cljrs run`.
///
/// # Safety
/// `registry` must be a valid, non-null `*mut Registry`, uniquely borrowed for
/// the duration of the call. The cljrs CLI satisfies both.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cljrs_init(registry: *mut Registry) {
    register(unsafe { &mut *registry });
}
