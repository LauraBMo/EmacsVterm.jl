using EmacsVterm
using Test

import Base64
import Markdown
import REPL
using Base.Docs

# These tests do not need Emacs.  They check the two things this package can
# get wrong on its own: the JSON it builds, and the escape sequence it writes.
# Whether Emacs then renders it well is the Emacs side's business.

@testset "EmacsVterm.jl" begin

    @testset "json_or_null" begin
        # What has nothing in it must travel as `null', because an empty string
        # is *true* in elisp and would print an empty field instead of none.
        @test EmacsVterm.json_or_null("") === nothing
        @test EmacsVterm.json_or_null(nothing) === nothing
        @test EmacsVterm.json_or_null("sin") == "sin"
        @test EmacsVterm.json_or_null(:sin) == "sin"
    end

    @testset "method_signature" begin
        @test EmacsVterm.method_signature("sin", Tuple{Number}) == "sin(::Number)"
        @test EmacsVterm.method_signature("map", Tuple{Any,Any,Vararg{Any}}) ==
              "map(::Any, ::Any, ::Vararg{Any})"
        @test EmacsVterm.method_signature("sin", Tuple{}) == "sin()"
        # Union{} is what a binding with no methods reports -- a constant, a
        # macro -- and it is not a tuple type, so it gets the bare name.
        @test EmacsVterm.method_signature("pi", Union{}) == "pi"
    end

    @testset "source_file" begin
        # 1. relative to <julia>/base
        @test endswith(EmacsVterm.source_file("math.jl"), joinpath("base", "math.jl"))
        @test isfile(EmacsVterm.source_file("math.jl"))

        # 2. a path that is simply not there
        @test EmacsVterm.source_file("/no/such/file.jl") === nothing
        @test EmacsVterm.source_file("") === nothing
    end

    @testset "rebase_stdlib" begin
        # 3. a stdlib path baked on the build machine.  The version in the
        #    recorded path is dropped rather than trusted: Sys.STDLIB already
        #    carries the one that is installed here.
        recorded = "/cache/build/builder-amdci4-4/julialang/julia-ci/usr/share/julia" *
                   "/stdlib/v1.0/LinearAlgebra/src/generic.jl"
        rebased = EmacsVterm.rebase_stdlib(recorded)
        @test rebased == joinpath(Sys.STDLIB, "LinearAlgebra", "src", "generic.jl")
        @test isfile(rebased)
        @test EmacsVterm.source_file(recorded) == rebased

        # Not a stdlib path at all.  `stdlib' on its own is not enough: the
        # build path is anchored at `julia/stdlib', so a directory that merely
        # happens to be called `stdlib' does not match.
        @test EmacsVterm.rebase_stdlib("/home/someone/Package/src/x.jl") === nothing
        @test EmacsVterm.rebase_stdlib("stdlib") === nothing
        @test EmacsVterm.rebase_stdlib("/home/someone/src/stdlib/x.jl") === nothing
        # The marker with no package after it is not a file.
        @test EmacsVterm.rebase_stdlib("julia/stdlib") === nothing
        @test EmacsVterm.rebase_stdlib("julia/stdlib/v1.13") === nothing
    end

    @testset "doc_payload for a function with methods" begin
        md = Docs.doc(Docs.Binding(Base, :sin), Union{})
        payload = EmacsVterm.doc_payload(md)

        @test occursin("\"symbol\":\"sin\"", payload)
        @test occursin("\"binding\":\"Base.sin\"", payload)
        @test occursin("\"module\":\"Base\"", payload)
        @test occursin("\"typesig\":null", payload)      # no signature queried

        # The signature is built from the tuple type Julia records, rather
        # than left blank.
        @test occursin("\"sig\":\"sin(::Number)\"", payload)
        @test occursin("\"module\":\"Base.Math\"", payload)
        @test occursin("\"path\":\"math.jl\"", payload)
        @test occursin("\"line\":425", payload)
        @test occursin("\"file\":\"/", payload)          # resolved, not null

        # The docstring really is in there.
        @test occursin("Compute sine", payload)
    end

    @testset "doc_payload for a constant" begin
        payload = EmacsVterm.doc_payload(Docs.doc(Docs.Binding(Base, :pi), Union{}))
        @test occursin("\"symbol\":\"pi\"", payload)
        @test occursin("\"sig\":\"pi\"", payload)        # no methods, so no args
        @test occursin("\"typesig\":null", payload)
    end

    @testset "doc_payload keeps a queried signature" begin
        # Only `Union{}' means "none asked for": a signature given by name is
        # sent as the string Julia renders, and must not be suppressed.
        md = Docs.doc(Docs.Binding(Base, :sin), Tuple{typeof(sin), Float64})
        @test occursin("\"typesig\":\"Tuple{typeof(sin), Float64}\"",
                       EmacsVterm.doc_payload(md))
    end

    @testset "doc_payload escapes what it embeds" begin
        # A docstring is arbitrary text and it lands inside a JSON string.
        @eval begin
            "quote \" backslash \\ ctrl \x01 and a unicode λ"
            hostile_doc() = nothing
        end
        payload = EmacsVterm.doc_payload(Docs.doc(Docs.Binding(Main, :hostile_doc), Union{}))

        # The invariant worth having: the payload is JSON with no raw control
        # character anywhere in it, so no field can break the envelope.
        @test !occursin(r"[\x00-\x1f\x7f]", payload)
        @test endswith(payload, "]}")

        # Note which layer escapes what.  The docstring's quote reaches the
        # payload as `&quot;', because Markdown.html escapes it long before
        # JSON.jl sees the string -- so asserting `\"' here would be asserting
        # something that correctly never happens.
        @test occursin("&quot;", payload)
        @test occursin("\\\\", payload)      # one backslash, escaped for JSON
        @test occursin("\\u0001", payload)
        @test occursin("λ", payload)
    end

    @testset "doc_payload for a docstring with no annotation" begin
        # What `?help' hands over.  Julia's help mode displays an MD of its own
        # making, which never had `:binding' attached, so there is no symbol,
        # module, signature or method to report.  These must travel as null:
        # an empty string is *true* in elisp, so "" would print an empty
        # heading, an empty "Defined in:" and an empty "Signature" line.
        md = Markdown.MD(Any[Markdown.parse("Compute sine of `x`.")])
        payload = EmacsVterm.doc_payload(md)

        @test occursin("\"symbol\":null", payload)
        @test occursin("\"binding\":null", payload)
        @test occursin("\"module\":null", payload)
        @test occursin("\"typesig\":null", payload)
        @test occursin("\"results\":[]", payload)
        @test occursin("Compute sine", payload)
    end

    @testset "display writes the escape sequence Emacs expects" begin
        md = Docs.doc(Docs.Binding(Base, :sin), Union{})
        was = EmacsVterm.options.markdown
        EmacsVterm.options.markdown = true
        try
            # When julia-repl advertises that it can render JSON, that is what
            # goes; what travels is base64, so the command's arguments survive
            # `split-string-and-unquote' on the Emacs side whatever the
            # docstring held.
            Base.withenv("JULIA_REPL_SHOW" =>
                         "documentation/text/html,documentation/application/json") do
                io = IOBuffer()
                Base.display(EmacsVterm.Display(io), md)
                written = String(take!(io))

                @test startswith(written, "\e]51;E")
                @test endswith(written, "\e\\")
                @test occursin("julia-repl--show documentation application/json \"",
                               written)

                b64 = match(r"\"([A-Za-z0-9+/=]+)\"", written)
                @test b64 !== nothing
                @test String(Base64.base64decode(b64[1])) == EmacsVterm.doc_payload(md)
            end

            # An older julia-repl advertises nothing and gets plain HTML, as it
            # always did.
            Base.withenv("JULIA_REPL_SHOW" => nothing) do
                io = IOBuffer()
                Base.display(EmacsVterm.Display(io), md)
                written = String(take!(io))

                @test occursin("julia-repl--show documentation text/html \"", written)
                b64 = match(r"\"([A-Za-z0-9+/=]+)\"", written)
                @test b64 !== nothing
                @test String(Base64.base64decode(b64[1])) == Markdown.html(md)
            end
        finally
            EmacsVterm.options.markdown = was
        end
    end

    @testset "display declines when markdown is off" begin
        md = Docs.doc(Docs.Binding(Base, :sin), Union{})
        was = EmacsVterm.options.markdown
        EmacsVterm.options.markdown = false
        try
            @test_throws MethodError Base.display(EmacsVterm.Display(IOBuffer()), md)
        finally
            EmacsVterm.options.markdown = was
        end
    end
end
