use clap::Parser;
use runtrue_attest::{ImageKind, ImageManifest, ImageSigningKey, SignedImageManifest};
use runtrue_model::ContentDigest;
use std::{
    collections::BTreeMap,
    env,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt as _,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

const OCI_MANIFEST_MEDIA_TYPE: &str = "application/vnd.oci.image.manifest.v1+json";

#[derive(Debug, Parser)]
#[command(name = "runtrue-action-admitter", version)]
struct Args {
    #[arg(long)]
    image: String,
    #[arg(long)]
    archive: PathBuf,
    #[arg(long)]
    reference: String,
    #[arg(long)]
    commit: String,
    #[arg(long)]
    metadata_digest: ContentDigest,
    #[arg(long)]
    build_policy_id: String,
    #[arg(long)]
    build_environment_id: String,
    #[arg(long)]
    material_policy_digest: ContentDigest,
}

struct Configuration {
    docker: PathBuf,
    runner_container: String,
    podman_root: PathBuf,
    manifest_directory: PathBuf,
    signing_key: PathBuf,
    signature_identity: String,
    runtime_uid: u32,
    runtime_gid: u32,
}

fn main() {
    if let Err(error) = run(Args::parse(), configuration()) {
        eprintln!("runtrue-action-admitter: {error}");
        std::process::exit(1);
    }
}

fn configuration() -> Configuration {
    Configuration {
        docker: env_path("RUNTRUE_ACTION_ADMISSION_DOCKER", "/usr/bin/docker"),
        runner_container: env::var("RUNTRUE_ACTION_ADMISSION_RUNNER_CONTAINER")
            .unwrap_or_else(|_| "runtrue-igh-runner-oci-1".to_owned()),
        podman_root: env_path(
            "RUNTRUE_ACTION_ADMISSION_PODMAN_ROOT",
            "/var/lib/runtrue-igh-oci/image-store",
        ),
        manifest_directory: env_path(
            "RUNTRUE_ACTION_ADMISSION_MANIFEST_DIRECTORY",
            "/var/lib/runtrue-igh-oci/manifests",
        ),
        signing_key: env_path(
            "RUNTRUE_ACTION_ADMISSION_SIGNING_KEY",
            "/run/runtrue-action-admission/image-signing.key",
        ),
        signature_identity: env::var("RUNTRUE_ACTION_ADMISSION_SIGNATURE_IDENTITY")
            .unwrap_or_else(|_| "local-image@runtrue.invalid".to_owned()),
        runtime_uid: env_u32("RUNTRUE_ACTION_ADMISSION_RUNTIME_UID", 10_001),
        runtime_gid: env_u32("RUNTRUE_ACTION_ADMISSION_RUNTIME_GID", 10_001),
    }
}

fn run(args: Args, configuration: Configuration) -> Result<(), String> {
    validate(&args, &configuration)?;
    let archive = OpenOptions::new()
        .read(true)
        .open(&args.archive)
        .map_err(|_| "cannot open the built OCI archive")?;
    let archive_size = archive
        .metadata()
        .map_err(|_| "cannot inspect the built OCI archive")?
        .len();
    if archive_size == 0 {
        return Err("built OCI archive is empty".to_owned());
    }
    import_image(&configuration, archive)?;
    verify_imported_image(&configuration, &args.image)?;

    let digest = image_digest(&args.image)?;
    let destination = configuration.manifest_directory.join(format!(
        "repository-action-{}.json",
        digest.as_str().trim_start_matches("sha256:")
    ));
    if destination.is_file() {
        validate_existing_manifest(&destination, &configuration.signing_key, &args.image)?;
        return Ok(());
    }

    let signing = load_signing_key(&configuration.signing_key)?;
    let manifest = manifest(&args, &configuration, digest, archive_size)?;
    let signed = signing
        .sign_manifest(&manifest)
        .map_err(|_| "cannot sign the OCI admission manifest")?;
    write_manifest(
        &destination,
        &signed,
        configuration.runtime_uid,
        configuration.runtime_gid,
    )?;
    restart_runner(&configuration)?;
    Ok(())
}

fn validate(args: &Args, configuration: &Configuration) -> Result<(), String> {
    let valid_reference = args
        .reference
        .rsplit_once('@')
        .is_some_and(|(repository, commit)| {
            !repository.is_empty()
                && commit == args.commit
                && commit.len() == 40
                && lower_hex(commit)
        });
    if !valid_reference
        || image_digest(&args.image).is_err()
        || !args.archive.is_absolute()
        || !configuration.docker.is_absolute()
        || !configuration.podman_root.is_absolute()
        || !configuration.manifest_directory.is_absolute()
        || !configuration.signing_key.is_absolute()
        || configuration.runner_container.is_empty()
        || configuration.signature_identity.is_empty()
        || args.build_policy_id.is_empty()
        || args.build_environment_id.is_empty()
    {
        return Err("admission request or configuration is invalid".to_owned());
    }
    Ok(())
}

fn import_image(configuration: &Configuration, archive: File) -> Result<(), String> {
    let status = Command::new(&configuration.docker)
        .args([
            "exec",
            "-i",
            "--user",
            &format!(
                "{}:{}",
                configuration.runtime_uid, configuration.runtime_gid
            ),
            &configuration.runner_container,
            "/usr/bin/podman",
            "--root",
            path_text(&configuration.podman_root)?,
            "load",
        ])
        .stdin(Stdio::from(archive))
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|_| "cannot start OCI image import")?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| "OCI image import failed".to_owned())
}

