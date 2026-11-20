#!/usr/bin/env python3
"""HTTP benchmark: ff vs Deno vs Bun, driven by oha and hyperfine.

For each runtime this script:
  1. starts the identical hello-JSON server alone on a loopback port,
  2. waits for a correct 200 + body,
  3. warms it up with oha,
  4. runs oha N times (JSON output) and samples the server's RSS,
  5. cross-checks with hyperfine over a fixed request count,
  6. stops the server and moves to the next runtime.

Results land in bench/httpbench/results/:
  raw.json, summary.csv, summary.md, report.html, charts/*.svg
plus per-runtime oha JSON, hyperfine JSON, and server logs.

Examples:
  ./bench/httpbench/run.sh
  ./bench/httpbench/run.sh --runtimes ff,bun --connections 256 --duration 10
  python3 bench/httpbench/bench.py --quick
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import http.client
import json
import os
import platform
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SERVERS = HERE / "servers"
BODY = b'{"message":"Hello, World!"}'
EXPECTED_CT = "application/json"

RUNTIME_ORDER = ["ff", "deno", "bun"]


# ── environment ───────────────────────────────────────────────────


def run_capture(cmd: list[str]) -> str:
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return "missing"
    text = (proc.stdout or proc.stderr or "").strip()
    return text.splitlines()[0] if text else "unknown"


def tool_version(name: str, args: list[str] | None = None) -> str:
    exe = shutil.which(name)
    if not exe:
        return "missing"
    return run_capture([exe] + (args or ["--version"]))


def strip_prefix(text: str, prefix: str) -> str:
    return text[len(prefix):] if text.startswith(prefix) else text


def git_rev() -> str:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
            text=True, stderr=subprocess.DEVNULL,
        )
        dirty = subprocess.call(
            ["git", "-C", str(ROOT), "diff", "--quiet"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return out.strip() + ("-dirty" if dirty else "")
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


# ── server process ────────────────────────────────────────────────


@dataclass
class Context:
    port: int
    path: str
    connections: int
    duration_s: int
    runs: int
    warmup_s: int
    hf_runs: int
    hf_warmup: int
    hf_requests: int
    oha_threads: int
    ff_bin: Path
    ff_args: str
    out: Path

    @property
    def url(self) -> str:
        suffix = "" if self.path.startswith("/") else "/"
        return f"http://127.0.0.1:{self.port}{suffix}{self.path}"


def server_command(name: str, ctx: Context) -> list[str]:
    if name == "ff":
        cmd = [
            str(ctx.ff_bin),
            "ff.js",
            f"--allow-net=127.0.0.1:{ctx.port}",
            "--allow-env=PORT",
        ]
        if ctx.ff_args.strip():
            cmd += shlex.split(ctx.ff_args)
        return cmd
    if name == "deno":
        return [
            shutil.which("deno") or "deno",
            "run",
            "--quiet",
            f"--allow-net=127.0.0.1:{ctx.port}",
            "--allow-env=PORT",
            "deno.js",
        ]
    if name == "bun":
        return [shutil.which("bun") or "bun", "bun.js"]
    raise SystemExit(f"unknown runtime: {name}")


def wait_ready(ctx: Context, proc: subprocess.Popen, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    last_error = "no response"
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"server exited with {proc.returncode} before becoming ready")
        try:
            conn = http.client.HTTPConnection("127.0.0.1", ctx.port, timeout=0.5)
            conn.request("GET", ctx.path)
            resp = conn.getresponse()
            body = resp.read()
            ctype = resp.getheader("content-type") or ""
            conn.close()
            if resp.status == 200 and body == BODY and EXPECTED_CT in ctype:
                return
            last_error = f"status={resp.status} body={body[:40]!r} content-type={ctype!r}"
        except (OSError, http.client.HTTPException) as exc:
            last_error = str(exc)
        time.sleep(0.1)
    raise RuntimeError(f"server did not become ready in {timeout:.0f}s ({last_error})")


def stop_server(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (OSError, AttributeError):
        proc.terminate()
    try:
        proc.wait(timeout=4)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (OSError, AttributeError):
            proc.kill()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass


class _MacTaskInfo(ctypes.Structure):
    """struct proc_taskinfo (libproc.h); first two fields are the ones we use."""

    _fields_ = [
        ("pti_virtual_size", ctypes.c_uint64),
        ("pti_resident_size", ctypes.c_uint64),
        ("pti_total_user", ctypes.c_uint64),
        ("pti_total_system", ctypes.c_uint64),
        ("pti_threads_user", ctypes.c_uint64),
        ("pti_threads_system", ctypes.c_uint64),
        ("pti_policy", ctypes.c_int32),
        ("pti_faults", ctypes.c_int32),
        ("pti_pageins", ctypes.c_int32),
        ("pti_cow_faults", ctypes.c_int32),
        ("pti_messages_sent", ctypes.c_int32),
        ("pti_messages_received", ctypes.c_int32),
        ("pti_syscalls_mach", ctypes.c_int32),
        ("pti_syscalls_unix", ctypes.c_int32),
        ("pti_csw", ctypes.c_int32),
        ("pti_threadnum", ctypes.c_int32),
        ("pti_numrunning", ctypes.c_int32),
        ("pti_priority", ctypes.c_int32),
    ]


class RssReader:
    """Resident set size of a running process.

    macOS: proc_pidinfo(PROC_PIDTASKINFO) — a syscall, no helper process.
    Linux: /proc/<pid>/status VmRSS.
    Other: `ps -o rss=` (kB) as a last resort.
    Returns megabytes, or None when the value cannot be read.
    """

    PROC_PIDTASKINFO = 4

    def __init__(self, pid: int):
        self.pid = pid
        self._libc = None
        if sys.platform == "darwin":
            try:
                libc = ctypes.CDLL(
                    ctypes.util.find_library("c") or "/usr/lib/libSystem.B.dylib",
                    use_errno=True,
                )
                libc.proc_pidinfo.argtypes = [
                    ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                    ctypes.c_void_p, ctypes.c_int,
                ]
                libc.proc_pidinfo.restype = ctypes.c_int
                self._libc = libc
            except (OSError, AttributeError):
                self._libc = None

    def read_mb(self) -> float | None:
        if self._libc is not None:
            info = _MacTaskInfo()
            size = ctypes.sizeof(info)
            got = self._libc.proc_pidinfo(
                self.pid, self.PROC_PIDTASKINFO, 0, ctypes.byref(info), size,
            )
            if got == size:
                return info.pti_resident_size / (1024.0 * 1024.0)
            return None
        if sys.platform.startswith("linux"):
            try:
                for line in Path(f"/proc/{self.pid}/status").read_text().splitlines():
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1]) / 1024.0
            except (OSError, ValueError, IndexError):
                return None
            return None
        try:
            out = subprocess.check_output(
                ["ps", "-o", "rss=", "-p", str(self.pid)],
                text=True, stderr=subprocess.DEVNULL, timeout=2,
            ).strip()
            return int(out) / 1024.0 if out else None
        except (OSError, ValueError, subprocess.SubprocessError):
            return None


class RssSampler(threading.Thread):
    """Sample the server's RSS until stopped; keep the peak."""

    def __init__(self, pid: int, interval: float = 0.1):
        super().__init__(daemon=True)
        self.reader = RssReader(pid)
        self.interval = interval
        self.samples: list[float] = []
        self._stop = threading.Event()

    def run(self) -> None:
        while not self._stop.wait(self.interval):
            value = self.reader.read_mb()
            if value is not None:
                self.samples.append(value)

    def stop(self) -> float | None:
        self._stop.set()
        self.join(timeout=2)
        return max(self.samples, default=None)


