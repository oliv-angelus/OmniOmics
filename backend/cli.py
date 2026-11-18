"""
OmniOmics command line: run the pipelines without the graphical interface,
on a workstation, a server, or an HPC cluster (PBS Pro).

The run is built by the same backend code as the GUI (config_engine,
run_engine, the pipeline manifests), so a run file and the Launch screen
produce the same config.yaml and the same Snakemake call.

    omniomics list
    omniomics init magma -o run.yaml          # commented run file with every default
    omniomics db list magma                   # databases and their download options
    omniomics db detect magma /data/databases
    omniomics db download magma kraken2 --option k2_pf_16 --dir /data/databases/kraken2
    omniomics envs run.yaml                   # build the tools' conda environments
    omniomics run run.yaml --cores 32 --ram-gb 120
    omniomics run run.yaml --submit pbs --queue cpu --ncpus 64 --mem-gb 240 --walltime 72:00:00
    omniomics unlock run.yaml

With --submit pbs, the whole pipeline runs inside ONE scheduler job (the
Snakemake controller and every rule on the same node); nothing but writing
the run's config and calling qsub happens on the submitting host.
"""
import argparse
import asyncio
import datetime
import os
import shlex
import subprocess
import sys

import yaml

import pipelines
import config_engine
import databases_engine
import run_engine
from settings_store import load_settings

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
LAUNCHER = os.path.join(REPO_ROOT, "bin", "omniomics")

# Memory for a rule whose job loads a whole database (Kraken2, Kaiju):
# database size on disk x this factor + a fixed margin. Validation peaks on
# tapajos: Kraken2 PlusPFP 232 GB on disk -> 232-242 GB RSS; Kaiju nr_euk
# 174 GB -> 194 GB.
DB_MEM_FACTOR = 1.15
DB_MEM_MARGIN_MB = 4000


def die(msg: str, code: int = 1):
    print(f"omniomics: {msg}", file=sys.stderr)
    sys.exit(code)


def _manifest(pid: str) -> dict:
    try:
        return pipelines.get_pipeline(pid)
    except Exception:
        known = ", ".join(p["id"] for p in pipelines.list_pipelines())
        die(f"unknown pipeline '{pid}' (available: {known})")


def _text(value, lang="en"):
    if isinstance(value, dict):
        return value.get(lang) or value.get("pt") or next(iter(value.values()), "")
    return value or ""


# --- run file ------------------------------------------------------------------

def load_run_file(path: str) -> dict:
    if not os.path.isfile(path):
        die(f"run file not found: {path}")
    with open(path) as f:
        run = yaml.safe_load(f) or {}
    if not run.get("pipeline"):
        die(f"{path}: 'pipeline' is required")
    if not run.get("output_dir"):
        die(f"{path}: 'output_dir' is required")
    _manifest(run["pipeline"])
    run["output_dir"] = os.path.abspath(os.path.expanduser(str(run["output_dir"])))
    return run


def _dir_size_mb(path: str) -> int:
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return int(total / 1024 / 1024)


