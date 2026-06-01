using Test
using REPLTranscript
import REPL

@testset "REPLTranscript" begin
    path = tempname() * ".jl"
    @transcript path replay_value = 1 + 2
    include(path)
    @test replay_value == 3
    text = read(path, String)
    @test occursin("replay_value = 1 + 2", text)
    @test occursin("replay_value = 1 + 2\n# 3\n\n", text)
    @test !occursin("# => 3", text)
    @test !occursin("replay_value = 1 + 2\n\n# 3", text)
    rm(path; force=true)

    path = tempname() * ".jl"
    REPLTranscript._record_timed(path, "collect(1:10000)") do
        collect(1:10000)
    end
    @test count(==('\n'), read(path, String)) < 100
    rm(path; force=true)

    path = tempname() * ".jl"
    REPLTranscript._record_timed(path, "collect(1:10000)"; full_output=true) do
        collect(1:10000)
    end
    @test count(==('\n'), read(path, String)) > 10000
    rm(path; force=true)

    path = tempname() * ".jl"
    try
        @transcript path error("boom")
    catch
    end
    text = read(path, String)
    @test occursin("error(\"boom\")", text)
    @test !occursin("# ! error(\"boom\")", text)
    @test_throws LoadError include(path)
    rm(path; force=true)

    path = tempname() * ".jl"
    try
        REPLTranscript._record_timed(path, "error(\"boom\")"; comment_errors=true) do
            error("boom")
        end
    catch
    end
    text = read(path, String)
    @test occursin("# ! error(\"boom\")", text)
    @test occursin("error | not replayed", text)
    include(path)
    rm(path; force=true)

    path = tempname() * ".jl"
    REPLTranscript.start_repl_transcript!(path)
    @test !any(==("# "), split(read(path, String), '\n'))
    REPLTranscript.stop_repl_transcript!()
    rm(path; force=true)

    path = tempname() * ".jl"
    REPLTranscript.start_repl_transcript!(path; full_output=true)
    @test REPLTranscript._repl_full_output[]
    REPLTranscript.stop_repl_transcript!()
    @test !REPLTranscript._repl_full_output[]
    rm(path; force=true)

    path = tempname() * ".jl"
    REPLTranscript.start_repl_transcript!(path; comment_errors=true)
    @test REPLTranscript._repl_comment_errors[]
    REPLTranscript.stop_repl_transcript!()
    @test !REPLTranscript._repl_comment_errors[]
    rm(path; force=true)

    path = tempname() * ".jl"
    REPLTranscript._repl_io[] = path
    REPLTranscript._repl_comment_errors[] = true
    ast = Base.parse_input_line("assert false \"what\"")
    try
        Core.eval(Main, REPL.softscope(REPLTranscript._repl_transform(ast)))
    catch
    end
    text = read(path, String)
    @test occursin("# ! assert false \"what\"", text)
    @test !occursin("Expr(:error", text)
    include(path)
    REPLTranscript._repl_comment_errors[] = false
    rm(path; force=true)
end
