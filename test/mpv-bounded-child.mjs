#!/usr/bin/env node
// A single owned POSIX process group, no shell, no detached/unobserved compiler lane.
// run DEADLINE_SECONDS RECEIPT -- EXECUTABLE [ARG...]
// check RECEIPT EXPECTED_SUPERVISOR_STATUS [normal-exit]
// 124 deadline; 125 infrastructure/unconfirmed cleanup; 127 spawn failure;
// 130 INT; 143 TERM. Only a confirmed "normal-exit" may be a mutant assertion kill.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { performance } from "node:perf_hooks";

const TERM_GRACE_MS = 1_000;
const KILL_GRACE_MS = 5_000;
const POLL_MS = 20;
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

function groupState(pid) {
  if (pid === null) return { quiescent: true, error: null };
  try {
    process.kill(-pid, 0);
    return { quiescent: false, error: null };
  } catch (error) {
    if (error.code === "ESRCH") return { quiescent: true, error: null };
    return { quiescent: false, error: String(error.code ?? error) };
  }
}

function validateReceipt(receipt, expectedStatus, requireNormalExit) {
  if (receipt.schema !== 1 || receipt.cleanupConfirmed !== true ||
      receipt.exitCode !== expectedStatus ||
      !(receipt.noChildCreated === true || receipt.directChildReaped === true) ||
      receipt.groupQuiescent !== true) {
    throw new Error("Supervisor status/cleanup receipt is not confirmed");
  }
  if (receipt.pid !== null && (!Number.isSafeInteger(receipt.pid) || receipt.pid <= 1 ||
      receipt.pgid !== receipt.pid)) {
    throw new Error("Invalid owned process group receipt");
  }
  if (!groupState(receipt.pid).quiescent) throw new Error("Owned process group is not quiescent");
  if (requireNormalExit && (receipt.outcome !== "normal-exit" ||
      receipt.childExitCode !== expectedStatus || receipt.childSignal !== null)) {
    throw new Error("Not a normal child exit; never a runtime assertion kill");
  }
}