def rss_mb(pid: int) -> float | None:
    return RssReader(pid).read_mb()


# ── oha / hyperfine ───────────────────────────────────────────────


def oha_base(ctx: Context) -> list[str]:
    exe = shutil.which("oha")
    if not exe:
        raise SystemExit("oha not found (install: brew install oha / cargo install oha)")
    return [
        exe,
        "-c", str(ctx.connections),
        "--no-tui",
        "--worker-threads", str(ctx.oha_threads),
        "--no-color",
    ]


def run_oha_json(ctx: Context, out_path: Path) -> None:
    cmd = oha_base(ctx) + [
        "-z", f"{ctx.duration_s}s",
        "--output-format", "json",
        "-o", str(out_path),
        ctx.url,
    ]
    proc = subprocess.run(
        cmd, capture_output=True, text=True, timeout=ctx.duration_s + 90,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"oha failed ({proc.returncode}): {proc.stderr.strip()[:300]}")


def run_oha_warmup(ctx: Context) -> None:
    cmd = oha_base(ctx) + [
        "-z", f"{ctx.warmup_s}s",
        "--output-format", "quiet",
        ctx.url,
    ]
    subprocess.run(
        cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=ctx.warmup_s + 60,
    )


def parse_oha(path: Path) -> dict:
    data = json.loads(path.read_text())
    summary = data.get("summary") or {}
    metrics = (data.get("metrics") or {}).get("latency_ms") or {}
    percentiles = data.get("latencyPercentiles") or {}

    def number(value):
        try:
            return None if value is None else float(value)
        except (TypeError, ValueError):
            return None

    def latency(metric_key: str, percentile_key: str) -> float:
        # metrics.latency_ms is milliseconds. Older oha builds leave it empty
        # and report latencyPercentiles in SECONDS — normalize to ms.
        direct = number(metrics.get(metric_key))
        if direct is not None:
            return direct
        fallback = number(percentiles.get(percentile_key))
        return 0.0 if fallback is None else fallback * 1000.0

    status = data.get("statusCodeDistribution") or {}
    total = sum(int(v) for v in status.values())
    ok = sum(int(v) for k, v in status.items() if str(k).startswith("2"))
    deadline = sum(
        int(v) for k, v in (data.get("errorDistribution") or {}).items()
        if "deadline" in str(k).lower()
    )
    return {
        "rps": number(summary.get("requestsPerSec")) or 0.0,
        "p50_ms": latency("p50", "p50"),
        "p95_ms": latency("p95", "p95"),
        "p99_ms": latency("p99", "p99"),
        "mean_ms": latency("mean", "p50"),
        "max_ms": latency("max", "p99.9"),
        "requests": total,
        "success_pct": (100.0 * ok / total) if total else 0.0,
        "errors": max(0, total - ok),
        "deadline_aborts": deadline,
    }


