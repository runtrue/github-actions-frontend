use super::*;
use runtrue_workflow_frontend::{
    WorkflowFrontendErrorKind, WorkflowFrontendOptions, WorkflowSourceFrontend,
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

    assert_eq!(first, second);
    assert_eq!(
        GithubActionsFrontend.frontend_id(),
        "runtrue.github-actions"
    );
    assert_eq!(GithubActionsFrontend.frontend_generation(), 2);
    assert!(first.native_yaml.contains(
        "registry.example/runtrue-ci@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ));
    let report = first.report.unwrap();
    assert!(!report.bytes.is_empty());
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
