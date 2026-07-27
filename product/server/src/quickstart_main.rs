//! Frontend-owned, single-process Runtrue distribution.
//!
//! This target intentionally includes the GitHub Actions adapter, browser UI,
//! backend, and in-process control-plane workers. It is for quick starts and
//! low-environment deployments; the normal split artifacts remain available.

include!("main.rs");
