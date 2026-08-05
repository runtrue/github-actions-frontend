use crate::{strict_yaml::validate_strict_yaml, validation::safe_relative_path, ImportError};
use runtrue_model::ContentDigest;
use runtrue_workflow_frontend::ResolvedActionInput;
use serde::Deserialize;
use serde_yaml::Value as YamlValue;
use std::collections::BTreeMap;

const MAX_ACTION_METADATA_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryActionMetadata {
    pub digest: ContentDigest,
    pub dockerfile: String,
    pub inputs: BTreeMap<String, ResolvedActionInput>,
    pub entrypoint: Option<String>,
    pub args: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntrueRepositoryActionMetadata {
    pub digest: ContentDigest,
    pub inputs: BTreeMap<String, ResolvedActionInput>,
    pub program: RuntrueRepositoryActionProgram,
    pub network: Vec<RepositoryActionNetworkDestination>,
    pub secrets: Vec<RepositoryActionSecret>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntrueRepositoryActionProgram {
    Container {
        dockerfile: String,
        entrypoint: Option<String>,
        args: Option<Vec<String>>,
    },
    Component {
        component: String,
        signature_identity: String,
        wit_world: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryActionNetworkDestination {
    pub host: String,
    pub port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepositoryActionSecret {
    pub name: String,
    pub purpose: String,
    pub file_env: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActionMetadata {
    name: String,
    description: String,
    #[serde(default)]
    author: Option<String>,
    #[serde(default)]
    inputs: BTreeMap<String, ActionInput>,
    #[serde(default)]
    outputs: BTreeMap<String, ActionOutput>,
    runs: ActionRuns,
    #[serde(default)]
    branding: Option<ActionBranding>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct ActionInput {
    description: String,
    #[serde(default)]
    required: bool,
    #[serde(default)]
    default: Option<YamlValue>,
    #[serde(default)]
    deprecation_message: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActionOutput {
    description: String,
    #[serde(default)]
    value: Option<YamlValue>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActionRuns {
    using: String,
    image: String,
    #[serde(default)]
    entrypoint: Option<String>,
    #[serde(default)]
    args: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ActionBranding {
    icon: String,
    color: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RuntrueActionMetadata {
    name: String,
    description: String,
    #[serde(default)]
    inputs: BTreeMap<String, ActionInput>,
    runs: RuntrueActionRuns,
    #[serde(default)]
    permissions: RuntrueActionPermissions,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct RuntrueActionRuns {
    using: String,
    #[serde(default)]
    image: Option<String>,
    #[serde(default)]
    entrypoint: Option<String>,
    #[serde(default)]
    args: Option<Vec<String>>,
    #[serde(default)]
    component: Option<String>,
    #[serde(default)]
    signature_identity: Option<String>,
    #[serde(default)]
    wit_world: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RuntrueActionPermissions {
    #[serde(default)]
    network: Vec<RuntrueNetworkDestination>,
    #[serde(default)]
    secrets: Vec<RuntrueSecret>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RuntrueNetworkDestination {
    host: String,
    port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "kebab-case", deny_unknown_fields)]
struct RuntrueSecret {
    name: String,
    purpose: String,
    file_env: String,
}

pub fn parse_runtrue_repository_action_metadata(
    bytes: &[u8],
) -> Result<RuntrueRepositoryActionMetadata, ImportError> {
    if bytes.len() > MAX_ACTION_METADATA_BYTES {
        return Err(ImportError::RepositoryActionMetadata(
            "Runtrue action metadata exceeds the 256 KiB limit".to_owned(),
        ));
    }
    let source = std::str::from_utf8(bytes).map_err(|_| {
        ImportError::RepositoryActionMetadata("Runtrue action metadata is not UTF-8".to_owned())
    })?;
    validate_strict_yaml(source)?;
    let metadata: RuntrueActionMetadata = serde_yaml::from_str(source)?;
    validate_text("name", &metadata.name)?;
    validate_text("description", &metadata.description)?;
    let inputs = parse_inputs(&metadata.inputs)?;
    let program = match metadata.runs.using.as_str() {
        "docker" => {
            if metadata.runs.component.is_some()
                || metadata.runs.signature_identity.is_some()
                || metadata.runs.wit_world.is_some()
            {
                return Err(ImportError::RepositoryActionMetadata(
                    "Docker actions cannot declare Wasm component fields".to_owned(),
                ));
            }
            let dockerfile = metadata.runs.image.ok_or_else(|| {
                ImportError::RepositoryActionMetadata(
                    "Docker actions require runs.image".to_owned(),
                )
            })?;
            validate_docker_program(
                &dockerfile,
                metadata.runs.entrypoint.as_deref(),
                metadata.runs.args.as_deref(),
            )?;
            RuntrueRepositoryActionProgram::Container {
                dockerfile,
                entrypoint: metadata.runs.entrypoint,
                args: metadata.runs.args,
            }
        }
        "wasm" => {
            if metadata.runs.image.is_some()
                || metadata.runs.entrypoint.is_some()
                || metadata.runs.args.is_some()
                || !metadata.permissions.network.is_empty()
                || !metadata.permissions.secrets.is_empty()
            {
                return Err(ImportError::RepositoryActionMetadata(
                    "Wasm actions cannot declare Docker fields or OCI runtime permissions"
                        .to_owned(),
                ));
            }
            let component = metadata.runs.component.ok_or_else(|| {
                ImportError::RepositoryActionMetadata(
                    "Wasm actions require runs.component".to_owned(),
                )
            })?;
            if !crate::validation::is_exact_wasm_component(&component) {
                return Err(ImportError::RepositoryActionMetadata(
                    "runs.component must be an exact wasm://...@sha256:<digest> reference"
                        .to_owned(),
                ));
            }
            let signature_identity = metadata.runs.signature_identity.ok_or_else(|| {
                ImportError::RepositoryActionMetadata(
                    "Wasm actions require runs.signature-identity".to_owned(),
                )
            })?;
            validate_text("runs.signature-identity", &signature_identity)?;
            let wit_world = metadata.runs.wit_world.ok_or_else(|| {
                ImportError::RepositoryActionMetadata(
                    "Wasm actions require runs.wit-world".to_owned(),
                )
            })?;
            if wit_world != "runtrue:action/run@1.0.0" {
                return Err(ImportError::RepositoryActionMetadata(
                    "runs.wit-world is not supported by this runtime generation".to_owned(),
                ));
            }
            RuntrueRepositoryActionProgram::Component {
                component,
                signature_identity,
                wit_world,
            }
        }
        _ => {
            return Err(ImportError::RepositoryActionMetadata(
                "runtrue-action.yml requires runs.using: docker or wasm".to_owned(),
            ));
        }
    };
    let network = parse_network_permissions(&metadata.permissions.network)?;
    let secrets = parse_secret_permissions(&metadata.permissions.secrets)?;
    Ok(RuntrueRepositoryActionMetadata {
        digest: ContentDigest::sha256(bytes),
        inputs,
        program,
        network,
        secrets,
    })
}

pub fn parse_repository_action_metadata(
    bytes: &[u8],
) -> Result<RepositoryActionMetadata, ImportError> {
    if bytes.len() > MAX_ACTION_METADATA_BYTES {
        return Err(ImportError::RepositoryActionMetadata(
            "action metadata exceeds the 256 KiB limit".to_owned(),
        ));
    }
    let source = std::str::from_utf8(bytes).map_err(|_| {
        ImportError::RepositoryActionMetadata("action metadata is not UTF-8".to_owned())
    })?;
    validate_strict_yaml(source)?;
    let metadata: ActionMetadata = serde_yaml::from_str(source)?;
    validate_text("name", &metadata.name)?;
    validate_text("description", &metadata.description)?;
    if let Some(author) = &metadata.author {
        validate_text("author", author)?;
    }
    let inputs = parse_inputs(&metadata.inputs)?;
    for (name, output) in &metadata.outputs {
        validate_identifier("output", name)?;
        validate_text("output description", &output.description)?;
        let _ = &output.value;
    }
    if let Some(branding) = &metadata.branding {
        validate_text("branding icon", &branding.icon)?;
        validate_text("branding color", &branding.color)?;
    }
    if metadata.runs.using != "docker" {
        return Err(ImportError::RepositoryActionMetadata(
            "only runs.using: docker repository actions are supported".to_owned(),
        ));
    }
    validate_docker_program(
        &metadata.runs.image,
        metadata.runs.entrypoint.as_deref(),
        metadata.runs.args.as_deref(),
    )?;
    Ok(RepositoryActionMetadata {
        digest: ContentDigest::sha256(bytes),
        dockerfile: metadata.runs.image,
        inputs,
        entrypoint: metadata.runs.entrypoint,
        args: metadata.runs.args,
    })
}

fn validate_docker_program(
    image: &str,
    entrypoint: Option<&str>,
    args: Option<&[String]>,
) -> Result<(), ImportError> {
    if let Some(entrypoint) = entrypoint {
        validate_text("runs.entrypoint", entrypoint)?;
    }
    if let Some(args) = args {
        if args.is_empty() || args.len() > 256 {
            return Err(ImportError::RepositoryActionMetadata(
                "runs.args must contain between 1 and 256 arguments".to_owned(),
            ));
        }
        for argument in args {
            if argument.len() > 8 * 1024 || argument.contains('\0') {
                return Err(ImportError::RepositoryActionMetadata(
                    "runs.args contains an invalid argument".to_owned(),
                ));
            }
        }
    }
    if !safe_relative_path(image, false)
        || image.starts_with("docker://")
        || !image.rsplit('/').next().is_some_and(|name| {
            name.eq_ignore_ascii_case("Dockerfile") || name.ends_with(".Dockerfile")
        })
    {
        return Err(ImportError::RepositoryActionMetadata(
            "runs.image must name a repository-relative Dockerfile".to_owned(),
        ));
    }
    Ok(())
}

fn parse_network_permissions(
    declared: &[RuntrueNetworkDestination],
) -> Result<Vec<RepositoryActionNetworkDestination>, ImportError> {
    declared
        .iter()
        .map(|destination| {
            let resolved = runtrue_workflow_frontend::ResolvedActionNetworkDestination::new(
                destination.host.clone(),
                destination.port,
            )
            .map_err(|error| ImportError::RepositoryActionMetadata(error.to_string()))?;
            Ok(RepositoryActionNetworkDestination {
                host: resolved.host().to_owned(),
                port: resolved.port(),
            })
        })
        .collect()
}

fn parse_secret_permissions(
    declared: &[RuntrueSecret],
) -> Result<Vec<RepositoryActionSecret>, ImportError> {
    declared
        .iter()
        .map(|secret| {
            let resolved = runtrue_workflow_frontend::ResolvedActionSecret::new(
                secret.name.clone(),
                secret.purpose.clone(),
                secret.file_env.clone(),
            )
            .map_err(|error| ImportError::RepositoryActionMetadata(error.to_string()))?;
            Ok(RepositoryActionSecret {
                name: resolved.name().to_owned(),
                purpose: resolved.purpose().to_owned(),
                file_env: resolved.file_env().to_owned(),
            })
        })
        .collect()
}

fn parse_inputs(
    declared: &BTreeMap<String, ActionInput>,
) -> Result<BTreeMap<String, ResolvedActionInput>, ImportError> {
    let mut inputs = BTreeMap::new();
    for (name, input) in declared {
        validate_identifier("input", name)?;
        validate_text("input description", &input.description)?;
        if let Some(message) = &input.deprecation_message {
            validate_text("input deprecation message", message)?;
        }
        let default = input.default.as_ref().map(action_scalar_text).transpose()?;
        inputs.insert(
            name.clone(),
            ResolvedActionInput::new(input.required, default)
                .map_err(|error| ImportError::RepositoryActionMetadata(error.to_string()))?,
        );
    }
    Ok(inputs)
}

fn action_scalar_text(value: &YamlValue) -> Result<String, ImportError> {
    let text = match value {
        YamlValue::String(value) => value.clone(),
        YamlValue::Bool(value) => value.to_string(),
        YamlValue::Number(value) => value.to_string(),
        _ => {
            return Err(ImportError::RepositoryActionMetadata(
                "input defaults must be scalar strings, booleans, or numbers".to_owned(),
            ));
        }
    };
    if text.len() > 8 * 1024 || text.contains('\0') {
        return Err(ImportError::RepositoryActionMetadata(
            "input default is invalid".to_owned(),
        ));
    }
    Ok(text)
}

fn validate_text(field: &str, value: &str) -> Result<(), ImportError> {
    if value.is_empty() || value.len() > 8 * 1024 || value.chars().any(char::is_control) {
        return Err(ImportError::RepositoryActionMetadata(format!(
            "{field} is empty or invalid"
        )));
    }
    Ok(())
}

fn validate_identifier(field: &str, value: &str) -> Result<(), ImportError> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ImportError::RepositoryActionMetadata(format!(
            "{field} name is invalid"
        )));
    }
    Ok(())
}
