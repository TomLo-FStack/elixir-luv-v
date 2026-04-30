import argparse
import os
import queue
import re
import subprocess
import threading
import time


CASES = [
    {
        "name": "literal 1+1",
        "julia_setup": [],
        "julia_expr": "1+1",
        "elv_setup": [],
        "elv_expr": "1+1",
        "expect": "2",
    },
    {
        "name": "xor 10000 ^ 10",
        "julia_setup": [],
        "julia_expr": "xor(10000, 10)",
        "elv_setup": [],
        "elv_expr": "10000 ^ 10",
        "expect": "10010",
    },
    {
        "name": "variable read",
        "julia_setup": ["value = 1"],
        "julia_expr": "value + 2",
        "elv_setup": ["value := 1"],
        "elv_expr": "value + 2",
        "expect": "3",
    },
    {
        "name": "function call",
        "julia_setup": ["add(a, b) = a + b"],
        "julia_expr": "add(1, 2)",
        "elv_setup": ["fn add(a int, b int) int { return a + b }"],
        "elv_expr": "add(1, 2)",
        "expect": "3",
    },
    {
        "name": "math import/use",
        "julia_setup": [],
        "julia_expr": "sqrt(81)",
        "elv_setup": ["import math"],
        "elv_expr": "math.sqrt(81)",
        "expect": "9",
    },
]


def reader(stream, out):
    while True:
        chunk = stream.read(1)
        if not chunk:
            return
        out.put(chunk)


class Repl:
    def __init__(self, name, command):
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
        threading.Thread(
            target=reader, args=(self.process.stdout, self.output), daemon=True
        ).start()
        time.sleep(STARTUP_WAIT_S)
        self.drain()

    def drain(self):
        chunks = []
        while True:
            try:
                chunks.append(self.output.get_nowait())
            except queue.Empty:
                return "".join(chunks)

    def eval_once(self, expression, expect):
        pattern = re.compile(rf"(?m)(?:^|>\s*){re.escape(expect)}(?:\.0)?\s*$")
        self.drain()
        started = time.perf_counter()
        self.process.stdin.write(expression + "\n")
        self.process.stdin.flush()

        text = ""
        while time.perf_counter() - started < TIMEOUT_S:
            if self.process.poll() is not None:
                text += self.drain()
                raise RuntimeError(
                    f"{self.name} exited with {self.process.returncode}. Output:\n{text}"
                )

            try:
                text += self.output.get(timeout=0.001)
            except queue.Empty:
                continue

            if pattern.search(text):
                return (time.perf_counter() - started) * 1000.0

        text += self.drain()
        raise TimeoutError(f"{self.name} timed out on {expression!r}. Output:\n{text}")

    def close(self, exit_command):
        try:
            if self.process.poll() is None:
                self.process.stdin.write(exit_command + "\n")
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
        "avg": sum(samples) / len(samples),
        "median": ordered[len(ordered) // 2],
        "p95": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
        "min": ordered[0],
        "max": ordered[-1],
    }


def measure_case(repl, setup, expr, expect, iterations, warmup):
    for line in setup:
        repl.eval_once(line, expect_from_setup(line, repl.name))

    for _ in range(warmup):
        repl.eval_once(expr, expect)

    return summarize([repl.eval_once(expr, expect) for _ in range(iterations)])


def expect_from_setup(line, repl_name):
    stripped = line.strip()
    if repl_name == "Julia":
        if stripped == "value = 1":
            return "1"
        if stripped == "add(a, b) = a + b":
            return "add"
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=50)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--timeout-s", type=float, default=20.0)
    parser.add_argument("--startup-wait-s", type=float, default=1.5)
    parser.add_argument("--threshold-pct", type=float, default=5.0)
    args = parser.parse_args()

    global TIMEOUT_S
    global STARTUP_WAIT_S
    TIMEOUT_S = args.timeout_s
    STARTUP_WAIT_S = args.startup_wait_s

    julia = Repl("Julia", ["julia", "--startup-file=no", "--quiet", "-i"])
    elv = Repl("ELV", ["escript", ".\\elv", "repl", "--no-banner", "--no-snapshots"])

    try:
        print(
            f"{'case':<18} {'Julia med':>10} {'ELV med':>10} {'slowdown':>12} {'ELV p95':>10} {'status':>8}"
        )
        print("-" * 75)
        failures = []

        for case in CASES:
            # Use fresh REPLs per case so setup/history does not cross-contaminate.
            julia.close("exit()")
            elv.close(":quit")
            julia = Repl("Julia", ["julia", "--startup-file=no", "--quiet", "-i"])
            elv = Repl("ELV", ["escript", ".\\elv", "repl", "--no-banner", "--no-snapshots"])

            j = measure_case(
                julia,
                case["julia_setup"],
                case["julia_expr"],
                case["expect"],
                args.iterations,
                args.warmup,
            )
            e = measure_case(
                elv,
                case["elv_setup"],
                case["elv_expr"],
                case["expect"],
                args.iterations,
                args.warmup,
            )
            slowdown = (e["median"] / j["median"] - 1.0) * 100.0
            passed = slowdown <= args.threshold_pct
            if not passed:
                failures.append((case["name"], slowdown))

            print(
                f"{case['name']:<18} "
                f"{j['median']:>9.3f}ms "
                f"{e['median']:>9.3f}ms "
                f"{slowdown:>11.1f}% "
                f"{e['p95']:>9.3f}ms "
                f"{'PASS' if passed else 'FAIL':>8}"
            )

        if failures:
            print()
            print(f"FAILED: {len(failures)} case(s) slower than Julia by > {args.threshold_pct:.1f}%")
            raise SystemExit(1)

        print()
        print(f"PASS: all cases are within {args.threshold_pct:.1f}% of Julia median latency")
    finally:
        julia.close("exit()")
        elv.close(":quit")


if __name__ == "__main__":
    main()
