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
    assert_eq!(GithubActionsFrontend.frontend_generation(), 3);
    assert!(first.native_yaml.contains(
        "registry.example/runtrue-ci@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ));
    let report = first.report.unwrap();
    assert!(!report.bytes.is_empty());
}

#[test]
fn explicit_runtrue_files_remain_native_inside_the_github_directory() {
    assert!(GithubActionsFrontend.supports(".github/workflows/ci.yml"));
    assert!(!GithubActionsFrontend.supports(".github/workflows/release.runtrue.yml"));
    assert!(!GithubActionsFrontend.supports(".github/workflows/release.runtrue.yaml"));
}

#[test]
fn repository_actions_use_bounded_two_phase_resolution() {
    let source = format!(
        "on: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: owner/action@{}\n",
        "a".repeat(40)
    );
    let requests = GithubActionsFrontend
        .action_resolution_requests(&source, ".github/workflows/ci.yml")
        .unwrap();
    let request = requests.iter().next().unwrap();
    assert_eq!(request.repository(), "owner/action");
    assert_eq!(request.descriptor_candidates().len(), 3);

    let mut descriptors = runtrue_workflow_frontend::SourceActionDescriptors::for_request(request);
    descriptors
        .insert(
            "action.yml",
            b"name: action\ndescription: action\nruns:\n  using: docker\n  image: Dockerfile\n"
                .to_vec(),
        )
        .unwrap();
    let declaration = GithubActionsFrontend
        .parse_action_descriptor(request, &descriptors)
        .unwrap();
    assert_eq!(declaration.descriptor_path(), "action.yml");
    assert_eq!(
        descriptors.selected_descriptor(&declaration).unwrap(),
        descriptors.get("action.yml").unwrap()
    );
    assert!(matches!(
        declaration.program(),
        runtrue_workflow_frontend::SourceActionProgramDeclaration::ContainerBuild {
            build_file,
            ..
        } if build_file == "Dockerfile"
    ));
}

#[test]
fn descriptor_ambiguity_fails_closed() {
    let source = format!(
        "on: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: owner/action@{}\n",
        "a".repeat(40)
    );
    let requests = GithubActionsFrontend
        .action_resolution_requests(&source, ".github/workflows/ci.yml")
        .unwrap();
    let request = requests.iter().next().unwrap();
    let mut descriptors = runtrue_workflow_frontend::SourceActionDescriptors::for_request(request);
    for path in ["action.yml", "action.yaml"] {
        descriptors
            .insert(
                path,
                b"name: action\ndescription: action\nruns:\n  using: docker\n  image: Dockerfile\n"
                    .to_vec(),
            )
            .unwrap();
    }
    assert!(GithubActionsFrontend
        .parse_action_descriptor(request, &descriptors)
        .is_err());
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