def run_hyperfine(ctx: Context, out_path: Path, log_path: Path) -> dict:
    exe = shutil.which("hyperfine")
    if not exe:
        raise SystemExit("hyperfine not found (install: brew install hyperfine)")
    oha_client = oha_base(ctx) + [
        "-n", str(ctx.hf_requests),
        "--output-format", "quiet",
        ctx.url,
    ]
    cmd = [
        exe,
        "--warmup", str(ctx.hf_warmup),
        "--runs", str(ctx.hf_runs),
        "--style", "basic",
        "--export-json", str(out_path),
        shlex.join(oha_client),
    ]
    with log_path.open("w") as log:
        proc = subprocess.run(
            cmd, stdout=log, stderr=subprocess.STDOUT,
            timeout=(ctx.hf_requests / 10_000 + 30) * (ctx.hf_runs + ctx.hf_warmup + 1),
        )
    if proc.returncode != 0:
        raise RuntimeError(f"hyperfine failed ({proc.returncode}); see {log_path}")
    data = json.loads(out_path.read_text())
    result = data["results"][0]
    mean = float(result.get("mean") or 0.0)
    return {
        "mean_s": mean,
        "stddev_s": float(result.get("stddev") or 0.0),
        "min_s": float(result.get("min") or 0.0),
        "max_s": float(result.get("max") or 0.0),
        "rps": (ctx.hf_requests / mean) if mean > 0 else 0.0,
        "times_s": [float(t) for t in result.get("times") or []],
    }


# ── per-runtime run ───────────────────────────────────────────────


