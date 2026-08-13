"""
Background installer jobs that outlive the WebSocket that started them.

The install handlers used to own their subprocess directly: spawn conda, stream
its output down the socket, kill it if the socket dropped. Two things went wrong
with that arrangement, and they compounded each other.

conda's solve phase runs for minutes without printing anything. With no traffic
in either direction, a dropped connection went unnoticed on both ends -- the
backend never attempted a send, so nothing raised WebSocketDisconnect and the
process was never cleaned up, while the Flutter side saw its event stream close
and quietly reset the button with no error frame to show. The install kept
running, orphaned, behind a UI that said it had not started. Clicking Install
again then spawned a second conda, which died on the package-cache lock the
first one still held: "LockError: failed to acquire lock".

So the job now lives here, keyed by name, owned by the backend. A socket
attaches to a job, replays the log accumulated so far, and streams the rest; if
it drops, the install carries on and the next connection picks it back up.
Jobs are also grouped: everything that touches conda's shared package cache
shares one group, and starting a second job in a busy group is refused with the
name of the one already running, rather than being allowed to fail later with
conda's own opaque lock error.
"""
import asyncio

# Bounded so a chatty installer cannot grow the log without limit; this runs on
# machines where memory is the scarce resource.
_MAX_LOG = 2000

# Jobs sharing a group are serialised. conda locks its package cache process-
# wide, so every conda-backed install collides with every other one regardless
# of which environment it is creating.
CONDA_GROUP = "conda"
PIP_GROUP = "pip"

_jobs: dict[str, "InstallJob"] = {}


class InstallBusy(Exception):
    """Another job in the same group is already running."""

    def __init__(self, running: str):
        self.running = running
        super().__init__(running)


class InstallJob:
    def __init__(self, name: str, group: str, runner):
        self.name = name
        self.group = group
        self.status = "running"          # running | done | error | cancelled
        self.error: str | None = None
        self.log: list[dict] = []
        self.proc = None
        self.cancelled = False
        self.task = None
        self._runner = runner
        self._queues: set[asyncio.Queue] = set()

    def emit(self, event: dict) -> None:
        self.log.append(event)
        if len(self.log) > _MAX_LOG:
            del self.log[: len(self.log) - _MAX_LOG]
        for q in list(self._queues):
            q.put_nowait(event)

    def subscribe(self) -> tuple[list[dict], asyncio.Queue]:
        """The log so far, plus a queue carrying everything after it.

        Both are taken without awaiting in between, so no event can land in the
        gap and be lost or delivered twice.
        """
        q: asyncio.Queue = asyncio.Queue()
        self._queues.add(q)
        return list(self.log), q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._queues.discard(q)

    def cancel(self) -> None:
        """Explicit user cancellation -- the only thing that kills the process.
        A socket merely closing does not, which is the point of this module."""
        self.cancelled = True
        if self.proc is not None and self.proc.returncode is None:
            self.proc.terminate()

    async def _run(self) -> None:
        try:
            await self._runner(self)
            self.status = "cancelled" if self.cancelled else "done"
        except Exception as e:
            self.status = "error"
            # Carried into the error frame rather than only logged: the
            # interface highlights the error line, and "installation failed" on
            # its own tells nobody which of the several possible reasons applied.
            self.error = str(e) or f"{self.name}: installation failed."
        finally:
            if self.status == "done":
                self.emit({"type": "done"})
            elif self.status == "cancelled":
                self.emit({"type": "error", "text": "Cancelled.\n"})
            else:
                self.emit({"type": "error", "text": f"{self.error}\n"})
            # A sentinel rather than closing the queues, so every attached
            # socket learns the job ended instead of blocking forever.
            for q in list(self._queues):
                q.put_nowait(None)


def get_job(name: str) -> InstallJob | None:
    return _jobs.get(name)


def busy_in_group(group: str, exclude: str | None = None) -> str | None:
    """Name of a running job holding `group`, if any."""
    for job in _jobs.values():
        if job.group == group and job.status == "running" and job.name != exclude:
            return job.name
    return None


def start_job(name: str, group: str, runner) -> InstallJob:
    """Start `name`, or return the job already running under that name.

    Re-entry is deliberate: the Install button exists on both the first-run gate
    and the Settings screen, so the same install can legitimately be requested
    twice. The second request attaches to the first rather than starting a rival
    process.
    """
    existing = _jobs.get(name)
    if existing is not None and existing.status == "running":
        return existing

    blocker = busy_in_group(group, exclude=name)
    if blocker:
        raise InstallBusy(blocker)

    job = InstallJob(name, group, runner)
    _jobs[name] = job
    job.task = asyncio.create_task(job._run())
    return job


def statuses() -> dict:
    return {name: job.status for name, job in _jobs.items()}


async def run_proc(job: InstallJob, argv: list[str], clean=None) -> int:
    """Spawn `argv`, streaming stdout+stderr into the job's log. Returns the
    exit code. The process handle is kept on the job so cancel() can reach it."""
    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    job.proc = proc
    try:
        async for line in proc.stdout:
            text = clean(line) if clean else line.decode("utf-8", "replace")
            if text:
                job.emit({"type": "log", "text": text})
        return await proc.wait()
    finally:
        job.proc = None
