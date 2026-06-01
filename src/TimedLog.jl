module TimedLog

import Dates
import REPL

export @timelog, enable_repl_log!, disable_repl_log!, default_timelog_path

const _repl_io = Ref{Any}(nothing)
const _repl_ast = Ref{Any}(nothing)
const _repl_full_output = Ref(false)
const _repl_comment_errors = Ref(false)

timestamp() = Dates.format(Dates.now(), "HH:MM:SS\tu d (e)")

_open_log(io::IO) = io, false
function _open_log(path::AbstractString)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    return open(path, "a"), true
end

"""
    default_timelog_path()

Return the default REPL timelog path.

Usually this is `~/.julia/logs/timelog.jl`. More precisely, the file is named
`timelog.jl` and is placed beside Julia's REPL history file. For example, if
`ENV["JULIA_HISTORY"] == "/tmp/history.jl"`, the default timelog path is
`/tmp/timelog.jl`.
"""
function default_timelog_path()
    history_path = REPL.find_hist_file()
    return joinpath(dirname(history_path), "timelog.jl")
end

_repl_log_path() = something(_repl_io[], default_timelog_path())

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

function _write_repl_header(io_spec)
    output_io, should_close = _open_log(io_spec)
    try
        _write_comment(output_io)
        _write_comment(output_io, "==============================================================================")
        _write_comment(output_io, "Julia REPL timelog session")
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

function _run_timed(
    f,
    io_spec,
    expr_str::String;
    replay::Bool=true,
    full_output::Bool=false,
    comment_errors::Bool=false,
)
    output_io, should_close = _open_log(io_spec)
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
            catch log_err
                @warn "timelog: failed to write result to log" exception=log_err
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
            catch log_err
                @warn "timelog: failed to write error to log" exception=log_err
            end
            rethrow()
        end
    finally
        should_close && try close(output_io) catch; end
    end
end

function _timelog_expand(io, expr)
    expr_str = _expr_to_string(expr)
    run_timed = GlobalRef(@__MODULE__, :_run_timed)
    if expr isa Expr && expr.head == :(=)
        var_name, rhs = expr.args[1], expr.args[2]
        quote
            $(esc(var_name)) = $run_timed($(esc(io)), $expr_str) do
                $(esc(rhs))
            end
        end
    else
        quote
            $run_timed($(esc(io)), $expr_str) do
                $(esc(expr))
            end
        end
    end
end

"""
    @timelog [io] expr

Evaluate `expr` and append a replay-safe timed transcript entry to `io`.

Arguments:
- `io`: (default=`"timelog.jl"`) log destination. Pass a path such as
  `"session.jl"` to choose an explicit file.
- `expr`: Julia expression to evaluate and log.

The expression is written as executable Julia. Timing metadata and displayed
results are written as comments. If `expr` throws, the failed expression is
still written as executable Julia, followed by the error as comments.
"""
macro timelog(io, expr)
    _timelog_expand(io, expr)
end

macro timelog(expr)
    _timelog_expand("timelog.jl", expr)
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
    _run_timed(io_spec, expr_str; replay, full_output, comment_errors) do
        Core.eval(mod, REPL.softscope(ast))
    end
end

function _is_replayable_repl_ast(ast)
    ast isa Expr || return true
    if ast.head === :toplevel
        return all(_is_replayable_repl_ast, ast.args)
    elseif ast.head === :call && !isempty(ast.args)
        return ast.args[1] ∉ (:enable_repl_log!, :disable_repl_log!, :exit, :quit)
    end
    return true
end

function _repl_transform(ast)
    expr_str = _expr_to_string(ast)
    replay = _is_replayable_repl_ast(ast)
    _repl_ast[] = ast
    eval_repl = GlobalRef(@__MODULE__, :_eval_repl)
    repl_ast = GlobalRef(@__MODULE__, :_repl_ast)
    repl_path = GlobalRef(@__MODULE__, :_repl_log_path)
    repl_full_output = GlobalRef(@__MODULE__, :_repl_full_output)
    repl_comment_errors = GlobalRef(@__MODULE__, :_repl_comment_errors)
    return :($eval_repl(@__MODULE__, $repl_ast[], $expr_str, $repl_path(), $replay, $repl_full_output[], $repl_comment_errors[]))
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
    enable_repl_log!([io]; full_output=false, comment_errors=false)

Log each Julia REPL input as a replay-safe timed Julia transcript.

Arguments:
- `io`: (default=`default_timelog_path()`) log destination. Pass a path such as
  `"session.jl"` to choose an explicit file.
- `full_output`: (default=`false`) when `false`, result displays are shortened
  to match the REPL. When `true`, complete displayed results are logged.
- `comment_errors`: (default=`false`) when `false`, failed commands remain
  executable so replay can check whether the same command still fails. When
  `true`, failed commands are commented out so replay can continue.

Default path priority:
1. Explicit path, e.g. `enable_repl_log!("session.jl")` writes to `session.jl`.
2. Default path, usually `~/.julia/logs/timelog.jl`.

More precisely, `enable_repl_log!()` writes `timelog.jl` beside Julia's REPL
history file. If `ENV["JULIA_HISTORY"] == "/tmp/history.jl"`, the default path
is `/tmp/timelog.jl`.
"""
function enable_repl_log!(io=default_timelog_path(); full_output::Bool=false, comment_errors::Bool=false)
    transforms = _current_ast_transforms()
    _repl_io[] = io
    _repl_full_output[] = full_output
    _repl_comment_errors[] = comment_errors
    _write_repl_header(io)
    _insert_repl_transform!(transforms)
    println("Recording Julia REPL timelog: ", io)
    return nothing
end

"""
    disable_repl_log!()

Stop automatic REPL timelog recording for the current Julia session.

This removes TimedLog's REPL transform and resets REPL logging options such as
`full_output` and `comment_errors` to their defaults.
"""
function disable_repl_log!()
    _remove_repl_transform!(_current_ast_transforms())
    _repl_full_output[] = false
    _repl_comment_errors[] = false
    return nothing
end

end
