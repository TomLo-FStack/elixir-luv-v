import argparse
import os
import queue
import re
import subprocess
import threading
import time


CASES = [
    {
        "name": "if expression",
        "setup": ["value := 1"],
        "expr": "if value == 1 { 3 } else { 4 }",
        "expect": "3",
    },
    {
        "name": "function call",
        "setup": ["fn slow_mul(a int, b int) int {\n  return a * b\n}"],
        "expr": "slow_mul(1, 3)",
        "expect": "3",
    },
    {
        "name": "math import",
        "setup": ["import math as m"],
        "expr": "m.sqrt(81)",
        "expect": "9",
    },
    {
        "name": "multiline block",
        "setup": [],
        "expr": "for i in 0 .. 1 {\n  println(i + 3)\n}",
        "expect": "3",
    },
]


def reader(stream, out):
    while True:
        chunk = stream.read(1)
        if not chunk:
            return
        out.put(chunk)


class Repl:
    def __init__(self, name, command, startup_wait_s):
        self.name = name
        self.output = queue.Queue()
        self.process = subprocess.Popen(
            command,
            cwd=os.getcwd(),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=0,
        )
        threading.Thread(target=reader, args=(self.process.stdout, self.output), daemon=True).start()
        time.sleep(startup_wait_s)
        self.drain()

    def drain(self):
        chunks = []
        while True:
            try:
                chunks.append(self.output.get_nowait())
            except queue.Empty:
                return "".join(chunks)

    def eval_once(self, expression, expect, timeout_s):
        pattern = re.compile(rf"(?m)(?:^|[>.]\s*){re.escape(expect)}(?:\.0)?\s*$")
        self.drain()
        started = time.perf_counter()
        self.process.stdin.write(expression + "\n")
        self.process.stdin.flush()

        text = ""
        while time.perf_counter() - started < timeout_s:
            if self.process.poll() is not None:
                text += self.drain()
                raise RuntimeError(
                    f"{self.name} exited with {self.process.returncode}. Output:\n{text}"
                )

            try:
                text += self.output.get(timeout=0.001)
            except queue.Empty:
                continue

            if expect == "" and "v> " in text:
                return (time.perf_counter() - started) * 1000.0

            if expect != "" and pattern.search(text):
                return (time.perf_counter() - started) * 1000.0

        text += self.drain()
        raise TimeoutError(f"{self.name} timed out on {expression!r}. Output:\n{text}")

    def close(self):
        try:
            if self.process.poll() is None:
                self.process.stdin.write(":quit\n")
                self.process.stdin.flush()
                self.process.wait(timeout=2)
        except Exception:
            pass

        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=2)


def summarize(samples):
    ordered = sorted(samples)
    return {
        "median": ordered[len(ordered) // 2],
        "p95": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
        "min": ordered[0],
        "max": ordered[-1],
    }


def setup_expect(line):
    stripped = line.strip()
    if stripped.startswith("fn ") or stripped.startswith("import ") or ":=" in stripped:
        return ""
    return stripped


def measure_backend(label, command, case, args):
    repl = Repl(label, command, args.startup_wait_s)
    try:
        # Force the replay CLI out of the speculative front fast path so the
        # benchmark compares native fallback/daemon execution rather than FastEval.
        repl.eval_once("if true { 0 } else { 1 }", "0", args.timeout_s)

        for line in case["setup"]:
            repl.eval_once(line, setup_expect(line), args.timeout_s)

        for _ in range(args.warmup):
            repl.eval_once(case["expr"], case["expect"], args.timeout_s)

        return summarize(
            [repl.eval_once(case["expr"], case["expect"], args.timeout_s) for _ in range(args.iterations)]
        )
    finally:
        repl.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--timeout-s", type=float, default=30.0)
    parser.add_argument("--startup-wait-s", type=float, default=1.5)
    parser.add_argument("--threshold-pct", type=float, default=25.0)
    parser.add_argument("--elv", nargs="+", default=["escript", ".\\elv", "repl"])
    args = parser.parse_args()

    print(
        f"{'case':<20} {'replay med':>11} {'daemon med':>11} {'speedup':>9} "
        f"{'replay p95':>11} {'daemon p95':>11} {'status':>8}"
    )
    print("-" * 88)
    failures = []

    for case in CASES:
        replay_cmd = args.elv + ["--backend", "replay", "--no-banner", "--no-snapshots"]
        daemon_cmd = args.elv + ["--backend", "daemon", "--no-banner", "--no-snapshots"]

        replay = measure_backend("replay", replay_cmd, case, args)
        daemon = measure_backend("daemon", daemon_cmd, case, args)
        speedup = (1.0 - daemon["median"] / replay["median"]) * 100.0
        passed = daemon["median"] <= replay["median"] * (1.0 + args.threshold_pct / 100.0)

        if not passed:
            failures.append(case["name"])

        status = "PASS" if passed else "FAIL"
        bottleneck = " V-compile-bound" if daemon["median"] > 250.0 else ""
        print(
            f"{case['name']:<20} "
            f"{replay['median']:>10.3f}ms "
            f"{daemon['median']:>10.3f}ms "
            f"{speedup:>8.1f}% "
            f"{replay['p95']:>10.3f}ms "
            f"{daemon['p95']:>10.3f}ms "
            f"{status:>8}{bottleneck}"
        )

    if failures:
        print()
        print(f"FAILED: daemon slower than replay threshold in {len(failures)} case(s)")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