def prepare(run: dict, quiet: bool = False) -> dict:
    """Writes samples.tsv and config.yaml for the run (as the Launch screen
    does) and returns what the Snakemake call needs."""
    pid = run["pipeline"]
    manifest = _manifest(pid)
    out = run["output_dir"]
    config_dir = os.path.join(out, "config")
    os.makedirs(config_dir, exist_ok=True)

    inputs = {k: (os.path.abspath(os.path.expanduser(v)) if isinstance(v, str) and v and k != "reference_mode" else v)
              for k, v in (run.get("inputs") or {}).items()}

    # samples.tsv, discovered from the input folders exactly as in the GUI
    data = {"output_dir": out, **inputs}
    rows = config_engine.build_samples(pid, data)
    if not rows:
        die("no samples found: each sample must be a sub-folder of the input folder(s) "
            "holding its reads (e.g. reads/SAMPLE1/SAMPLE1_R1.fastq.gz)")
    columns = manifest.get("sample_sheet", {}).get("columns")
    tsv_path = os.path.join(config_dir, "samples.tsv")
    config_engine._write_tsv(rows, tsv_path, columns)

    # databases: auto-detected under databases_dir, then explicit paths win
    db_specs = manifest.get("databases", {})
    db_paths = {}
    if run.get("databases_dir"):
        base = os.path.abspath(os.path.expanduser(run["databases_dir"]))
        db_paths.update(databases_engine.detect_databases(pid, base))
    for key, path in (run.get("databases") or {}).items():
        if key not in db_specs:
            die(f"unknown database '{key}' for {pid} (see: omniomics db list {pid})")
        db_paths[key] = os.path.abspath(os.path.expanduser(str(path))) if path else ""

    # tools: the GUI's defaults unless the run file says otherwise; a tool
    # whose requirements are off is dropped, as in the GUI
    tools = manifest.get("tools", {})
    if run.get("active_tools") is not None:
        active = list(run["active_tools"])
    else:
        active = run_engine.default_active_tools(pid)
        active += [t for t in (run.get("enable_tools") or []) if t not in active]
        active = [t for t in active if t not in set(run.get("disable_tools") or [])]
    unknown = [t for t in active if t not in tools]
    if unknown:
        die(f"unknown tool(s) for {pid}: {', '.join(unknown)} (see the run file template: omniomics init {pid})")
    tracks = {k: set(v) for k, v in (run.get("active_tracks") or {}).items()}
    settled, tracks = run_engine.settle(pid, active, tracks)
    dropped = sorted(set(active) - settled)
    if dropped and not quiet:
        print(f"Tools switched off because a tool they need is off: {', '.join(dropped)}")
    omit = run_engine.omit_from_rules(pid, settled, tracks)
    omit += [r for r in (run.get("omit_rules") or []) if r not in omit]

    cfg_data = {
        "output_dir": out,
        "tsv_path": tsv_path,
        "active_tools": sorted(settled),
        "tool_flags": run.get("tool_flags") or {},
        "thread_overrides": run.get("threads") or {},
        "ram_gb": run.get("ram_gb") or 0,
        **inputs,
    }
    for key in ("long_read_platform", "amplicon_preset", "amplicon_fwd_primers", "amplicon_rev_primers"):
        if run.get(key):
            cfg_data[key] = run[key]
    for spec in manifest.get("sample_sheet", {}).get("input_dirs", []):
        if spec.get("toggle"):
            cfg_data[f"{spec['key']}_enabled"] = bool(inputs.get(spec["key"]))
    for key, path in db_paths.items():
        cfg_data[db_specs[key]["setting_key"]] = path
    cfg = config_engine.generate_config(pid, cfg_data)

    missing = sorted(k for k, v in (cfg["data"].get("databases") or {}).items() if not v)
    if missing and not quiet:
        print("Databases with no path (rules that need them will fail): " + ", ".join(missing))

    # memory per rule for the database-loading rules
    rule_mem = {}
    for rule, spec in (manifest.get("rule_resources") or {}).items():
        if rule in omit:
            continue
        if spec.get("mem_from_database"):
            path = (cfg["data"].get("databases") or {}).get(spec["mem_from_database"]) or ""
            if path and os.path.isdir(path):
                rule_mem[rule] = int(_dir_size_mb(path) * DB_MEM_FACTOR) + DB_MEM_MARGIN_MB
        elif spec.get("mem_mb"):
            rule_mem[rule] = int(spec["mem_mb"])

    return {"pid": pid, "manifest": manifest, "output_dir": out, "config_path": cfg["path"],
            "samples": rows, "omit": omit, "rule_mem": rule_mem}


