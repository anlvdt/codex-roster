use anyhow::{Result, bail};

use super::{ProviderAdapter, ProviderAuthBundle};
use crate::env::AppEnv;
use crate::model::{
    AiProvider, DisplayIdentity, ProviderCapability, ProviderUsageView, SnapshotBlob,
};

pub struct OpenAiAdapter;
pub static OPENAI: OpenAiAdapter = OpenAiAdapter;

const CAPABILITIES: &[ProviderCapability] = &[
    ProviderCapability::ReadIdentity,
    ProviderCapability::MonitorUsage,
    ProviderCapability::LocalActivity,
    ProviderCapability::TokenHistory,
    ProviderCapability::SnapshotAuth,
    ProviderCapability::SwitchAccount,
    ProviderCapability::AutoSwitch,
    ProviderCapability::RelaunchApp,
];

impl ProviderAdapter for OpenAiAdapter {
    fn provider(&self) -> AiProvider {
        AiProvider::OpenAi
    }

    fn capabilities(&self) -> &'static [ProviderCapability] {
        CAPABILITIES
    }

    fn try_read_live_auth(&self, env: &AppEnv) -> Result<Option<ProviderAuthBundle>> {
        Ok(
            crate::codex::try_read_live_auth_bundle(env)?.map(|bundle| ProviderAuthBundle {
                identity: bundle.identity,
                snapshot: bundle.snapshot,
            }),
        )
    }

    fn read_live_auth(&self, env: &AppEnv) -> Result<ProviderAuthBundle> {
        let bundle = crate::codex::read_live_auth_bundle(env)?;
        Ok(ProviderAuthBundle {
            identity: bundle.identity,
            snapshot: bundle.snapshot,
        })
    }

    fn identity_from_snapshot(&self, snapshot: &SnapshotBlob) -> Result<DisplayIdentity> {
        crate::codex::identity_from_snapshot(snapshot)
    }

    fn restore_snapshot(&self, env: &AppEnv, snapshot: &SnapshotBlob) -> Result<()> {
        let identity = crate::codex::identity_from_snapshot(snapshot)?;
        crate::codex::restore_snapshot_with_retry(
            env,
            snapshot,
            &identity,
            true,
            4,
            std::time::Duration::from_millis(250),
        )
    }

    fn fetch_usage(&self, _snapshot: &SnapshotBlob) -> Result<ProviderUsageView> {
        bail!("OpenAI usage is handled by the existing Codex usage transaction")
    }

    fn requires_relaunch_after_switch(&self) -> bool {
        true
    }
}
