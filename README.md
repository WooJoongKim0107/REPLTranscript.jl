# REPLTranscript.jl

`REPLTranscript.jl` records Julia expressions and REPL inputs as timed,
replay-safe `.jl` transcripts.

## Philosophy

- Transcripts are Julia source, not a separate event format.
- Inputs stay executable so transcripts can be inspected, edited, and replayed.
- Timing, results, and errors are comments around the code that produced them.
- Result displays are shortened by default to match the REPL.
    - `full_output=true` records complete displayed results when needed.
- Failed commands stay executable so replay can check whether a bug is fixed.
    - `comment_errors=true` comments out failed commands so replay can continue.

## Example transcript

```julia
#
# ==============================================================================
# Julia REPL transcript session
# Started: 18:40:13	Jun 1 (Mon)
# Julia: 1.11.0
# Working directory: /tmp/demo
# Project: /tmp/demo/Project.toml
# ==============================================================================
#
# %% 18:40:18	Jun 1 (Mon) | elapsed: 0.001s | ok
x = 1 + 2
# 3

# %% 18:40:19	Jun 1 (Mon) | elapsed: 0.001s | ok
map(1:3) do x
    x^2
end
# 3-element Vector{Int64}:
#  1
#  4
#  9

# %% 18:40:21	Jun 1 (Mon) | elapsed: 0.002s | error
error("boom")
# ! error:
# boom

# %% 18:40:35	Jun 1 (Mon) | elapsed: 0.0s | ok
rand(100, 100)
# 100×100 Matrix{Float64}:
#  0.404087   0.396347   0.323287   0.844318  …  0.696734   0.502656   0.576839
#  0.503901   0.278609   0.0216509  0.271467     0.576582   0.619716   0.238256
#  0.0814417  0.894132   0.205239   0.696443     0.788151   0.328918   0.705292
#  0.777041   0.564451   0.231589   0.542225     0.744211   0.32935    0.67573
#  0.864134   0.0374238  0.142672   0.955864     0.797334   0.600287   0.814833
#  0.0386348  0.595244   0.170096   0.532936  …  0.920646   0.185577   0.421696
#  0.416364   0.13232    0.702877   0.46454      0.834676   0.103001   0.159208
#  0.922534   0.527076   0.498415   0.785662     0.988756   0.84432    0.736533
#  0.0737927  0.954479   0.215627   0.853534     0.0828876  0.518387   0.798884
#  0.319092   0.914386   0.0477975  0.033116     0.098512   0.347798   0.741563
#  ⋮                                          ⋱                        
#  0.859808   0.216157   0.56589    0.651353     0.182151   0.464551   0.270316
#  0.34633    0.982367   0.413364   0.448038     0.141613   0.310595   0.740535
#  0.471317   0.343906   0.249089   0.11195      0.4393     0.685135   0.939561
#  0.867168   0.953317   0.369831   0.138946     0.304706   0.183547   0.077965
#  0.0332372  0.209202   0.8796     0.469989  …  0.664753   0.89417    0.544277
#  0.276003   0.468422   0.662208   0.137121     0.0845659  0.0246913  0.347029
#  0.757653   0.844724   0.966046   0.487776     0.553785   0.839258   0.404383
#  0.66137    0.5191     0.200782   0.652689     0.0472294  0.869999   0.820799
#  0.0405229  0.721757   0.871807   0.767747     0.886841   0.864378   0.701159
```

The generated transcript is a Julia file, so it can be replayed with
`include(transcript_path)`.

With `comment_errors=true`, the failed command is commented out so replay can
continue past that entry.

## Usage

### Option 1. Manually record one expression

```julia
using REPLTranscript

@transcript "repl_transcript.jl" x = 1 + 2  # record one expression
```

### Option 2. Automatically record a REPL session

```julia
start_repl_transcript!()
stop_repl_transcript!()
```

Successful entries are written as executable Julia with timing and result
metadata in comments. Result output uses the same shortened display as the REPL
unless `full_output=true` is passed. Failed inputs are written as executable
Julia by default; pass `comment_errors=true` to comment them out instead.

API:

```julia
start_repl_transcript!([io]; full_output=false, comment_errors=false)
```

- `io`: (default=`default_transcript_path()`) transcript destination. Pass a
  path such as `"session.jl"` to choose an explicit file. See
  [below](#default-path-priority) for details.
- `full_output`: (default=`false`) when `false`, result displays are shortened
  to match the REPL. When `true`, complete displayed results are recorded.
- `comment_errors`: (default=`false`) when `false`, failed commands remain
  executable so replay can check whether the same command still fails. When
  `true`, failed commands are commented out so replay can continue.

### Default path priority

1. Explicit path, e.g. `start_repl_transcript!("session.jl")` writes to `session.jl`.
2. Default path, usually `~/.julia/logs/repl_transcript.jl`.

More precisely, `start_repl_transcript!()` writes `repl_transcript.jl` beside
Julia's REPL history file. If `ENV["JULIA_HISTORY"] == "/tmp/history.jl"`, the
default path is `/tmp/repl_transcript.jl`.

## Comparison with existing tools

`REPLTranscript.jl` fills a gap between existing tools:

- Julia's built-in REPL history records input and timestamps, but not elapsed
  time, results, errors, or replay-safe session structure.
- `REPLHistory.jl` helps retrieve history, but does not time executions or
  capture results.
- `Diary.jl` records REPL sessions, but recording is configured only when the
  REPL starts, cannot be changed for an already-running REPL, and does not
  capture output or elapsed time.
- `Replay.jl` replays instructions, but does not create an ongoing timed REPL
  transcript.
- JuliaLogging and LoggingExtras focus on application log events, not REPL
  command/result transcripts.
