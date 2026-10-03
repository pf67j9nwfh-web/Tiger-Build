"""Control of a running chat turn: stop, guidance, and tool approval.

Tiger Build gives each turn an id. While the turn streams, Tiger Build can
send small requests naming that id:

  stop      end the turn now (close the model stream and the tool session)
  guide     a note from the user, delivered to the model at the next safe
            moment (between tool steps), never in the middle of a tool call
  approve   the user's answer to a "may I run this tool?" question

Everything is held in memory and dropped when the turn ends.
"""

import threading
import time

APPROVAL_WAIT = 600


class Stopped(Exception):
    """Raised inside a turn when the user pressed Stop or the client left."""


class Run(object):
    def __init__(self, run_id):
        self.id = run_id
        self.started = time.time()
        self.cancelled = threading.Event()
        self._lock = threading.Lock()
        self._guidance = []
        self._abort = []
        self._answers = {}
        self._waiters = {}

    # --- stop ---
    def on_abort(self, callback):
        """Call this when the turn is stopped, from the stopping thread. Used
        to close a model response or tool connection that is blocking."""
        with self._lock:
            if not self.cancelled.is_set():
                self._abort.append(callback)
                return callback
        self._call(callback)
        return callback

    def off_abort(self, callback):
        with self._lock:
            try:
                self._abort.remove(callback)
            except ValueError:
                pass

    @staticmethod
    def _call(callback):
        try:
            callback()
        except Exception:
            pass

    def cancel(self):
        with self._lock:
            if self.cancelled.is_set():
                return
            self.cancelled.set()
            callbacks, self._abort = self._abort, []
            waiters = list(self._waiters.values())
        for callback in callbacks:
            self._call(callback)
        for event in waiters:
            event.set()

    def check(self):
        if self.cancelled.is_set():
            raise Stopped()

    # --- guidance ---
    def add_guidance(self, text):
        text = (text or "").strip()
        if not text:
            return False
        with self._lock:
            if len(self._guidance) >= 8:
                return False
            self._guidance.append(text[:4000])
        return True

    def take_guidance(self):
        with self._lock:
            notes, self._guidance = self._guidance, []
        return notes

    # --- approval ---
    def ask(self, call_id):
        """Register a question. Returns the event wait() blocks on."""
        event = threading.Event()
        with self._lock:
            self._waiters[call_id] = event
        return event

    def answer(self, call_id, decision):
        with self._lock:
            known = call_id in self._waiters
            if known:
                self._answers[call_id] = decision
                event = self._waiters[call_id]
        if known:
            event.set()
        return known

    def wait(self, call_id, timeout=APPROVAL_WAIT):
        """The user's decision: "allow", "deny", or "always". Stopping or a
        long silence is a refusal."""
        with self._lock:
            event = self._waiters.get(call_id)
        if event is None:
            return "deny"
        event.wait(timeout)
        self.check()
        with self._lock:
            self._waiters.pop(call_id, None)
            decision = self._answers.pop(call_id, "deny")
        return decision if decision in ("allow", "always") else "deny"


_RUNS = {}
_RUNS_LOCK = threading.Lock()


def valid_id(value):
    return (
        isinstance(value, str)
        and 4 <= len(value) <= 48
        and all(ch.isalnum() or ch in "-_" for ch in value)
    )


def start(run_id):
    run = Run(run_id)
    if valid_id(run_id):
        with _RUNS_LOCK:
            old = _RUNS.get(run_id)
            _RUNS[run_id] = run
        if old is not None:
            old.cancel()
    return run


def get(run_id):
    with _RUNS_LOCK:
        return _RUNS.get(run_id)


def finish(run):
    with _RUNS_LOCK:
        if _RUNS.get(run.id) is run:
            del _RUNS[run.id]
    run.cancel()
