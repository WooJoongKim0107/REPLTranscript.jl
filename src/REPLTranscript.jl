module REPLTranscript

import Dates
import REPL

export @transcript, start_repl_transcript!, stop_repl_transcript!, default_transcript_path

const _repl_io = Ref{Any}(nothing)
const _repl_ast = Ref{Any}(nothing)
const _repl_full_output = Ref(false)
const _repl_comment_errors = Ref(false)

timestamp() = Dates.format(Dates.now(), "HH:MM:SS\tu d (e)")

_open_transcript(io::IO) = io, false
function _open_transcript(path::AbstractString)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    return open(path, "a"), true
end

"""
    default_transcript_path()

Return the default REPL transcript path.

Usually this is `~/.julia/logs/repl_transcript.jl`. More precisely, the file is
named `repl_transcript.jl` and is placed beside Julia's REPL history file. For
example, if `ENV["JULIA_HISTORY"] == "/tmp/history.jl"`, the default transcript
path is `/tmp/repl_transcript.jl`.
"""
function default_transcript_path()
    history_path = REPL.find_hist_file()
    return joinpath(dirname(history_path), "repl_transcript.jl")
end

_transcript_path() = something(_repl_io[], default_transcript_path())

function _write_comment(io::IO, text::AbstractString="")
    isempty(text) ? println(io, "#") : println(io, "# ", text)
end

function _write_comment_lines(io::IO, prefix::AbstractString, text::AbstractString)
    for line in split(text, '\n')
        _write_comment(io, prefix * line)
    end
end

function _write_executable(io::IO, text::AbstractString)
    println(io, text)
end

function _write_result(io::IO, result; full_output::Bool=false)
    text = sprint(show, "text/plain", result; context=:limit => !full_output)
    _write_comment_lines(io, "", text)
end

_write_entry_end(io::IO) = println(io)

function _write_transcript_header(io_spec)
    output_io, should_close = _open_transcript(io_spec)
    try
        _write_comment(output_io)
        _write_comment(output_io, "==============================================================================")
        _write_comment(output_io, "Julia REPL transcript session")
        _write_comment(output_io, "Started: " * timestamp())
        _write_comment(output_io, "Julia: " * string(VERSION))
        _write_comment(output_io, "Working directory: " * pwd())
        _write_comment(output_io, "Project: " * Base.active_project())
        _write_comment(output_io, "==============================================================================")
        _write_comment(output_io)
    finally
        should_close && try close(output_io) catch; end
    end
end

function _drop_line_numbers!(expr)
    if expr isa Expr
        filter!(arg -> !(arg isa LineNumberNode), expr.args)
        foreach(_drop_line_numbers!, expr.args)
    end
    return expr
end

function _parse_error_source(err)
    try
        source = getfield(getfield(err, :detail), :source)
        code = getfield(source, :code)
        code isa AbstractString && return String(code)
    catch
    end
    return nothing
end

function _expr_to_string(expr)
    if expr isa Expr && expr.head === :error && length(expr.args) == 1
        source = _parse_error_source(expr.args[1])
        source !== nothing && return source
    end

    expr_clean = _drop_line_numbers!(Base.remove_linenums!(copy(expr)))
    if expr_clean isa Expr && expr_clean.head === :toplevel
        return join(_expr_to_string.(expr_clean.args), '\n')
    end
    return string(expr_clean)
end

function _write_error(io::IO, expr_str::String, error_str::String; comment_errors::Bool=false)
    if comment_errors
        _write_comment(io, "! input:")
        _write_comment_lines(io, "! ", expr_str)
    else
        _write_executable(io, expr_str)
    end
    _write_comment(io, "! error:")
    _write_comment_lines(io, "! ", error_str)
end

function _record_timed(
    f,
    io_spec,
    expr_str::String;
    replay::Bool=true,
    full_output::Bool=false,
    comment_errors::Bool=false,
)
    output_io, should_close = _open_transcript(io_spec)
    try
        start_time = time()
        started = timestamp()
        try
            result = f()
            elapsed = time() - start_time
            try
                status = replay ? "ok" : "ok | not replayed"
                _write_comment(output_io, "%% " * started * " | elapsed: " * string(round(elapsed; digits=3)) * "s | " * status)
                if replay
                    _write_executable(output_io, expr_str)
                else
                    _write_comment(output_io, "! input:")
                    _write_comment_lines(output_io, "! ", expr_str)
                end
                _write_result(output_io, result; full_output)
                _write_entry_end(output_io)
            catch transcript_err
                @warn "REPLTranscript: failed to write result to transcript" exception=transcript_err
            end
            return result
        catch eval_err
            elapsed = time() - start_time
            try
                error_str = sprint(showerror, eval_err, catch_backtrace())
                status = comment_errors ? "error | not replayed" : "error"
                _write_comment(output_io, "%% " * started * " | elapsed: " * string(round(elapsed; digits=3)) * "s | " * status)
                _write_error(output_io, expr_str, error_str; comment_errors)
                _write_entry_end(output_io)
            catch transcript_err
                @warn "REPLTranscript: failed to write error to transcript" exception=transcript_err
            end
            rethrow()
        end
    finally
        should_close && try close(output_io) catch; end
    end
end

