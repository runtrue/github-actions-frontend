//! Strict, fail-closed GitHub Actions compatibility analysis and import.
//!
//! This crate is deliberately a front end. It does not add GitHub semantics to
//! Runtrue's native model: a source construct is converted to native workflow
//! syntax, called out as an emulation, or reported as a blocking incompatibility.

mod analyzer;
mod error;
mod github;
mod native;
mod provider;
mod report;
mod repository_action;
mod source;
mod strict_yaml;
mod validation;

use analyzer::Analyzer;
use github::GithubWorkflow;
#[cfg(test)]
use runtrue_workflow_ast as ast;
use runtrue_workflow_frontend::{
    PreparedWorkflowSource, ResolvedActionNetworkDestination, ResolvedActionSecret,
    SourceActionDeclaration, SourceActionDescriptors, SourceActionProgramDeclaration,
    SourceActionResolutionRequest, SourceActionResolutionRequests, WorkflowFrontendError,
    WorkflowFrontendErrorKind, WorkflowFrontendOptions, WorkflowFrontendReport,
    WorkflowSourceFrontend,
};
use strict_yaml::validate_strict_yaml;

pub use error::ImportError;
pub use provider::*;
pub use report::{
    CompatibilityFinding, CompatibilityReport, CompatibilityStatus, ImportResult, StatusCounts,
};
pub use repository_action::{
    parse_repository_action_metadata, parse_runtrue_repository_action_metadata,
    RepositoryActionMetadata, RuntrueRepositoryActionMetadata, RuntrueRepositoryActionProgram,
};
pub use source::*;

/// Generic frontend option understood by the GitHub Actions adapter.
pub const DEFAULT_JOB_CONTAINER_IMAGE_OPTION: &str =
    "runtrue.github-actions.default-job-container-image";

/// GitHub Actions source adapter. Composition roots register this as one
/// frontend; the trusted planner depends only on the neutral frontend API.
#[derive(Debug, Clone, Copy, Default)]
pub struct GithubActionsFrontend;

impl WorkflowSourceFrontend for GithubActionsFrontend {
    fn frontend_id(&self) -> &'static str {
        "runtrue.github-actions"
    }

    fn frontend_generation(&self) -> u32 {
        4
    }

    fn discovery_roots(&self) -> &'static [&'static str] {
        &[".github/workflows"]
    }

    fn supports(&self, workflow_path: &str) -> bool {
        let explicitly_native =
            workflow_path.ends_with(".runtrue.yml") || workflow_path.ends_with(".runtrue.yaml");
        !explicitly_native
            && (workflow_path.starts_with(".github/workflows/")
                || workflow_path.ends_with(".github.yml")
                || workflow_path.ends_with(".github.yaml"))
    }

    fn action_resolution_requests(
        &self,
        source: &str,
        _workflow_path: &str,
    ) -> Result<SourceActionResolutionRequests, WorkflowFrontendError> {
        let references =
            pinned_repository_action_references(source).map_err(frontend_source_error)?;
        let mut requests = SourceActionResolutionRequests::default();
        for source_reference in references {
            let (repository, revision) = source_reference.rsplit_once('@').ok_or_else(|| {
                frontend_invalid_source("repository action reference has no exact revision")
            })?;
            let request = SourceActionResolutionRequest::new(
                source_reference.clone(),
                repository,
                revision,
                "",
                vec![
                    "runtrue-action.yml".to_owned(),
                    "action.yml".to_owned(),
                    "action.yaml".to_owned(),
                ],
            )
            .map_err(|error| frontend_invalid_source(error.to_string()))?;
            requests
                .insert(request)
                .map_err(|error| frontend_invalid_source(error.to_string()))?;
        }
        Ok(requests)
    }

    fn parse_action_descriptor(
        &self,
        request: &SourceActionResolutionRequest,
        descriptors: &SourceActionDescriptors,
    ) -> Result<SourceActionDeclaration, WorkflowFrontendError> {
        let mut present = descriptors.iter();
        let Some((descriptor_path, bytes)) = present.next() else {
            return Err(frontend_invalid_source(
                "repository action has no supported descriptor",
            ));
        };
        if present.next().is_some() {
            return Err(frontend_invalid_source(
                "repository action has ambiguous descriptors",
            ));
        }

        let (mut declaration, inputs, network, secrets) =
            if descriptor_path == "runtrue-action.yml" {
                let metadata = parse_runtrue_repository_action_metadata(bytes)
                    .map_err(frontend_source_error)?;
                let program = match metadata.program {
                    RuntrueRepositoryActionProgram::Container {
                        dockerfile,
                        entrypoint,
                        args,
                    } => SourceActionProgramDeclaration::ContainerBuild {
                        build_file: dockerfile,
                        entrypoint,
                        arguments: args,
                    },
                    RuntrueRepositoryActionProgram::Component {
                        component,
                        signature_identity,
                        wit_world,
                    } => SourceActionProgramDeclaration::Component {
                        reference: component,
                        signature_identity,
                        interface: wit_world,
                    },
                };
                SourceActionDeclaration::new(request.source_reference(), descriptor_path, program)
                    .map(|declaration| {
                        (
                            declaration,
                            metadata.inputs,
                            metadata.network,
                            metadata.secrets,
                        )
                    })
            } else {
                let metadata =
                    parse_repository_action_metadata(bytes).map_err(frontend_source_error)?;
                SourceActionDeclaration::new(
                    request.source_reference(),
                    descriptor_path,
                    SourceActionProgramDeclaration::ContainerBuild {
                        build_file: metadata.dockerfile,
                        entrypoint: metadata.entrypoint,
                        arguments: metadata.args,
                    },
                )
                .map(|declaration| (declaration, metadata.inputs, Vec::new(), Vec::new()))
            }
            .map_err(|error| frontend_invalid_source(error.to_string()))?;

        for (name, input) in inputs {
            declaration
                .insert_input(name, input)
                .map_err(|error| frontend_invalid_source(error.to_string()))?;
        }
        for destination in network {
            declaration
                .insert_network_destination(
                    ResolvedActionNetworkDestination::new(destination.host, destination.port)
                        .map_err(|error| frontend_invalid_source(error.to_string()))?,
                )
                .map_err(|error| frontend_invalid_source(error.to_string()))?;
        }
        for secret in secrets {
            declaration
                .insert_secret(
                    ResolvedActionSecret::new(secret.name, secret.purpose, secret.file_env)
                        .map_err(|error| frontend_invalid_source(error.to_string()))?,
                )
                .map_err(|error| frontend_invalid_source(error.to_string()))?;
        }
        Ok(declaration)
    }

    fn prepare(
        &self,
        source: &str,
        workflow_path: &str,
        options: &WorkflowFrontendOptions,
    ) -> Result<PreparedWorkflowSource, WorkflowFrontendError> {
        let imported = import_github_actions_with_options(source, workflow_path, options.clone())
            .map_err(frontend_source_error)?;
        let native_yaml = imported.native_yaml.ok_or_else(|| {
            let blockers = imported
                .report
                .findings
                .iter()
                .filter(|finding| finding.is_blocking())
                .map(|finding| finding.code.as_str())
                .take(8)
                .collect::<Vec<_>>()
                .join(", ");
            WorkflowFrontendError::new(
                WorkflowFrontendErrorKind::IncompatibleSource,
                "github-actions.incompatible-source",
                if blockers.is_empty() {
                    "compatibility analysis produced no executable workflow".to_owned()
                } else {
                    blockers
                },
            )
        })?;
        let report_bytes = serde_json::to_vec(&imported.report).map_err(|error| {
            WorkflowFrontendError::new(
                WorkflowFrontendErrorKind::Internal,
                "github-actions.report-encoding-failed",
                error.to_string(),
            )
        })?;
        Ok(PreparedWorkflowSource {
            native_yaml,
            generated_lockfile_toml: imported.lockfile_toml,
            report: Some(WorkflowFrontendReport {
                media_type: "application/vnd.runtrue.github-actions-compatibility+json".to_owned(),
                bytes: report_bytes,
            }),
        })
    }
}