def bench_runtime(name: str, ctx: Context, skip_hyperfine: bool) -> dict:
    out_dir = ctx.out / name
    out_dir.mkdir(parents=True, exist_ok=True)
    for stale in out_dir.glob("oha_run*.json"):
        stale.unlink()

    log_path = out_dir / "server.log"
    env = os.environ.copy()
    env["PORT"] = str(ctx.port)
    env["DENO_NO_UPDATE_CHECK"] = "1"
    env.setdefault("NO_COLOR", "1")

    cmd = server_command(name, ctx)
    print(f"\n▶ {name}: {' '.join(shlex.quote(part) for part in cmd)}")
    with log_path.open("w") as log:
        proc = subprocess.Popen(
            cmd, cwd=str(SERVERS), env=env,
            stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    try:
        wait_ready(ctx, proc)
        idle_rss = rss_mb(proc.pid)
        shown = "—" if idle_rss is None else f"{idle_rss:.1f} MB"
        print(f"  ready on 127.0.0.1:{ctx.port}  (rss {shown})")

        run_oha_warmup(ctx)
        idle_rss = rss_mb(proc.pid)
        sampler = RssSampler(proc.pid)
        sampler.start()

        runs = []
        try:
            for index in range(1, ctx.runs + 1):
                target = out_dir / f"oha_run{index}.json"
                run_oha_json(ctx, target)
                runs.append(parse_oha(target))
                print(
                    f"  run {index}/{ctx.runs}: "
                    f"{runs[-1]['rps'] / 1000:.1f}k req/s, "
                    f"p50 {runs[-1]['p50_ms']:.2f} ms, "
                    f"p99 {runs[-1]['p99_ms']:.2f} ms"
                )
                if proc.poll() is not None:
                    raise RuntimeError(f"server exited mid-run ({proc.returncode}); see {log_path}")
        finally:
            peak_rss_mb = sampler.stop()

        hf = {}
        if not skip_hyperfine:
            print(f"  hyperfine: {ctx.hf_runs} × oha -n {ctx.hf_requests} …")
            hf = run_hyperfine(ctx, out_dir / "hyperfine.json", out_dir / "hyperfine.log")
            print(
                f"  hyperfine: {hf['mean_s']:.3f} ± {hf['stddev_s']:.3f} s "
                f"→ {hf['rps'] / 1000:.1f}k req/s"
            )
    finally:
        stop_server(proc)

    rps_values = [r["rps"] for r in runs]
    item = {
        "runs": runs,
        "rps_median": statistics.median(rps_values),
        "rps_min": min(rps_values),
        "rps_max": max(rps_values),
        "p50_ms": statistics.median(r["p50_ms"] for r in runs),
        "p95_ms": statistics.median(r["p95_ms"] for r in runs),
        "p99_ms": statistics.median(r["p99_ms"] for r in runs),
        "mean_ms": statistics.median(r["mean_ms"] for r in runs),
        "max_ms": max(r["max_ms"] for r in runs),
        "success_pct": statistics.median(r["success_pct"] for r in runs),
        "errors": sum(r["errors"] for r in runs),
        "deadline_aborts": sum(r["deadline_aborts"] for r in runs),
        "idle_rss_mb": idle_rss,
        "rss_peak_mb": peak_rss_mb,
        "hyperfine": hf,
        "hf_mean_s": hf.get("mean_s", 0.0),
        "hf_stddev_s": hf.get("stddev_s", 0.0),
        "hf_rps": hf.get("rps", 0.0),
    }
    (out_dir / "metrics.json").write_text(json.dumps(item, indent=2) + "\n")
    return item


# ── main ──────────────────────────────────────────────────────────


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="HTTP benchmark (ff vs Deno vs Bun) with oha + hyperfine.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--runtimes", default=",".join(RUNTIME_ORDER),
                        help="comma-separated subset of ff,deno,bun")
    parser.add_argument("--connections", type=int, default=100,
                        help="oha -c keep-alive connections")
    parser.add_argument("--duration", type=int, default=5, help="seconds per oha run")
    parser.add_argument("--runs", type=int, default=3, help="oha runs per runtime")
    parser.add_argument("--warmup", type=int, default=2, help="warmup seconds per runtime")
    parser.add_argument("--hf-runs", type=int, default=3,
                        help="hyperfine timed runs")
    parser.add_argument("--hf-warmup", type=int, default=1,
                        help="hyperfine warmup runs")
    parser.add_argument("--hf-requests", type=int, default=200_000,
                        help="fixed request count for hyperfine")
    parser.add_argument("--oha-threads", type=int,
                        default=min(8, os.cpu_count() or 8),
                        help="oha worker threads")
    parser.add_argument("--port", type=int, default=8787,
                        help="loopback port (must be free)")
    parser.add_argument("--path", default="/", help="request path")
    parser.add_argument("--out", type=Path, default=HERE / "results",
                        help="results directory")
    parser.add_argument("--ff-bin", type=Path, default=ROOT / "zig-out/bin/ff",
                        help="ff binary")
    parser.add_argument("--ff-args", default="",
                        help="extra flags for the ff server, shell-quoted "
                             "(e.g. '--max-heap=512MB')")
    parser.add_argument("--build", action="store_true",
                        help="run `zig build -Doptimize=ReleaseFast` first")
    parser.add_argument("--skip-hyperfine", action="store_true",
                        help="oha only; skip the hyperfine cross-check")
    parser.add_argument("--quick", action="store_true",
                        help="1s × 1 run, 20k hyperfine requests (smoke test)")
    return parser.parse_args(argv)


