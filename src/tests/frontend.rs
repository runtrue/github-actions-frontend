use super::*;
use runtrue_workflow_frontend::{
    WorkflowFrontendErrorKind, WorkflowFrontendOptions, WorkflowSourceFrontend,
    WORKFLOW_FRONTEND_CONTRACT_GENERATION,
};

#[test]
fn github_frontend_is_deterministic_and_binds_translation_identity() {
    let source = "name: CI\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: cargo test\n";
    let mut options = WorkflowFrontendOptions::default();
    options
        .set(
            DEFAULT_JOB_CONTAINER_IMAGE_OPTION,
            format!("registry.example/runtrue-ci@sha256:{}", "a".repeat(64)),
        )
        .unwrap();
    assert_eq!(
        GithubActionsFrontend.discovery_roots(),
        &[".github/workflows"]
    );
    let first = GithubActionsFrontend
        .prepare(source, ".github/workflows/ci.yml", &options)
        .unwrap();
    let second = GithubActionsFrontend
        .prepare(source, ".github/workflows/ci.yml", &options)
        .unwrap();

    first.validate_for(source, &options).unwrap();
    second.validate_for(source, &options).unwrap();
    assert_eq!(first, second);
    assert_eq!(
        first.contract_generation,
        WORKFLOW_FRONTEND_CONTRACT_GENERATION
    );
    assert_eq!(first.configuration_digest, options.digest());
    assert!(first.native_yaml.contains(
        "registry.example/runtrue-ci@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ));
    assert_eq!(
        first.input_digest,
        runtrue_model::ContentDigest::sha256(source)
    );
    assert_eq!(
        first.native_digest,
        runtrue_model::ContentDigest::sha256(first.native_yaml.as_bytes())
    );
    let report = first.report.unwrap();
    assert_eq!(
        report.digest,
        runtrue_model::ContentDigest::sha256(&report.bytes)
    );
}

#[test]
fn github_frontend_fails_closed_on_blocking_semantics() {
    let source = "name: unsafe\non: [push]\njobs:\n  deploy:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: unknown/remote-action@main\n";
    let error = GithubActionsFrontend
        .prepare(
            source,
            ".github/workflows/deploy.yml",
            &WorkflowFrontendOptions::default(),
        )
        .unwrap_err();
    assert_eq!(error.kind(), WorkflowFrontendErrorKind::IncompatibleSource);
    assert_eq!(error.code(), "github-actions.incompatible-source");
    assert!(!error.detail().is_empty());
}