fn frontend_source_error(error: ImportError) -> WorkflowFrontendError {
    frontend_invalid_source(error.to_string())
}

fn frontend_invalid_source(detail: impl Into<String>) -> WorkflowFrontendError {
    WorkflowFrontendError::new(
        WorkflowFrontendErrorKind::InvalidSource,
        "github-actions.invalid-source",
        detail,
    )
}

/// Maximum accepted GitHub Actions workflow source size.
pub const MAX_GITHUB_WORKFLOW_BYTES: usize = 1024 * 1024;

pub fn import_github_actions(
    source: &str,
    source_name: impl Into<String>,
) -> Result<ImportResult, ImportError> {
    import_github_actions_with_options(source, source_name, WorkflowFrontendOptions::default())
}

#[cfg(test)]
fn import_github_actions_with_default_job_container_image(
    source: &str,
    source_name: impl Into<String>,
    default_job_container_image: Option<String>,
) -> Result<ImportResult, ImportError> {
    let mut options = WorkflowFrontendOptions::default();
    if let Some(image) = default_job_container_image {
        options
            .set(DEFAULT_JOB_CONTAINER_IMAGE_OPTION, image)
            .map_err(|error| ImportError::GeneratedWorkflow(error.to_string()))?;
    }
    import_github_actions_with_options(source, source_name, options)
}

pub fn import_github_actions_with_options(
    source: &str,
    source_name: impl Into<String>,
    options: WorkflowFrontendOptions,
) -> Result<ImportResult, ImportError> {
    if source.len() > MAX_GITHUB_WORKFLOW_BYTES {
        return Err(ImportError::TooLarge);
    }
    validate_strict_yaml(source)?;
    let workflow: GithubWorkflow = serde_yaml::from_str(source)?;
    Analyzer::new(source_name.into(), options).analyze(workflow)
}

pub fn pinned_repository_action_references(source: &str) -> Result<Vec<String>, ImportError> {
    if source.len() > MAX_GITHUB_WORKFLOW_BYTES {
        return Err(ImportError::TooLarge);
    }
    validate_strict_yaml(source)?;
    let workflow: GithubWorkflow = serde_yaml::from_str(source)?;
    let mut references = std::collections::BTreeSet::new();
    for job in workflow.jobs.values() {
        for step in &job.steps {
            let Some(reference) = step.uses.as_ref().and_then(serde_yaml::Value::as_str) else {
                continue;
            };
            let Some((action, selector)) = reference.rsplit_once('@') else {
                continue;
            };
            let normalized = action.to_ascii_lowercase();
            if matches!(
                normalized.as_str(),
                "actions/checkout"
                    | "actions/cache"
                    | "actions/cache/restore"
                    | "actions/cache/save"
                    | "actions/upload-artifact"
                    | "actions/download-artifact"
                    | "docker/build-push-action"
                    | "docker/setup-buildx-action"
            ) || !validation::is_full_git_commit(selector)
                || !analyzer::is_canonical_repository_action(action)
            {
                continue;
            }
            references.insert(reference.to_owned());
        }
    }
    Ok(references.into_iter().collect())
}

#[cfg(test)]
mod tests;
