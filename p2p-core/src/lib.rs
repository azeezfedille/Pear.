//! p2p_core: embedded, opt-in, zero-footprint BitTorrent streaming engine for iOS.
//! Swift sees one object (`P2pEngine`). Creating it spawns everything; `stop()` / dropping it destroys everything.
mod engine;
mod http;
mod pacer;
mod pacer_logic;
mod util;

pub use engine::P2pEngine;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum P2pError {
    #[error("engine is stopped")]
    Stopped,
    #[error("invalid input: {msg}")]
    InvalidInput { msg: String },
    #[error("timed out fetching torrent metadata")]
    MetadataTimeout,
    #[error("no playable file in torrent")]
    NoFile,
    #[error("torrent error: {msg}")]
    Torrent { msg: String },
    #[error("io error: {msg}")]
    Io { msg: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineConfig {
    /// Writable dir (use the app's Caches directory). Engine creates/deletes `p2p-*` subfolders only.
    pub cache_dir: String,
    /// Upload cap in bytes/sec (clamped to >= 16 KiB/s: librqbit drops peers when a limit is below one chunk per second). Low by default: we leech-optimised to save battery.
    pub upload_limit_bps: u32,
    /// How long start_stream waits for magnet metadata before failing.
    pub metadata_timeout_secs: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StreamInfo {
    /// `http://127.0.0.1:<port>/<token>/stream/<file>`: hand this to AetherEngine.
    pub url: String,
    pub file_name: String,
    pub length: u64,
    pub file_index: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EngineStats {
    pub downloaded_bytes: u64,
    pub uploaded_bytes: u64,
    pub total_bytes: u64,
    pub peers_live: u32,
    pub download_bps: u64,
}

#[uniffi::export]
pub fn default_engine_config(cache_dir: String) -> EngineConfig {
    EngineConfig { cache_dir, upload_limit_bps: 16 * 1024, metadata_timeout_secs: 45 }
}