function _transcript_expand(io, expr)
    expr_str = _expr_to_string(expr)
    record_timed = GlobalRef(@__MODULE__, :_record_timed)
    if expr isa Expr && expr.head == :(=)
        var_name, rhs = expr.args[1], expr.args[2]
        quote
            $(esc(var_name)) = $record_timed($(esc(io)), $expr_str) do
                $(esc(rhs))
            end
        end
    else
        quote
            $record_timed($(esc(io)), $expr_str) do
                $(esc(expr))
            end
        end
    end
end

"""
    @transcript [io] expr

Evaluate `expr` and append a replay-safe timed transcript entry to `io`.

Arguments:
- `io`: (default=`"repl_transcript.jl"`) transcript destination. Pass a path such as
  `"session.jl"` to choose an explicit file.
- `expr`: Julia expression to evaluate and record.

The expression is written as executable Julia. Timing metadata and displayed
results are written as comments. If `expr` throws, the failed expression is
still written as executable Julia, followed by the error as comments.
"""
macro transcript(io, expr)
    _transcript_expand(io, expr)
end

macro transcript(expr)
    _transcript_expand("repl_transcript.jl", expr)
end

function _eval_repl(
    mod::Module,
    ast,
    expr_str::String,
    io_spec,
    replay::Bool,
    full_output::Bool,
    comment_errors::Bool,
)
    _record_timed(io_spec, expr_str; replay, full_output, comment_errors) do
        Core.eval(mod, REPL.softscope(ast))
    end
end

function _is_replayable_repl_ast(ast)
    ast isa Expr || return true
    if ast.head === :toplevel
        return all(_is_replayable_repl_ast, ast.args)
    elseif ast.head === :call && !isempty(ast.args)
        return ast.args[1] ∉ (:start_repl_transcript!, :stop_repl_transcript!, :exit, :quit)
    end
    return true
end

function _repl_transform(ast)
    expr_str = _expr_to_string(ast)
    replay = _is_replayable_repl_ast(ast)
    _repl_ast[] = ast
    eval_repl = GlobalRef(@__MODULE__, :_eval_repl)
    repl_ast = GlobalRef(@__MODULE__, :_repl_ast)
    transcript_path = GlobalRef(@__MODULE__, :_transcript_path)
    repl_full_output = GlobalRef(@__MODULE__, :_repl_full_output)
    repl_comment_errors = GlobalRef(@__MODULE__, :_repl_comment_errors)
    return :($eval_repl(@__MODULE__, $repl_ast[], $expr_str, $transcript_path(), $replay, $repl_full_output[], $repl_comment_errors[]))
end

function _current_ast_transforms()
    if isdefined(Base, :active_repl_backend)
        backend = Base.active_repl_backend
        if !isnothing(backend) && hasproperty(backend, :ast_transforms)
            return backend.ast_transforms
        end
    end
    return REPL.repl_ast_transforms
end

function _insert_repl_transform!(transforms)
    any(xf -> xf === _repl_transform, transforms) && return transforms
    softscope_idx = findfirst(xf -> xf === REPL.softscope, transforms)
    if isnothing(softscope_idx)
        pushfirst!(transforms, _repl_transform)
    else
        insert!(transforms, softscope_idx, _repl_transform)
    end
    return transforms
end

function _remove_repl_transform!(transforms)
    filter!(xf -> xf !== _repl_transform, transforms)
    return transforms
end

"""
    start_repl_transcript!([io]; full_output=false, comment_errors=false)

Record each Julia REPL input as a replay-safe timed Julia transcript.

Arguments:
- `io`: (default=`default_transcript_path()`) transcript destination. Pass a path such as
  `"session.jl"` to choose an explicit file.
- `full_output`: (default=`false`) when `false`, result displays are shortened
  to match the REPL. When `true`, complete displayed results are recorded.
- `comment_errors`: (default=`false`) when `false`, failed commands remain
  executable so replay can check whether the same command still fails. When
  `true`, failed commands are commented out so replay can continue.

Default path priority:
1. Explicit path, e.g. `start_repl_transcript!("session.jl")` writes to `session.jl`.
2. Default path, usually `~/.julia/logs/repl_transcript.jl`.

More precisely, `start_repl_transcript!()` writes `repl_transcript.jl` beside
Julia's REPL history file. If `ENV["JULIA_HISTORY"] == "/tmp/history.jl"`, the
default path is `/tmp/repl_transcript.jl`.
"""
function start_repl_transcript!(io=default_transcript_path(); full_output::Bool=false, comment_errors::Bool=false)
    transforms = _current_ast_transforms()
    _repl_io[] = io
    _repl_full_output[] = full_output
    _repl_comment_errors[] = comment_errors
    _write_transcript_header(io)
    _insert_repl_transform!(transforms)
    println("Recording Julia REPL transcript: ", io)
    return nothing
end

"""
    stop_repl_transcript!()

Stop automatic REPL transcript recording for the current Julia session.

This removes REPLTranscript's REPL transform and resets REPL transcript options
such as `full_output` and `comment_errors` to their defaults.
"""
function stop_repl_transcript!()
    _remove_repl_transform!(_current_ast_transforms())
    _repl_full_output[] = false
    _repl_comment_errors[] = false
    return nothing
end

end