def snakemake_command(prep: dict, cores: int, ram_gb: float | None, extra: list,
                      conda_prefix: str | None = None) -> tuple[list, dict]:
    settings = load_settings()
    cmd, snakemake_bin, conda_bin_dir = run_engine.resolve_snakemake(settings)
    if not snakemake_bin and not os.path.isfile(cmd[0]) and cmd[0] == "conda":
        die("snakemake not found: activate the OmniOmics environment (see docs/CLI.md)")
    too_old = run_engine.conda_too_old(conda_bin_dir)
    if too_old:
        die(too_old)
    conda_prefix = os.path.abspath(os.path.expanduser(conda_prefix or run_engine.CONDA_ENVS_DIR))
    os.makedirs(conda_prefix, exist_ok=True)

    resources = {}
    if ram_gb:
        budget = int(float(ram_gb) * 1024)
        resources["mem_mb"] = budget
        cmd_res = ["--default-resources", f"mem_mb=min({budget}, max(4000, 1800 * threads))"]
        if prep["rule_mem"]:
            cmd_res += ["--set-resources", *(f"{r}:mem_mb={min(m, budget)}" for r, m in sorted(prep["rule_mem"].items()))]
    else:
        cmd_res = []
    cmd += run_engine.snakemake_args(prep["config_path"], prep["output_dir"], cores, prep["omit"],
                                     conda_prefix=conda_prefix, resources=resources)
    cmd += cmd_res + ["--rerun-incomplete"] + list(extra)
    env = run_engine.apply_env(run_engine.subprocess_env(), run_engine.run_env_overrides(conda_bin_dir))
    return cmd, env


