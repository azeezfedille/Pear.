//! Loopback-only HTTP server: GET/HEAD + Range (206) over a librqbit FileStream.
//! Unguessable per-session token in the path stops other local apps from reading the stream.
use std::{convert::Infallible, io, io::SeekFrom, sync::Arc, time::Duration};

use bytes::Bytes;
use futures_util::stream;
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Empty, StreamBody};
use hyper::{
    body::{Frame, Incoming},
    header,
    server::conn::http1,
    service::service_fn,
    Method, Request, Response, StatusCode,
};
use hyper_util::rt::TokioIo;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncSeek, AsyncSeekExt},
    net::TcpListener,
    sync::Semaphore,
};
use tokio_util::sync::CancellationToken;

use crate::{
    engine::Shared,
    pacer::{Pace, WaitGuard},
    util::{mime_for, parse_range, RangeSpec},
};

type Body = UnsyncBoxBody<Bytes, io::Error>;
/// Small chunks keep resident memory flat; librqbit pieces live on disk, not in RAM.
const CHUNK: u64 = 64 * 1024;
const MAX_CONNS: usize = 8;

fn empty() -> Body {
    Empty::<Bytes>::new().map_err(|n| match n {}).boxed_unsync()
}

fn status(code: StatusCode) -> Response<Body> {
    let mut r = Response::new(empty());
    *r.status_mut() = code;
    r
}

fn file_body<S>(s: S, start: u64, len: u64, pace: Arc<Pace>) -> Body
where
    S: AsyncRead + AsyncSeek + Unpin + Send + 'static,
{
    let st = stream::unfold((s, start, len, false, pace), |(mut s, pos, remaining, seeked, pace)| async move {
        if remaining == 0 {
            return None;
        }
        if !seeked {
            pace.note_request(pos);
            if let Err(e) = s.seek(SeekFrom::Start(pos)).await {
                return Some((Err(e), (s, pos, 0, true, pace)));
            }
        }
        let mut buf = vec![0u8; CHUNK.min(remaining) as usize];
        let guard = WaitGuard::new(&pace); // lets the pacer lift its throttle if we are starved for data
        let r = s.read(&mut buf).await;
        drop(guard);
        match r {
            Ok(0) => Some((Err(io::ErrorKind::UnexpectedEof.into()), (s, pos, 0, true, pace))),
            Ok(n) => {
                buf.truncate(n);
                let next = pos + n as u64;
                pace.advance(next);
                Some((Ok(Frame::data(Bytes::from(buf))), (s, next, remaining - n as u64, true, pace)))
            }
            Err(e) => Some((Err(e), (s, pos, 0, true, pace))),
        }
    });
    StreamBody::new(st).boxed_unsync()
}

async fn route(req: Request<Incoming>, shared: &Shared, token: &str) -> Result<Response<Body>, StatusCode> {
    let head = match *req.method() {
        Method::GET => false,
        Method::HEAD => true,
        _ => return Err(StatusCode::METHOD_NOT_ALLOWED),
    };
    let mut seg = req.uri().path().trim_start_matches('/').split('/');
    if seg.next() != Some(token) || seg.next() != Some("stream") {
        return Err(StatusCode::NOT_FOUND);
    }
    let (handle, idx, len, name) = {
        let g = shared.current.read().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let c = g.as_ref().ok_or(StatusCode::NOT_FOUND)?;
        (c.handle.clone(), c.file_idx, c.len, c.name.clone())
    };

    let range = req
        .headers()
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|v| parse_range(v, len))
        .unwrap_or(RangeSpec::Full);

    let mut builder = Response::builder()
        .header(header::CONTENT_TYPE, mime_for(&name))
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CACHE_CONTROL, "no-store");

    if len == 0 {
        return builder.status(StatusCode::OK).header(header::CONTENT_LENGTH, 0).body(empty()).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR);
    }
    let (start, end, code) = match range {
        RangeSpec::Full => (0, len - 1, StatusCode::OK),
        RangeSpec::Partial(s, e) => {
            builder = builder.header(header::CONTENT_RANGE, format!("bytes {s}-{e}/{len}"));
            (s, e, StatusCode::PARTIAL_CONTENT)
        }
        RangeSpec::Unsatisfiable => {
            return Response::builder()
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{len}"))
                .body(empty())
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR);
        }
    };
    let n = end - start + 1;
    let body = if head {
        empty()
    } else {
        let fs = handle.stream(idx).map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
        file_body(fs, start, n, shared.pace.clone())
    };
    builder.status(code).header(header::CONTENT_LENGTH, n).body(body).map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)
}

pub async fn serve(listener: TcpListener, shared: Arc<Shared>, token: Arc<str>, cancel: CancellationToken) {
    let permits = Arc::new(Semaphore::new(MAX_CONNS));
    loop {
        let sock = tokio::select! {
            _ = cancel.cancelled() => break,
            r = listener.accept() => match r {
                Ok((s, _)) => s,
                Err(_) => { tokio::time::sleep(Duration::from_millis(200)).await; continue; }
            },
        };
        let Ok(permit) = permits.clone().try_acquire_owned() else { continue }; // drop excess sockets
        let _ = sock.set_nodelay(true);
        let (shared, token, cancel) = (shared.clone(), token.clone(), cancel.clone());
        tokio::spawn(async move {
            let _permit = permit;
            let svc = service_fn(move |req| {
                let (shared, token) = (shared.clone(), token.clone());
                async move { Ok::<_, Infallible>(route(req, &shared, &token).await.unwrap_or_else(status)) }
            });
            let conn = http1::Builder::new().serve_connection(TokioIo::new(sock), svc);
            tokio::select! {
                _ = cancel.cancelled() => {}
                _ = conn => {}
            }
        });
    }
}