def preflight(args: argparse.Namespace, runtimes: list[str]) -> None:
    missing = []
    if not shutil.which("oha"):
        missing.append("oha")
    if not args.skip_hyperfine and not shutil.which("hyperfine"):
        missing.append("hyperfine")
    for runtime in runtimes:
        if runtime != "ff" and not shutil.which(runtime):
            missing.append(runtime)
    if missing:
        raise SystemExit(
            "missing tools: " + ", ".join(missing)
            + "\n  install: brew install oha hyperfine deno bun"
        )
    if "ff" in runtimes and not args.ff_bin.exists():
        raise SystemExit(
            f"ff binary not found at {args.ff_bin}\n"
            "  build it with: zig build -Doptimize=ReleaseFast   (or pass --build)"
        )
    if not port_is_free(args.port):
        raise SystemExit(
            f"port {args.port} is busy; stop the listener or pass --port"
        )


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.quick:
        args.duration, args.runs, args.warmup = 1, 1, 1
        args.hf_runs, args.hf_warmup, args.hf_requests = 1, 0, 20_000

    runtimes = [r.strip() for r in args.runtimes.split(",") if r.strip()]
    unknown = [r for r in runtimes if r not in RUNTIME_ORDER]
    if unknown:
        raise SystemExit(f"unknown runtimes: {', '.join(unknown)}")

    if args.build:
        print("▶ building ff (ReleaseFast)…")
        subprocess.run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT, check=True)

    preflight(args, runtimes)
    args.out.mkdir(parents=True, exist_ok=True)

    ctx = Context(
        port=args.port,
        path=args.path,
        connections=args.connections,
        duration_s=args.duration,
        runs=args.runs,
        warmup_s=args.warmup,
        hf_runs=args.hf_runs,
        hf_warmup=args.hf_warmup,
        hf_requests=args.hf_requests,
        oha_threads=args.oha_threads,
        ff_bin=args.ff_bin.resolve(),
        ff_args=args.ff_args,
        out=args.out.resolve(),
    )

    meta = {
        "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "host": platform.node(),
        "os": platform.platform(),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "loadavg": list(os.getloadavg()) if hasattr(os, "getloadavg") else [],
        "git": git_rev(),
        "connections": ctx.connections,
        "duration_s": ctx.duration_s,
        "runs": ctx.runs,
        "warmup_s": ctx.warmup_s,
        "hf_runs": ctx.hf_runs,
        "hyperfine_enabled": not args.skip_hyperfine,
        "hf_requests": ctx.hf_requests,
        "workload": "hello-json",
        "path": ctx.path,
        "oha_version": strip_prefix(tool_version("oha"), "oha "),
        "hyperfine_version": strip_prefix(tool_version("hyperfine"), "hyperfine "),
        "ff_version": strip_prefix(tool_version(str(ctx.ff_bin)), "ff "),
        "ff_args": ctx.ff_args,
        "deno_version": strip_prefix(tool_version("deno", ["--version"]), "deno "),
        "bun_version": tool_version("bun"),
        "python": platform.python_version(),
    }

    print("HTTP benchmark — ff · Deno · Bun")
    print(f"  host     {meta['host']} ({meta['cpu_count']} CPUs, {meta['os']})")
    print(f"  client   oha {meta['oha_version']}, hyperfine {meta['hyperfine_version']}")
    print(f"  load     {ctx.connections} conns, {ctx.duration_s}s × {ctx.runs} runs, "
          f"warmup {ctx.warmup_s}s")
    print(f"  workload {ctx.url}")

    results: dict[str, dict] = {}
    for name in runtimes:
        results[name] = bench_runtime(name, ctx, args.skip_hyperfine)

    raw = {"meta": meta, "runtimes": results}
    (ctx.out / "raw.json").write_text(json.dumps(raw, indent=2) + "\n")

    print("\n── summary ─────────────────────────────────────────────")
    for name, item in results.items():
        print(
            f"  {name:<5} {item['rps_median'] / 1000:7.1f}k req/s  "
            f"p50 {item['p50_ms']:5.2f} ms  p99 {item['p99_ms']:5.2f} ms  "
            f"RSS {item['rss_peak_mb']:5.1f} MB"
        )

    import report  # local module
    report.write_csv(raw, ctx.out / "summary.csv")
    report.write_markdown(raw, ctx.out / "summary.md")
    html_path = report.render(raw, ctx.out)
    print(f"\nreport:  {html_path}")
    print(f"data:    {ctx.out / 'summary.csv'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        raise SystemExit(130)