fn verify_imported_image(configuration: &Configuration, image: &str) -> Result<(), String> {
    let status = Command::new(&configuration.docker)
        .args([
            "exec",
            "--user",
            &format!(
                "{}:{}",
                configuration.runtime_uid, configuration.runtime_gid
            ),
            &configuration.runner_container,
            "/usr/bin/podman",
            "--root",
            path_text(&configuration.podman_root)?,
            "image",
            "exists",
            image,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|_| "cannot verify imported OCI image")?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| "imported OCI digest is unavailable".to_owned())
}

fn manifest(
    args: &Args,
    configuration: &Configuration,
    digest: ContentDigest,
    archive_size: u64,
) -> Result<ImageManifest, String> {
    let provenance = serde_json::to_vec(&serde_json::json!({
        "reference": args.reference,
        "commit": args.commit,
        "metadata_digest": args.metadata_digest,
        "build_policy_id": args.build_policy_id,
        "build_environment_id": args.build_environment_id,
        "material_policy_digest": args.material_policy_digest,
    }))
    .map_err(|_| "cannot encode build provenance")?;
    let sbom = serde_json::to_vec(&serde_json::json!({
        "spdxVersion": "SPDX-2.3",
        "name": args.reference,
        "documentNamespace": format!("https://runtrue.dev/spdx/{}", digest),
        "packages": [],
    }))
    .map_err(|_| "cannot encode build SBOM")?;
    let created_unix_ms = u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "system clock is before the Unix epoch")?
            .as_millis(),
    )
    .map_err(|_| "system clock exceeds admission bounds")?;
    let mut compatibility = BTreeMap::new();
    compatibility.insert(
        "runtrue-assignment-scope".to_owned(),
        "reusable-image".to_owned(),
    );
    compatibility.insert("runtrue-oci-reference".to_owned(), args.image.clone());
    compatibility.insert(
        "runtrue-signature-identity".to_owned(),
        configuration.signature_identity.clone(),
    );
    Ok(ImageManifest {
        manifest_version: 1,
        kind: ImageKind::OciImage,
        name: args.image.clone(),
        payload_digest: digest,
        payload_size_bytes: archive_size,
        payload_media_type: OCI_MANIFEST_MEDIA_TYPE.to_owned(),
        operating_system: "linux".to_owned(),
        architecture: "amd64".to_owned(),
        builder_id: args.build_environment_id.clone(),
        build_provenance_digest: ContentDigest::sha256(&provenance),
        sbom_digest: ContentDigest::sha256(&sbom),
        created_unix_ms,
        expires_unix_ms: None,
        snapshot_phase: None,
        components: BTreeMap::new(),
        compatibility,
    })
}

