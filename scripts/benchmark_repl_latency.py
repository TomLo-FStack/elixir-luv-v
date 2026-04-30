import argparse
import os
import queue
import re
import subprocess
import sys
import threading
import time


def reader(stream, out):
    try:
        while True:
            chunk = stream.read(1)
            if not chunk:
                break
            out.put(chunk)
    finally:
        try:
            stream.close()
        except Exception:
            pass


class Repl:
    def __init__(self, name, command, cwd):
        self.name = name
        self.command = command
        self.output = queue.Queue()
        self.process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=0,
        )
        self.thread = threading.Thread(
            target=reader, args=(self.process.stdout, self.output), daemon=True
        )
        self.thread.start()

    def drain(self):
        chunks = []
        while True:
            try:
                chunks.append(self.output.get_nowait())
            except queue.Empty:
                return "".join(chunks)

    def eval_once(self, expression, done_pattern, timeout_s):
        self.drain()
        started = time.perf_counter()
        self.process.stdin.write(expression + "\n")
        self.process.stdin.flush()

        text = ""
        while (time.perf_counter() - started) < timeout_s:
            if self.process.poll() is not None:
                text += self.drain()
                raise RuntimeError(
                    f"{self.name} exited with {self.process.returncode}. Output:\n{text}"
                )

            try:
                text += self.output.get(timeout=0.001)
            except queue.Empty:
                continue

            if done_pattern.search(text):
                return (time.perf_counter() - started) * 1000.0

        text += self.drain()
        raise TimeoutError(f"{self.name} timed out. Output:\n{text}")

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


def measure(name, command, expression, done_pattern, exit_command, args):
    repl = Repl(name, command, os.getcwd())
    try:
        time.sleep(args.startup_wait_ms / 1000.0)
        repl.drain()

        for _ in range(args.warmup):
            repl.eval_once(expression, done_pattern, args.timeout_ms / 1000.0)

        samples = [
            repl.eval_once(expression, done_pattern, args.timeout_ms / 1000.0)
            for _ in range(args.iterations)
        ]
    finally:
        repl.close(exit_command)

    samples_sorted = sorted(samples)
    median = samples_sorted[len(samples_sorted) // 2]
    p95 = samples_sorted[min(len(samples_sorted) - 1, int(len(samples_sorted) * 0.95))]

    return {
        "name": name,
        "samples": samples,
        "avg": sum(samples) / len(samples),
        "median": median,
        "p95": p95,
        "min": samples_sorted[0],
        "max": samples_sorted[-1],
    }


def print_result(result):
    print(
        f"{result['name']:>8}: "
        f"avg={result['avg']:.3f} ms "
        f"median={result['median']:.3f} ms "
        f"p95={result['p95']:.3f} ms "
        f"min={result['min']:.3f} ms "
        f"max={result['max']:.3f} ms"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--timeout-ms", type=int, default=15000)
    parser.add_argument("--startup-wait-ms", type=int, default=1500)
    parser.add_argument("--max-slowdown-percent", type=float, default=5.0)
    parser.add_argument("--julia", default="julia")
    parser.add_argument("--elv", nargs="+", default=["escript", ".\\elv", "repl", "--no-banner", "--no-snapshots"])
    args = parser.parse_args()

    done = re.compile(r"(?m)(?:^|>\s*)2\s*$")

    julia = measure(
        "Julia",
        [args.julia, "--startup-file=no", "--quiet", "-i"],
        "1+1",
        done,
        "exit()",
        args,
    )
    elv = measure("ELV", args.elv, "1+1", done, ":quit", args)

    print_result(julia)
    print_result(elv)

    slowdown = (elv["median"] / julia["median"] - 1.0) * 100.0
    print(
        f"Median slowdown: {slowdown:.2f}% "
        f"(ELV {elv['median']:.3f} ms / Julia {julia['median']:.3f} ms)"
    )

    if slowdown > args.max_slowdown_percent:
        print(f"FAIL: slowdown exceeds {args.max_slowdown_percent:.2f}%", file=sys.stderr)
        return 1

    print(f"PASS: slowdown is within {args.max_slowdown_percent:.2f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
