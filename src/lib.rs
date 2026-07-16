//! Strict, fail-closed GitHub Actions compatibility analysis and import.
//!
//! This crate is deliberately a front end. It does not add GitHub semantics to
//! Runtrue's native model: a source construct is converted to native workflow
//! syntax, called out as an emulation, or reported as a blocking incompatibility.

mod analyzer;
mod error;
mod github;
mod native;
mod report;
mod strict_yaml;
mod validation;

use analyzer::Analyzer;
use github::GithubWorkflow;
#[cfg(test)]
use runtrue_workflow_ast as ast;
use runtrue_workflow_frontend::{
    PreparedWorkflowSource, WorkflowFrontendError, WorkflowFrontendErrorKind,
    WorkflowFrontendOptions, WorkflowFrontendReport, WorkflowSourceFrontend,
};
use strict_yaml::validate_strict_yaml;

pub use error::ImportError;
pub use report::{
    CompatibilityFinding, CompatibilityReport, CompatibilityStatus, ImportResult, StatusCounts,
};

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
        2
    }

    fn discovery_roots(&self) -> &'static [&'static str] {
        &[".github/workflows"]
    }

    fn supports(&self, workflow_path: &str) -> bool {
        workflow_path.starts_with(".github/workflows/")
            || workflow_path.ends_with(".github.yml")
            || workflow_path.ends_with(".github.yaml")
    }

    fn prepare(
        &self,
        source: &str,
        workflow_path: &str,
        options: &WorkflowFrontendOptions,
    ) -> Result<PreparedWorkflowSource, WorkflowFrontendError> {
        let imported = import_github_actions_with_default_job_container_image(
            source,
            workflow_path,
            options
                .value(DEFAULT_JOB_CONTAINER_IMAGE_OPTION)
                .map(str::to_owned),
        )
        .map_err(|error| {
            WorkflowFrontendError::new(
                WorkflowFrontendErrorKind::InvalidSource,
                "github-actions.invalid-source",
                error.to_string(),
            )
        })?;
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
            let detail = if blockers.is_empty() {
                "compatibility analysis produced no executable workflow".to_owned()
            } else {
                blockers
            };
            WorkflowFrontendError::new(
                WorkflowFrontendErrorKind::IncompatibleSource,
                "github-actions.incompatible-source",
                detail,
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

/// Maximum accepted GitHub Actions workflow source size.
pub const MAX_GITHUB_WORKFLOW_BYTES: usize = 1024 * 1024;

/// Analyze and, when safe and fully representable, import a GitHub Actions
/// workflow into native Runtrue YAML.
pub fn import_github_actions(
    source: &str,
    source_name: impl Into<String>,
) -> Result<ImportResult, ImportError> {
    import_github_actions_with_default_job_container_image(source, source_name, None)
}

fn import_github_actions_with_default_job_container_image(
    source: &str,
    source_name: impl Into<String>,
    default_job_container_image: Option<String>,
) -> Result<ImportResult, ImportError> {
    if source.len() > MAX_GITHUB_WORKFLOW_BYTES {
        return Err(ImportError::TooLarge);
    }
    validate_strict_yaml(source)?;
    let workflow: GithubWorkflow = serde_yaml::from_str(source)?;
    Analyzer::new(source_name.into(), default_job_container_image).analyze(workflow)
}

#[cfg(test)]
mod tests;