fn load_signing_key(path: &Path) -> Result<ImageSigningKey, String> {
    let file = OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|_| "cannot open OCI image signing key")?;
    let mut bytes = Vec::new();
    file.take(33)
        .read_to_end(&mut bytes)
        .map_err(|_| "cannot read OCI image signing key")?;
    let seed: [u8; 32] = bytes
        .try_into()
        .map_err(|_| "OCI image signing key must contain exactly 32 bytes")?;
    Ok(ImageSigningKey::from_seed(seed))
}

fn validate_existing_manifest(path: &Path, key: &Path, image: &str) -> Result<(), String> {
    let bytes = fs::read(path).map_err(|_| "cannot read existing OCI admission manifest")?;
    let signed: SignedImageManifest =
        serde_json::from_slice(&bytes).map_err(|_| "existing OCI admission manifest is invalid")?;
    let signing = load_signing_key(key)?;
    signing
        .verifying_key()
        .verify_manifest(&signed)
        .map_err(|_| "existing OCI admission manifest signature is invalid")?;
    if signed.manifest.name != image
        || signed.manifest.payload_digest != image_digest(image)?
        || signed
            .manifest
            .compatibility
            .get("runtrue-oci-reference")
            .is_none_or(|reference| reference != image)
    {
        return Err("existing OCI admission manifest does not match the image".to_owned());
    }
    Ok(())
}

fn write_manifest(
    path: &Path,
    signed: &SignedImageManifest,
    uid: u32,
    gid: u32,
) -> Result<(), String> {
    fs::create_dir_all(path.parent().ok_or("manifest path has no parent")?)
        .map_err(|_| "cannot create OCI manifest directory")?;
    let pending = path.with_extension(format!("json.pending-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&pending)
        .map_err(|_| "cannot create pending OCI admission manifest")?;
    serde_json::to_writer(&mut file, signed).map_err(|_| "cannot encode OCI admission manifest")?;
    file.write_all(b"\n")
        .and_then(|()| file.sync_all())
        .map_err(|_| "cannot persist OCI admission manifest")?;
    nix::unistd::chown(
        &pending,
        Some(nix::unistd::Uid::from_raw(uid)),
        Some(nix::unistd::Gid::from_raw(gid)),
    )
    .map_err(|_| "cannot assign OCI admission manifest ownership")?;
    fs::rename(&pending, path).map_err(|_| "cannot publish OCI admission manifest")?;
    Ok(())
}

fn restart_runner(configuration: &Configuration) -> Result<(), String> {
    let status = Command::new(&configuration.docker)
        .args(["restart", "--time", "30", &configuration.runner_container])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|_| "cannot restart OCI runner after admission")?;
    status
        .success()
        .then_some(())
        .ok_or_else(|| "OCI runner restart failed".to_owned())
}

fn image_digest(image: &str) -> Result<ContentDigest, String> {
    let (repository, digest) = image
        .rsplit_once('@')
        .ok_or_else(|| "image is not immutable".to_owned())?;
    if repository.is_empty() || repository.contains('@') {
        return Err("image is not immutable".to_owned());
    }
    ContentDigest::parse(digest).map_err(|_| "image digest is invalid".to_owned())
}

fn lower_hex(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn env_path(name: &str, default: &str) -> PathBuf {
    env::var_os(name).map_or_else(|| PathBuf::from(default), PathBuf::from)
}

fn env_u32(name: &str, default: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default)
}

fn path_text(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| "path is not UTF-8".to_owned())
}
