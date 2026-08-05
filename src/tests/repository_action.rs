use super::*;

#[test]
fn accepts_minimal_root_docker_action_metadata() {
    let source = br#"
name: Runtrue Backport
description: Reconcile backports
author: Runtrue
inputs:
  config-path:
    description: Trusted policy path
    required: false
    default: .github/backport.yml
runs:
  using: docker
  image: Dockerfile
  entrypoint: /bin/action
  args: ["--config", "${{ inputs.config-path }}"]
branding:
  icon: git-pull-request
  color: blue
"#;
    let metadata = parse_repository_action_metadata(source).unwrap();
    assert_eq!(metadata.dockerfile, "Dockerfile");
    assert_eq!(metadata.entrypoint.as_deref(), Some("/bin/action"));
    assert_eq!(
        metadata.args.as_deref(),
        Some(
            [
                "--config".to_owned(),
                "${{ inputs.config-path }}".to_owned()
            ]
            .as_slice()
        )
    );
    assert_eq!(
        metadata.inputs["config-path"].default_value(),
        Some(".github/backport.yml")
    );
    assert_eq!(
        metadata.digest,
        runtrue_model::ContentDigest::sha256(source)
    );
}

#[test]
fn metadata_rejects_non_docker_and_escaping_or_remote_images() {
    for runs in [
        "using: node20\n  image: Dockerfile",
        "using: docker\n  image: ../Dockerfile",
        "using: docker\n  image: /Dockerfile",
        "using: docker\n  image: docker://registry.example/action:latest",
    ] {
        let source = format!("name: action\ndescription: action description\nruns:\n  {runs}\n");
        assert!(parse_repository_action_metadata(source.as_bytes()).is_err());
    }
}

#[test]
fn metadata_rejects_unknown_fields_and_duplicate_keys() {
    for source in [
        "name: action\ndescription: action\nruns: { using: docker, image: Dockerfile }\nunknown: true\n",
        "name: action\nname: changed\ndescription: action\nruns: { using: docker, image: Dockerfile }\n",
        "name: action\ndescription: action\nruns: { using: docker, image: Dockerfile, env: { BAD: value } }\n",
    ] {
        assert!(parse_repository_action_metadata(source.as_bytes()).is_err());
    }
}

#[test]
fn accepts_exact_runtrue_component_metadata() {
    let source = format!(
        r#"name: Runtrue Backport
description: Reconcile backports in a component
inputs:
  config-path:
    description: Trusted policy path
    default: .github/backport.yml
runs:
  using: wasm
  component: wasm://ghcr.io/runtrue/backport@sha256:{}
  signature-identity: release@runtrue.dev
  wit-world: runtrue:action/run@1.0.0
"#,
        "a".repeat(64)
    );
    let metadata = parse_runtrue_repository_action_metadata(source.as_bytes()).unwrap();
    assert!(matches!(
        metadata.program,
        RuntrueRepositoryActionProgram::Component {
            signature_identity,
            wit_world,
            ..
        } if signature_identity == "release@runtrue.dev"
            && wit_world == "runtrue:action/run@1.0.0"
    ));
    assert_eq!(
        metadata.inputs["config-path"].default_value(),
        Some(".github/backport.yml")
    );
}

#[test]
fn accepts_runtrue_docker_action_runtime_requirements() {
    let source = br#"name: AI review
description: Review a pull request
inputs:
  github-token:
    description: Scoped provider token
    required: true
runs:
  using: docker
  image: Dockerfile
permissions:
  network:
    - host: api.example.test
      port: 443
  secrets:
    - name: API_KEY
      purpose: inference
      file-env: INPUT_API_KEY_FILE
"#;
    let metadata = parse_runtrue_repository_action_metadata(source).unwrap();
    assert!(matches!(
        metadata.program,
        RuntrueRepositoryActionProgram::Container { ref dockerfile, .. }
            if dockerfile == "Dockerfile"
    ));
    assert_eq!(metadata.network[0].host, "api.example.test");
    assert_eq!(metadata.network[0].port, 443);
    assert_eq!(metadata.secrets[0].name, "API_KEY");
    assert_eq!(metadata.secrets[0].purpose, "inference");
    assert_eq!(metadata.secrets[0].file_env, "INPUT_API_KEY_FILE");
}