async function run(deadlineSeconds, receiptPath, executable, args) {
  if (process.platform === "win32") throw new Error("This harness requires POSIX process groups");
  if (!Number.isSafeInteger(deadlineSeconds) || deadlineSeconds < 1 || deadlineSeconds > 3600 ||
      !path.isAbsolute(receiptPath) || !path.isAbsolute(executable)) {
    throw new Error("An absolute executable/receipt and a 1..3600 second deadline are required");
  }
  if (fs.existsSync(receiptPath)) throw new Error("Refusing to overwrite a supervisor receipt");
  const activeReceipt = receiptPath + ".active";
  const started = performance.now();
  let pid = null;
  let childClosed = false;
  let childExitCode = null;
  let childSignal = null;
  let spawnError = null;
  let cause = null;
  let internalError = null;
  const requests = [];
  const signals = [];
  const requestStop = (outcome, exitCode) => {
    requests.push({ outcome, elapsedMilliseconds: Math.round(performance.now() - started) });
    // A deadline/interruption cannot be overwritten by a child exiting 1 during TERM cleanup.
    if (cause === null) cause = { outcome, exitCode };
  };
  const onINT = () => requestStop("interrupted-INT", 130);
  const onTERM = () => requestStop("interrupted-TERM", 143);
  process.on("SIGINT", onINT);
  process.on("SIGTERM", onTERM);
  const deadlineTimer = setTimeout(() => requestStop("deadline", 124), deadlineSeconds * 1000);
  // Publish readiness ONLY after handlers exist. Async Bash children can initially inherit
  // ignored SIGINT. The parent persists a cancellation marker before checking this readiness;
  // cancellation before readiness is consumed here, not lost during Node startup.
  fs.writeFileSync(activeReceipt, JSON.stringify({
    schema: 1, supervisorPID: process.pid, receiptPath, executable, args,
    readyForSignals: true, startedAt: new Date().toISOString(), deadlineSeconds,
    termGraceMilliseconds: TERM_GRACE_MS, killGraceMilliseconds: KILL_GRACE_MS
  }, null, 2) + "\n", { flag: "wx" });
  if (fs.existsSync(receiptPath + ".cancel-INT")) onINT();
  else if (fs.existsSync(receiptPath + ".cancel-TERM")) onTERM();
  const quiescence = () => {
    const group = groupState(pid);
    return {
      confirmed: (pid === null || childClosed) && group.quiescent,
      group
    };
  };
  const signalOwnedGroup = signal => {
    if (pid === null) return;
    try {
      process.kill(-pid, signal);
      signals.push({ signal, result: "sent", elapsedMilliseconds: Math.round(performance.now() - started) });
    } catch (error) {
      signals.push({
        signal, result: error.code === "ESRCH" ? "already-gone" : "failed",
        error: String(error.code ?? error), elapsedMilliseconds: Math.round(performance.now() - started)
      });
    }
  };
  const waitForQuiescence = async milliseconds => {
    const until = performance.now() + milliseconds;
    while (!quiescence().confirmed && performance.now() < until) {
      await delay(Math.min(POLL_MS, Math.max(1, until - performance.now())));
    }
    return quiescence().confirmed;
  };

  try {
    // detached:true gives this child its own POSIX process group. Never signal our parent group.
    // Inherited stdio cannot leave Node waiting on a pipe held open by a compiler descendant.
    if (cause === null) {
      const child = spawn(executable, args, { detached: true, stdio: "inherit", shell: false });
      pid = Number.isSafeInteger(child.pid) ? child.pid : null;
      child.on("error", error => {
        spawnError = String(error.code ?? error);
        requestStop(pid === null ? "spawn-failure" : "child-process-error", pid === null ? 127 : 125);
      });
      child.on("close", (code, signal) => {
        childExitCode = code;
        childSignal = signal;
        childClosed = true; // Node has reaped the direct child before emitting close.
        if (performance.now() - started >= deadlineSeconds * 1000 && cause === null) {
          requestStop("deadline", 124);
        }
      });
      while (!childClosed && cause === null) await delay(POLL_MS);
    }
  } catch (error) {
    internalError = String(error.code ?? error);
    requestStop(pid === null ? "spawn-failure" : "supervisor-error", pid === null ? 127 : 125);
  }

  clearTimeout(deadlineTimer);
  // Even a nominal exit must not leave compiler descendants running after the slot is released.
  if (cause === null && !quiescence().confirmed) requestStop("leftover-process-group", 125);
  if (!quiescence().confirmed) {
    signalOwnedGroup("SIGTERM");
    if (!(await waitForQuiescence(TERM_GRACE_MS))) {
      signalOwnedGroup("SIGKILL");
      await waitForQuiescence(KILL_GRACE_MS);
    }
  }
  const final = quiescence();
  const noChildCreated = pid === null;
  let exitCode;
  let outcome;
  if (!final.confirmed) {
    // A finite supervisor cannot promise to reap an OS-uninterruptible child. Fail closed:
    // persist its identity, return infrastructure failure, and NEVER release the parent slot.
    exitCode = 125;
    outcome = "cleanup-unconfirmed";
  } else if (cause !== null) {
    ({ exitCode, outcome } = cause);
  } else if (childSignal !== null || !Number.isInteger(childExitCode)) {
    exitCode = 125;
    outcome = "unexpected-child-signal";
  } else {
    exitCode = childExitCode;
    outcome = "normal-exit";
  }
  const receipt = {
    schema: 1, supervisorPID: process.pid, pid, pgid: pid, executable, args,
    deadlineSeconds, elapsedMilliseconds: Math.round(performance.now() - started),
    termGraceMilliseconds: TERM_GRACE_MS, killGraceMilliseconds: KILL_GRACE_MS,
    outcome, exitCode, requestedOutcome: cause?.outcome ?? null,
    childExitCode, childSignal, spawnError, internalError, requests, signals,
    noChildCreated, directChildReaped: childClosed, groupQuiescent: final.group.quiescent,
    groupProbeError: final.group.error, cleanupConfirmed: final.confirmed,
    completedAt: new Date().toISOString()
  };
  fs.writeFileSync(receiptPath, JSON.stringify(receipt, null, 2) + "\n", { flag: "wx" });
  if (!final.confirmed) {
    process.stderr.write(`CLEANUP UNCONFIRMED: owned PID/PGID ${pid}; retain serial slot; reconcile ${receiptPath}\n`);
  }
  process.removeListener("SIGINT", onINT);
  process.removeListener("SIGTERM", onTERM);
  // Explicit exit is needed only for the bounded exceptional cleanup-unconfirmed case;
  // its receipt forbids releasing the slot or treating any child output as a valid result.
  process.exit(exitCode);
}

try {
  const [command, ...args] = process.argv.slice(2);
  if (command === "check" && (args.length === 2 || (args.length === 3 && args[2] === "normal-exit"))) {
    const status = Number(args[1]);
    if (!Number.isInteger(status) || status < 0 || status > 255) throw new Error("Invalid supervisor status");
    validateReceipt(JSON.parse(fs.readFileSync(args[0], "utf8")), status, args[2] === "normal-exit");
  } else if (command === "run" && args.length >= 4 && args[2] === "--") {
    await run(Number(args[0]), args[1], args[3], args.slice(4));
  } else {
    throw new Error("Usage: mpv-bounded-child.mjs run SECONDS RECEIPT -- EXECUTABLE [ARG...] | check RECEIPT STATUS [normal-exit]");
  }
} catch (error) {
  // Missing/invalid receipt or supervisor failure is not a normal child exit 1.
  process.stderr.write(`SUPERVISOR FAILURE: ${String(error.message ?? error)}\n`);
  process.exit(125);
}
