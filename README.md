# TimedLog.jl

`TimedLog.jl` records Julia expressions and REPL inputs as timed,
replay-safe `.jl` transcripts.

The package fills a gap between existing tools:

- Julia's built-in REPL history records input and timestamps, but not results,
  errors, or replay-safe session structure.
- `REPLHistory.jl` helps retrieve history, but does not time executions or
  capture results.
- `Replay.jl` replays instructions, but does not create an ongoing timed REPL
  transcript.
- JuliaLogging and LoggingExtras focus on application log events, not REPL
  command/result transcripts.

## Usage

```julia
using TimedLog

@timelog "timelog.jl" x = 1 + 2

enable_repl_log!()              # logs to ~/.julia/logs/timelogs.jl by default
enable_repl_log!("session.jl")  # explicit path
enable_repl_log!("full.jl"; full_output=true)
enable_repl_log!("safe.jl"; comment_errors=true)
disable_repl_log!()
```

Successful entries are written as executable Julia with timing and result
metadata in comments. Result output uses the same shortened display as the REPL
unless `full_output=true` is passed. Failed inputs are written as executable
Julia by default; pass `comment_errors=true` to comment them out instead.

The generated log is a Julia file, so it can be replayed with `include(log)`.

## Example log

```julia
#
# ==============================================================================
# Julia REPL timelog session
# Started: 18:40:13	Mon 1 (Jun)
# Julia: 1.11.0
# Working directory: /tmp/demo
# Project: /tmp/demo/Project.toml
# ==============================================================================
#
# %% 18:40:18	Mon 1 (Jun) | elapsed: 0.001s | ok
x = 1 + 2
# 3

# %% 18:40:21	Mon 1 (Jun) | elapsed: 0.002s | error
error("boom")
# ! error:
# boom

```

With `comment_errors=true`, the failed command is commented out so replay can
continue past that entry.
