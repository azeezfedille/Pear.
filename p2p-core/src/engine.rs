use std::{
    collections::HashSet,
    future::Future,
    num::NonZeroU32,
    path::{Path, PathBuf},
    sync::{atomic::Ordering, mpsc, Arc, Mutex, RwLock},
    time::Duration,
};

use librqbit::{
    api::TorrentIdOrHash, limits::LimitsConfig, AddTorrent, AddTorrentOptions, AddTorrentResponse, ManagedTorrent,
    Session, SessionOptions,
};
use tokio::{net::TcpListener, runtime::Builder, time::timeout};
use tokio_util::sync::CancellationToken;

use crate::{http, pacer, pacer_logic::{clamp_limit, MIN_LIMIT_BPS}, util::pick_file, EngineConfig, EngineStats, P2pError, StreamInfo};

pub struct Current {
    pub handle: Arc<ManagedTorrent>,
    pub id: usize,
    pub file_idx: usize,
    pub len: u64,
    pub name: String,
}

#[derive(Default)]
pub struct Shared {
    pub current: RwLock<Option<Current>>,
    pub pace: Arc<pacer::Pace>,
}

#[derive(Clone)]
struct Ctx {
    session: Arc<Session>,
    shared: Arc<Shared>,
    base: String,
    token: String,
    meta_timeout: Duration,
    upload_bps: u32,
}

/// Everything that owns a socket, thread or file lives here. Dropping it is the killswitch.
struct Inner {
    runtime: Option<tokio::runtime::Runtime>,
    ctx: Ctx,
    cancel: CancellationToken,
    dir: PathBuf,
}

fn io_err(e: impl ToString) -> P2pError {
    P2pError::Io { msg: e.to_string() }
}
fn t_err(e: impl ToString) -> P2pError {
    P2pError::Torrent { msg: e.to_string() }
}

/// Leftovers from a Jetsam kill / crash: delete before starting so disk never accumulates.
fn purge_stale(root: &Path) {
    if let Ok(rd) = std::fs::read_dir(root) {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().starts_with("p2p-") {
                let _ = std::fs::remove_dir_all(e.path());
            }
        }
    }
}