def _unlock(cmd: list, env: dict, cwd: str):
    base = [a for a in cmd if not a.startswith("--omit-from")]
    # --unlock only needs the workflow, directory and config
    keep = [base[0]] + [a for a in base[1:] if a.startswith(("--directory=", "--configfile="))]
    subprocess.run(keep + ["--unlock"], cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _default_cores() -> int:
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        return os.cpu_count() or 1


def _default_ram_gb() -> float:
    try:
        import psutil
        return round(psutil.virtual_memory().total / 1024 ** 3 * 0.9, 1)
    except Exception:
        return 0


def run_file_from_gui(pid: str, data: dict) -> str:
    """Run file (YAML) for the configuration on the Launch screen, written to
    <output_dir>/config/run.yaml, so a run set up in the app can be started
    with `omniomics run` on a server. Paths are kept as they are; edit them if
    the server sees the data elsewhere."""
    m = _manifest(pid)
    out = data.get("output_dir") or ""
    inputs = {}
    for spec in m.get("sample_sheet", {}).get("input_dirs", []):
        key = spec["key"]
        if spec.get("toggle") and not data.get(f"{key}_enabled"):
            continue
        if data.get(key):
            inputs[key] = data[key]
    for key in ("reference_mode", "reference_file"):
        if data.get(key):
            inputs[key] = data[key]
    settings = load_settings()
    databases = {}
    for key, db in m.get("databases", {}).items():
        path = data.get(db.get("setting_key", "")) or settings.get(db.get("setting_key", ""), "")
        if db.get("config_key") and path:
            databases[key] = path
    run = {
        "pipeline": pid,
        "output_dir": out,
        "inputs": inputs,
        "databases": databases,
        "active_tools": sorted(data.get("active_tools") or []),
    }
    if data.get("active_tracks"):
        run["active_tracks"] = {k: sorted(v) for k, v in data["active_tracks"].items()}
    for key, run_key in (("tool_flags", "tool_flags"), ("thread_overrides", "threads")):
        if data.get(key):
            run[run_key] = data[key]
    for key in ("ram_gb", "long_read_platform", "amplicon_preset", "amplicon_fwd_primers", "amplicon_rev_primers"):
        if data.get(key):
            run[key] = data[key]
    path = os.path.join(out, "config", "run.yaml")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    header = ("# OmniOmics run file exported from the app. Run it with:\n"
              "#   omniomics run run.yaml                 (this machine)\n"
              "#   omniomics run run.yaml --submit pbs    (one PBS job; see docs/CLI.md)\n"
              "# Edit the paths if the data and databases sit elsewhere on the server.\n")
    with open(path, "w") as f:
        f.write(header + yaml.safe_dump(run, sort_keys=False, allow_unicode=True, width=4096))
    return path


# --- PBS -------------------------------------------------------------------------

def submit_pbs(args, job_name: str, inner: list, log_dir: str, ncpus: int, mem_gb: float) -> str:
    """Submits ONE PBS Pro job that runs `inner` (an omniomics command) on the node."""
    os.makedirs(log_dir, exist_ok=True)
    select = f"select=1:ncpus={ncpus}:mem={int(mem_gb)}gb"
    if args.select_extra:
        select += ":" + args.select_extra.lstrip(":")
    lines = [
        "#!/bin/bash",
        f"#PBS -N {job_name}",
        f"#PBS -l {select}",
        f"#PBS -l walltime={args.walltime}",
        f"#PBS -o {os.path.join(log_dir, job_name + '.out')}",
        f"#PBS -e {os.path.join(log_dir, job_name + '.err')}",
    ]
    if args.queue:
        lines.append(f"#PBS -q {args.queue}")
    if args.account:
        lines.append(f"#PBS -A {args.account}")
    # PBS does not pass the submitting shell's environment to the job: put the
    # interpreter's own bin/ (the OmniOmics env, holding snakemake and conda)
    # first on PATH, as it is where this command was run.
    env_bin = os.path.dirname(sys.executable)
    lines += ["", f"export PATH={shlex.quote(env_bin)}:$PATH", f"cd {shlex.quote(REPO_ROOT)}",
              " ".join(shlex.quote(a) for a in inner), ""]
    script = "\n".join(lines)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    script_path = os.path.join(log_dir, f"{job_name}_{stamp}.pbs")
    with open(script_path, "w") as f:
        f.write(script)
    if args.print_only:
        print(script)
        return ""
    res = subprocess.run(["qsub"], input=script, text=True, capture_output=True)
    if res.returncode != 0:
        die(f"qsub failed: {res.stderr.strip() or res.stdout.strip()}")
    job_id = res.stdout.strip()
    print(f"Submitted PBS job {job_id} ({job_name}); script: {script_path}")
    print(f"Follow it with: qstat {job_id}   |   log: {os.path.join(log_dir, job_name + '.out')}")
    return job_id


def _inner_cli(*parts) -> list:
    return [sys.executable, LAUNCHER, *[str(p) for p in parts]]


# --- commands --------------------------------------------------------------------

def cmd_list(args):
    for p in pipelines.list_pipelines():
        print(f"{p['id']:8s} {_text(p.get('name'))} -- {_text(p.get('description'))[:90]}")


def cmd_init(args):
    pid = args.pipeline
    m = _manifest(pid)
    tools = m.get("tools", {})
    defaults = m.get("defaults", {})
    out = []
    w = out.append
    w(f"# OmniOmics run file -- {_text(m.get('name'))}")
    w("# Fill in the inputs, databases and output folder, then:")
    w("#   omniomics run <this file>                 (this machine)")
    w("#   omniomics run <this file> --submit pbs    (one PBS job)")
    w(f"pipeline: {pid}")
    w("output_dir: /path/to/results")
    w("")
    w("# Input folders: one sub-folder per sample holding its reads")
    w("inputs:")
    for spec in m.get("sample_sheet", {}).get("input_dirs", []):
        note = " (optional; leave empty to skip)" if spec.get("toggle") else ""
        kind = "file" if spec.get("kind") == "file" else "folder"
        w(f"  {spec['key']}: \"\"   # {kind}: {_text(spec.get('label'))}{note}")
    if any(s.get("key") == "reference_dir" for s in m.get("sample_sheet", {}).get("input_dirs", [])):
        w("  reference_mode: none   # none | single (reference_file for every sample) | per_sample (reference_dir/<sample>/)")
        w("  reference_file: \"\"")
    w("")
    w("# Databases: a folder to search (every database found below it is used) and/or")
    w("# explicit paths per database. See: omniomics db list " + pid)
    w("databases_dir: \"\"")
    w("databases:")
    for key, db in m.get("databases", {}).items():
        if db.get("config_key"):
            w(f"  # {key}: \"\"   # {db.get('name', key)}")
    w("")
    if m.get("long_read_platforms"):
        opts = " | ".join(p["id"] for p in m["long_read_platforms"])
        w(f"long_read_platform: {m.get('default_long_read_platform') or m['long_read_platforms'][0]['id']}   # {opts}")
    if m.get("amplicon_presets"):
        opts = " | ".join(p["id"] for p in m["amplicon_presets"])
        w(f"amplicon_preset: {m.get('default_amplicon_preset') or m['amplicon_presets'][0]['id']}   # {opts}")
        w("# amplicon_fwd_primers: \"\"   # comma-separated; empty = the preset's primers")
        w("# amplicon_rev_primers: \"\"")
    w("")
    w("# Folder for the tools' conda environments (shared by runs). Empty = ~/.omniomics/conda_envs")
    w("conda_prefix:")
    w("")
    w("# Memory budget in GB (also caps eggNOG-mapper --dbmem). Empty = 90% of this machine.")
    w("ram_gb:")
    w("")
    w("# Tools: the default set below runs unless you change it. Use enable_tools /")
    w("# disable_tools for small changes, or active_tools for the full list.")
    on = [t for t, d in tools.items() if d.get("active_by_default", True)]
    off = [t for t, d in tools.items() if not d.get("active_by_default", True)]
    w("# On by default:  " + ", ".join(on))
    w("# Off by default: " + (", ".join(off) or "none"))
    w("enable_tools: []")
    w("disable_tools: []")
    w("")
    w("# Extra rules to skip (e.g. a setup step whose database you do not have)")
    w("omit_rules: []")
    w("")
    w("# Tool options: the full option string for that tool (replaces its default)")
    w("tool_flags:")
    for tid, val in defaults.items():
        if isinstance(val, dict):
            w(f"  # {tid}: {yaml.safe_dump(val, default_flow_style=True).strip()}")
        else:
            w(f"  # {tid}: {yaml.safe_dump(val, default_style=chr(34)).strip()}")
    w("")
    w("# Threads per tool (defaults shown)")
    w("threads:")
    for tid, n in (m.get("default_threads") or {}).items():
        w(f"  # {tid}: {n}")
    text = "\n".join(out) + "\n"
    if args.output:
        if os.path.exists(args.output) and not args.force:
            die(f"{args.output} exists (use --force to overwrite)")
        with open(args.output, "w") as f:
            f.write(text)
        print(f"Wrote {args.output}")
    else:
        sys.stdout.write(text)


def cmd_db_list(args):
    m = _manifest(args.pipeline)
    settings = load_settings()
    for key, db in m.get("databases", {}).items():
        path = settings.get(db.get("setting_key", ""), "")
        print(f"{key}: {db.get('name', key)}" + (f"   [configured: {path}]" if path else ""))
        for opt in db.get("download_options", []):
            print(f"    --option {opt['id']:28s} {_text(opt.get('label'))}")


def cmd_db_detect(args):
    found = databases_engine.detect_databases(args.pipeline, os.path.abspath(args.dir))
    if not found:
        print("No known database found.")
    for key, path in sorted(found.items()):
        print(f"{key}: {path}")


def cmd_db_download(args):
    pid = args.pipeline
    m = _manifest(pid)
    db = m.get("databases", {}).get(args.key)
    if not db:
        die(f"unknown database '{args.key}' for {pid} (see: omniomics db list {pid})")
    opts = db.get("download_options", [])
    opt_id = args.option or (opts[0]["id"] if len(opts) == 1 else None)
    if not opt_id:
        die("choose a download option with --option (see: omniomics db list " + pid + ")")
    if not databases_engine.get_download_option(pid, args.key, opt_id):
        die(f"unknown option '{opt_id}' for {args.key}")
    dest = os.path.abspath(os.path.expanduser(args.dir))

    if args.submit == "pbs":
        if not args.walltime:
            die("--submit pbs needs --walltime (e.g. 12:00:00)")
        inner = _inner_cli("db", "download", pid, args.key, "--option", opt_id, "--dir", dest)
        submit_pbs(args, f"omni_db_{args.key}", inner, os.path.join(dest, "..", "omniomics_logs"),
                   args.ncpus or 2, args.mem_gb or 8)
        return

    from db_download import _download_database
    last = {"line": ""}

    async def send(event: dict):
        if event.get("type") == "progress":
            line = f"\r  {event.get('done')}/{event.get('total')} {event.get('unit')} ({event.get('percent')}%)"
            if sys.stdout.isatty():
                sys.stdout.write(line)
                sys.stdout.flush()
            last["line"] = line
        elif event.get("type") == "log":
            if last["line"] and sys.stdout.isatty():
                sys.stdout.write("\n")
                last["line"] = ""
            sys.stdout.write(event.get("text", ""))
            sys.stdout.flush()

    try:
        path = asyncio.run(_download_database(pid, args.key, opt_id, dest, send))
    except KeyboardInterrupt:
        die("download cancelled; its partial files were removed", 130)
    except Exception as exc:
        die(f"download failed: {exc}")
    print(f"\nDone: {args.key} in {path}")


def _run_loop(cmd: list, env: dict, cwd: str, attempts: int) -> int:
    rc = 1
    for attempt in range(1, attempts + 1):
        _unlock(cmd, env, cwd)
        if attempt > 1:
            print(f"--- attempt {attempt} of {attempts} ---", flush=True)
        rc = subprocess.run(cmd, cwd=cwd, env=env).returncode
        if rc == 0:
            return 0
    print(f"omniomics: the run stopped with errors after {attempts} attempt(s); "
          "see the rule logs under <output_dir>/logs", file=sys.stderr)
    return rc


def _conda_prefix(args, run: dict) -> str | None:
    """Where the tools' conda environments live: --conda-prefix, else the run
    file's conda_prefix, else the app's shared folder (~/.omniomics/conda_envs)."""
    return getattr(args, "conda_prefix", None) or run.get("conda_prefix")


def _submit_args_ok(args):
    if not args.walltime:
        die("--submit pbs needs --walltime (e.g. 72:00:00)")
    if not args.ncpus or not args.mem_gb:
        die("--submit pbs needs --ncpus and --mem-gb")


def cmd_run(args):
    run = load_run_file(args.run_file)
    run_file = os.path.abspath(args.run_file)

    if args.submit == "pbs":
        _submit_args_ok(args)
        prepare(run)  # fail fast on the submitting host: samples, tools, databases
        inner = _inner_cli("run", run_file, "--cores", args.ncpus,
                           "--ram-gb", round(args.mem_gb * 0.95, 1), "--attempts", args.attempts)
        if args.conda_prefix:
            inner += ["--conda-prefix", os.path.abspath(args.conda_prefix)]
        submit_pbs(args, f"omni_{run['pipeline']}", inner,
                   os.path.join(run["output_dir"], "logs"), args.ncpus, args.mem_gb)
        return

    prep = prepare(run)
    cores = args.cores or _default_cores()
    ram_gb = args.ram_gb or run.get("ram_gb") or _default_ram_gb()
    extra = ["-n"] if args.dry_run else []
    extra += args.snakemake_args or []
    cmd, env = snakemake_command(prep, cores, ram_gb, extra, _conda_prefix(args, run))
    cwd = prep["manifest"]["_dir"]
    print(f"{run['pipeline']}: {len(prep['samples'])} sample(s), {cores} cores, {ram_gb} GB; output in {prep['output_dir']}")
    if prep["omit"]:
        print("Skipped rules: " + ", ".join(prep["omit"]))
    print("Command: " + " ".join(shlex.quote(a) for a in cmd), flush=True)
    if args.dry_run:
        sys.exit(subprocess.run(cmd, cwd=cwd, env=env).returncode)
    sys.exit(_run_loop(cmd, env, cwd, max(1, args.attempts)))


def cmd_envs(args):
    run = load_run_file(args.run_file)
    if args.submit == "pbs":
        _submit_args_ok(args)
        prepare(run)
        inner = _inner_cli("envs", os.path.abspath(args.run_file))
        if args.conda_prefix:
            inner += ["--conda-prefix", os.path.abspath(args.conda_prefix)]
        submit_pbs(args, f"omni_envs_{run['pipeline']}", inner,
                   os.path.join(run["output_dir"], "logs"), args.ncpus, args.mem_gb)
        return
    prep = prepare(run)
    cmd, env = snakemake_command(prep, 1, None, ["--conda-create-envs-only"], _conda_prefix(args, run))
    sys.exit(subprocess.run(cmd, cwd=prep["manifest"]["_dir"], env=env).returncode)


def cmd_unlock(args):
    run = load_run_file(args.run_file)
    prep = prepare(run, quiet=True)
    cmd, env = snakemake_command(prep, 1, None, [], run.get("conda_prefix"))
    _unlock(cmd, env, prep["manifest"]["_dir"])
    print("Unlocked.")


def _add_submit(p):
    g = p.add_argument_group("scheduler (one job for the whole step)")
    g.add_argument("--submit", choices=["pbs"], help="submit as one PBS Pro job instead of running here")
    g.add_argument("--queue", help="PBS queue (-q)")
    g.add_argument("--account", help="PBS account/project (-A)")
    g.add_argument("--ncpus", type=int, help="CPUs for the job")
    g.add_argument("--mem-gb", type=float, help="memory for the job, GB")
    g.add_argument("--walltime", help="walltime, HH:MM:SS")
    g.add_argument("--select-extra", help="extra terms for the PBS select, e.g. 'host=node02'")
    g.add_argument("--print-only", action="store_true", help="print the job script instead of submitting it")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="omniomics", description="Run OmniOmics pipelines from the command line.")
    sub = ap.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="list the pipelines").set_defaults(func=cmd_list)

    p = sub.add_parser("init", help="write a run file template for a pipeline")
    p.add_argument("pipeline")
    p.add_argument("-o", "--output")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_init)

    db = sub.add_parser("db", help="reference databases").add_subparsers(dest="db_command", required=True)
    p = db.add_parser("list", help="databases of a pipeline and their download options")
    p.add_argument("pipeline")
    p.set_defaults(func=cmd_db_list)
    p = db.add_parser("detect", help="find installed databases under a folder")
    p.add_argument("pipeline")
    p.add_argument("dir")
    p.set_defaults(func=cmd_db_detect)
    p = db.add_parser("download", help="download and install a database")
    p.add_argument("pipeline")
    p.add_argument("key")
    p.add_argument("--option", help="download option id (see: omniomics db list)")
    p.add_argument("--dir", required=True, help="folder to install the database into")
    _add_submit(p)
    p.set_defaults(func=cmd_db_download)

    p = sub.add_parser("run", help="run a pipeline from a run file")
    p.add_argument("run_file")
    p.add_argument("--cores", type=int, help="CPU cores (default: all available)")
    p.add_argument("--ram-gb", type=float, help="memory budget in GB (default: run file, else 90%% of RAM)")
    p.add_argument("-n", "--dry-run", action="store_true", help="show what would run")
    p.add_argument("--attempts", type=int, default=3, help="re-run after a failure up to this many times (default 3)")
    p.add_argument("--conda-prefix", help="folder for the tools' conda environments (default: run file, else ~/.omniomics/conda_envs)")
    p.add_argument("--snakemake-args", nargs=argparse.REMAINDER, help="extra arguments passed to Snakemake")
    _add_submit(p)
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("envs", help="build the conda environments of a run's tools")
    p.add_argument("run_file")
    p.add_argument("--conda-prefix", help="folder for the tools' conda environments")
    _add_submit(p)
    p.set_defaults(func=cmd_envs)

    p = sub.add_parser("unlock", help="remove a stale Snakemake lock left by an interrupted run")
    p.add_argument("run_file")
    p.set_defaults(func=cmd_unlock)
    return ap


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