impl Inner {
    fn new(cfg: &EngineConfig) -> Result<Self, P2pError> {
        let root = PathBuf::from(&cfg.cache_dir);
        std::fs::create_dir_all(&root).map_err(io_err)?;
        purge_stale(&root);
        let dir = root.join(format!("p2p-{:016x}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).map_err(io_err)?;

        let built = (|| -> Result<(tokio::runtime::Runtime, Ctx, CancellationToken), P2pError> {
            // 2 workers: enough for one stream, few enough wakeups for the radio/CPU to idle.
            let rt = Builder::new_multi_thread()
                .worker_threads(2)
                .max_blocking_threads(4)
                .thread_name("p2p")
                .enable_all()
                .build()
                .map_err(io_err)?;

            let opts = SessionOptions {
                disable_dht_persistence: true, // no DHT state files: zero footprint
                persistence: None,             // no session/fastresume files
                listen_port_range: None,       // no inbound listener: one less socket, no NAT keepalives
                enable_upnp_port_forwarding: false,
                ratelimits: LimitsConfig {
                    upload_bps: NonZeroU32::new(clamp_limit(cfg.upload_limit_bps)),
                    download_bps: None,
                },
                ..Default::default()
            };
            let session = rt.block_on(Session::new_with_opts(dir.clone(), opts)).map_err(t_err)?;
            let listener = rt.block_on(TcpListener::bind("127.0.0.1:0")).map_err(io_err)?;
            let port = listener.local_addr().map_err(io_err)?.port();

            let token = format!("{:032x}", rand::random::<u128>());
            let shared = Arc::new(Shared::default());
            let cancel = CancellationToken::new();
            rt.spawn(http::serve(listener, shared.clone(), Arc::from(token.as_str()), cancel.clone()));
            let ctx = Ctx {
                session,
                shared,
                base: format!("http://127.0.0.1:{port}"),
                token,
                meta_timeout: Duration::from_secs(cfg.metadata_timeout_secs.max(5) as u64),
                upload_bps: clamp_limit(cfg.upload_limit_bps),
            };
            Ok((rt, ctx, cancel))
        })();

        match built {
            Ok((rt, ctx, cancel)) => Ok(Inner { runtime: Some(rt), ctx, cancel, dir }),
            Err(e) => {
                let _ = std::fs::remove_dir_all(&dir);
                Err(e)
            }
        }
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.cancel.cancel(); // HTTP accept loop + live connections exit
        if let Ok(mut g) = self.ctx.shared.current.write() {
            g.take();
        }
        if let Some(rt) = self.runtime.take() {
            let s = self.ctx.session.clone();
            // Graceful: tell trackers/peers goodbye, close DHT + peer sockets.
            rt.block_on(async move {
                let _ = timeout(Duration::from_secs(3), s.stop()).await;
            });
            // Hard: kill any task still alive and join worker threads.
            rt.shutdown_timeout(Duration::from_secs(2));
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn build_magnet(hash: &str, trackers: &[String]) -> Result<String, P2pError> {
    if hash.len() != 40 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(P2pError::InvalidInput { msg: "info hash must be 40 hex chars".into() });
    }
    let mut m = format!("magnet:?xt=urn:btih:{}", hash.to_ascii_lowercase());
    for t in trackers.iter().filter(|t| ["udp://", "http://", "https://"].iter().any(|p| t.starts_with(p))).take(12) {
        m.push_str("&tr=");
        m.extend(url::form_urlencoded::byte_serialize(t.as_bytes()));
    }
    Ok(m)
}

impl Ctx {
    async fn drop_current(&self) {
        let cur = self.shared.current.write().ok().and_then(|mut g| g.take());
        if let Some(c) = cur {
            let _ = self.session.delete(TorrentIdOrHash::Id(c.id), true).await; // true = delete files
        }
    }

    async fn open(&self, info_hash: String, trackers: Vec<String>, file_idx: Option<u32>) -> Result<StreamInfo, P2pError> {
        self.drop_current().await; // one stream at a time: bounded peers, disk and memory
        let magnet = build_magnet(&info_hash, &trackers)?;
        let opts = AddTorrentOptions {
            paused: true, // metadata resolves, but no piece traffic until we pick the one file we need
            overwrite: true,
            only_files: file_idx.map(|i| vec![i as usize]),
            ..Default::default()
        };
        let resp = timeout(self.meta_timeout, self.session.add_torrent(AddTorrent::from_url(magnet), Some(opts)))
            .await
            .map_err(|_| P2pError::MetadataTimeout)?
            .map_err(t_err)?;
        let (id, handle) = match resp {
            AddTorrentResponse::Added(id, h) | AddTorrentResponse::AlreadyManaged(id, h) => (id, h),
            _ => return Err(P2pError::Torrent { msg: "unexpected add response".into() }),
        };

        let res: Result<StreamInfo, P2pError> = async {
            let files: Vec<(String, u64)> = handle
                .with_metadata(|m| {
                    m.file_infos
                        .iter()
                        .map(|f| (f.relative_filename.to_string_lossy().into_owned(), f.len))
                        .collect()
                })
                .map_err(t_err)?;
            let idx = pick_file(&files, file_idx).ok_or(P2pError::NoFile)?;
            let (path, len) = files[idx].clone();
            let name = path.rsplit('/').next().unwrap_or(&path).to_string();

            // Only this file downloads. librqbit's FileStream prioritises pieces at the read cursor (sequential + seek).
            let only: HashSet<usize> = [idx].into_iter().collect();
            // librqbit rejects update_only_files while the torrent is still Initializing ("can't update
            // initializing torrent"). A paused magnet passes through that state right after its metadata
            // resolves, so wait for it to settle (Paused) before touching the file selection.
            handle.wait_until_initialized().await.map_err(t_err)?;
            self.session.update_only_files(&handle, &only).await.map_err(t_err)?;
            self.session.unpause(&handle).await.map_err(t_err)?;
            handle.wait_until_initialized().await.map_err(t_err)?;

            let safe: String = url::form_urlencoded::byte_serialize(name.as_bytes()).collect();
            let url = format!("{}/{}/stream/{}", self.base, self.token, safe);
            *self.shared.current.write().map_err(|_| io_err("lock poisoned"))? =
                Some(Current { handle: handle.clone(), id, file_idx: idx, len, name: name.clone() });
            self.shared.pace.reset();
            tokio::spawn(pacer::run(self.session.clone(), self.shared.clone(), id));
            Ok(StreamInfo { url, file_name: name, length: len, file_index: idx as u32 })
        }
        .await;

        if res.is_err() {
            let _ = self.session.delete(TorrentIdOrHash::Id(id), true).await;
        }
        res
    }
}

#[derive(uniffi::Object)]
pub struct P2pEngine {
    inner: Mutex<Option<Inner>>,
}

impl P2pEngine {
    /// Clones what a call needs and RELEASES the lock, so `stop()` is never blocked behind a slow metadata fetch.
    fn grab(&self) -> Result<(tokio::runtime::Handle, Ctx), P2pError> {
        let g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let i = g.as_ref().ok_or(P2pError::Stopped)?;
        let rt = i.runtime.as_ref().ok_or(P2pError::Stopped)?;
        Ok((rt.handle().clone(), i.ctx.clone()))
    }

    /// Runs on the engine runtime; the calling (non-runtime) thread blocks on a channel.
    /// If stop() tears the runtime down mid-flight the sender is dropped and we return `Stopped`, never hang.
    fn run<T, F, Fut>(&self, wait: Duration, f: F) -> Result<T, P2pError>
    where
        T: Send + 'static,
        F: FnOnce(Ctx) -> Fut,
        Fut: Future<Output = T> + Send + 'static,
    {
        let (h, ctx) = self.grab()?;
        let (tx, rx) = mpsc::channel();
        let fut = f(ctx);
        h.spawn(async move {
            let _ = tx.send(fut.await);
        });
        rx.recv_timeout(wait).map_err(|_| P2pError::Stopped)
    }
}

#[uniffi::export]
impl P2pEngine {
    /// Spawns the runtime, DHT/session and loopback server. Blocking: call off the main thread.
    #[uniffi::constructor]
    pub fn new(config: EngineConfig) -> Result<Arc<Self>, P2pError> {
        Ok(Arc::new(Self { inner: Mutex::new(Some(Inner::new(&config)?)) }))
    }

    /// Resolves metadata, selects the file (`file_idx` from Torrentio, else largest video), returns the loopback URL.
    /// Blocking (up to metadata_timeout): call off the main thread.
    pub fn start_stream(&self, info_hash: String, trackers: Vec<String>, file_idx: Option<u32>) -> Result<StreamInfo, P2pError> {
        let wait = self.grab()?.1.meta_timeout + Duration::from_secs(20);
        self.run(wait, move |ctx| async move { ctx.open(info_hash, trackers, file_idx).await })?
    }

    /// Ends the current stream and deletes its files; engine stays alive (idle: no peers, no downloads).
    pub fn stop_stream(&self) {
        let _ = self.run(Duration::from_secs(8), |ctx| async move { ctx.drop_current().await });
    }

    pub fn stats(&self) -> Option<EngineStats> {
        let g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let cur = g.as_ref()?.ctx.shared.current.read().ok()?;
        let c = cur.as_ref()?;
        let s = c.handle.stats();
        let (peers, bps) = s
            .live
            .as_ref()
            .map(|l| (l.snapshot.peer_stats.live as u32, (l.download_speed.mbps * 1024.0 * 1024.0) as u64))
            .unwrap_or((0, 0));
        Some(EngineStats {
            downloaded_bytes: s.progress_bytes,
            uploaded_bytes: s.uploaded_bytes,
            total_bytes: s.total_bytes,
            peers_live: peers,
            download_bps: bps,
        })
    }

    /// Low Power Mode / thermal pressure: upload to the 16 KiB/s floor and a smaller read-ahead window. Cheap, non-blocking.
    pub fn set_power_saving(&self, on: bool) {
        let Ok((_, ctx)) = self.grab() else { return };
        ctx.shared.pace.low_power.store(on, Ordering::Relaxed);
        ctx.session.ratelimits.set_upload_bps(NonZeroU32::new(if on { MIN_LIMIT_BPS } else { ctx.upload_bps }));
    }

    pub fn is_running(&self) -> bool {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }

    /// Killswitch. Idempotent. Closes every socket, joins the Tokio threads, deletes all cached data.
    pub fn stop(&self) {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner()).take();
        drop(inner); // Inner::drop does the teardown, outside the mutex
    }
}

impl Drop for P2pEngine {
    fn drop(&mut self) {
        self.stop();
    }
}
