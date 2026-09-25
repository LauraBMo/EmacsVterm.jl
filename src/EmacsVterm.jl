module EmacsVterm

import REPL
import Base64
import Markdown

"""
    Options

Structure containing the package global options, accessible through
`EmacsVterm.options`.

# Fields
- `markdown::Bool`: whether to send Markdown to Emacs for displaying in a `*julia-help: SYMBOL*` buffer (default: `true`).
- `image::Bool`: whether to send images to Emacs for displaying in `*julia-img*` buffer (default: `false`)
"""
Base.@kwdef mutable struct Options
    markdown::Bool = true
    image::Bool = false
end

struct Display <: AbstractDisplay
    io::IO
end

EMACS = nothing

@doc (@doc Options)
const options = Options()

const user = get(ENV, "USER", "")
vterm_cmd(str) = "\e]$str\e\\"
prompt_suffix() = vterm_cmd("51;A$(user)@$(gethostname()):$(pwd())")
eval_elisp(elisp) = vterm_cmd("51;E$(elisp)")

# The Emacs command that shows a docstring.  One name in one place: the Emacs
# side registers the same string in `vterm-eval-cmds', which is what
# julia-help.el does.
const SHOW_COMMAND = "julia-help-show"

# --- what Emacs is told about a docstring ----------------------------------
#
# A `Markdown.MD` for a docstring is more than its prose.  `REPL.doc' leaves
# the binding, the queried signature and one `DocStr' per matching method in
# `md.meta', each carrying the module, file and line of that method -- all of it
# already computed by the time `display' is called, and thrown away by rendering
# the HTML alone.  See `Base.Docs.doc' and `REPL/src/docview.jl'.

json_escape(s::AbstractString) = sprint() do io
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt32(c), base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
end

# Hand-rolled because the alternative is a dependency: this package's whole
# list is Base64, Markdown and REPL, and a payload is a dozen fields.
json_string(s::AbstractString) = string('"', json_escape(s), '"')

# A field with nothing in it travels as `null', not as `""'.  An empty string is
# *true* in elisp, so `""' for a missing binding prints an empty heading rather
# than skipping it.  A docstring fetched with `?help' goes through
# `REPL.helpmode' and never had `:binding' attached at all.
json_or_null(s::AbstractString) = isempty(s) ? "null" : json_string(s)

"""
    rebase_stdlib(path)

`path` with its `stdlib/<version>/` part replaced by `Sys.STDLIB`, or
`nothing` if it names no stdlib file.

Docstrings in a stdlib record the path the file had on the machine Julia was
built on, e.g.
`/cache/build/builder-amdci4-4/.../usr/share/julia/stdlib/v1.13/LinearAlgebra/src/dense.jl`.
That file does not exist here; the same tree ships under `Sys.STDLIB`, which
already ends in `stdlib/<version>`, so keeping everything from the package
name onwards and rebasing it there finds it.
"""
function rebase_stdlib(path::AbstractString)
    parts = split(path, '/')
    i = findlast(==("stdlib"), parts)
    (i === nothing || length(parts) < i + 2) && return nothing
    joinpath(Sys.STDLIB, parts[(i + 2):end]...)
end

"""
    source_file(path)

A file on this machine holding the code `path` names, or `nothing`.

Three shapes of `path` turn up in real docstrings, tried in this order:

  1. `math.jl` — relative to `<julia>/base`, which `Base.find_source_file`
     resolves;
  2. an absolute path in an ordinary package, which is simply checked;
  3. a stdlib path baked on the build machine, which `rebase_stdlib` fixes.

`nothing` is a real answer, and the honest one: a methods table that offers to
open a file that is not there is worse than one that says where the method is
without pretending it can show you.
"""
function source_file(path::AbstractString)
    isempty(path) && return nothing
    isfile(path) && return path
    resolved = try
        Base.find_source_file(path)
    catch
        nothing
    end
    resolved !== nothing && isfile(resolved) && return resolved
    rebased = rebase_stdlib(path)
    rebased !== nothing && isfile(rebased) && return rebased
    return nothing
end

"""
    method_signature(name, typesig)

How one method is written in the methods table, e.g. `sin(::Number)`.

`REPL.doc' records the signature of each documented method as the tuple type
of its arguments -- `Tuple{Number}` -- and `Union{}` for a binding that has no
methods at all, such as a constant or a macro.  The latter gets the bare name.
"""
function method_signature(name::AbstractString, typesig)
    typesig isa DataType || return name
    typesig <: Tuple || return name
    args = ["::$p" for p in typesig.parameters]
    string(name, "(", join(args, ", "), ")")
end

"""
    doc_payload(md::Markdown.MD)

The JSON that describes `md` to Emacs: the docstring as HTML, plus what the
doc system knows about it.

Fields: `symbol`, `binding`, `module`, `typesig` and `html`, and a list of
`results`, one per documented method, each with `sig`, `typesig`, `module`,
`path`, `file` and `line`.  `file` is `null` when no such file is on this
machine (see `source_file`); `path` is the bare filename, since it is what is
shown beside the signature.
"""
function doc_payload(md::Markdown.MD)
    meta = md.meta
    binding = get(meta, :binding, nothing)
    name = binding === nothing ? "" : string(binding.var)
    results = get(meta, :results, ())

    io = IOBuffer()
    print(io, "{")
    print(io, "\"symbol\":", json_or_null(name), ",")
    print(io, "\"binding\":", json_or_null(binding === nothing ? "" : string(binding)), ",")
    print(io, "\"module\":", json_or_null(binding === nothing ? "" : string(binding.mod)), ",")
    print(io, "\"typesig\":", json_or_null(string(get(meta, :typesig, ""))), ",")
    print(io, "\"html\":", json_string(Markdown.html(md)), ",")
    print(io, "\"results\":[")
    for (i, ds) in enumerate(results)
        i > 1 && print(io, ",")
        typesig = get(ds.data, :typesig, Union{})
        path = string(get(ds.data, :path, ""))
        file = source_file(path)
        print(io, "{")
        print(io, "\"sig\":", json_string(method_signature(name, typesig)), ",")
        print(io, "\"typesig\":", json_string(string(typesig)), ",")
        print(io, "\"module\":", json_or_null(string(get(ds.data, :module, ""))), ",")
        print(io, "\"path\":", json_or_null(basename(path)), ",")
        print(io, "\"file\":", file === nothing ? "null" : json_string(file), ",")
        print(io, "\"line\":", get(ds.data, :linenumber, 0))
        print(io, "}")
    end
    print(io, "]}")
    String(take!(io))
end

# Show rendered Markdown in an Emacs `*julia-help: SYMBOL*` buffer.
#
# The payload is base64 rather than raw JSON because `vterm--eval' splits the
# escape sequence's arguments with `split-string-and-unquote', which would eat
# the backslashes of any JSON string containing a quote.
function Base.display(d::Display, md::Markdown.MD)
    if options.markdown
        write(d.io, eval_elisp("$SHOW_COMMAND documentation application/json \"$(doc_payload(md) |> Base64.base64encode)\""))
    else
        throw(MethodError(display, (d, md)))
    end
    return nothing
end

const IMAGE_MIMES = MIME[
    MIME"image/svg+xml"(),
    MIME"image/png"(),
    MIME"image/jpg"(),
    MIME"image/jpeg"(),
]

function Base.display(d::Display, m::MIME, x)
    if options.image && m in IMAGE_MIMES
        base64 = (m == MIME"image/svg+xml"()) ?
            Base64.base64encode(repr("image/svg+xml", x)) :
            Base64.stringmime(m, x)
        write(d.io, eval_elisp("julia-repl--show image $(string(m)) \"$(base64)\""))
    else
        throw(MethodError(display, (d, m, x)))
    end
    return nothing
end

function Base.display(d::Display, x)
    for mime in IMAGE_MIMES
        if showable(mime, x)
            return display(d, mime, x)
        end
    end
   throw(MethodError(Base.display, (d, x)))
end

"""
    display_on()

Enable multimedia Emacs display.
"""
function display_on()
    if EMACS ∉ Base.Multimedia.displays
        pushdisplay(EMACS)
    end
    return nothing
end

"""
    display_off()

Disable multimedia Emacs display.
"""
function display_off()
    popdisplay(EMACS)
    return nothing
end

function __init__()
    if !(isinteractive() && isdefined(Base, :active_repl))
        return
    end
    begin
        if get(ENV, "INSIDE_EMACS", "") == "vterm"
            @info "Emacs vterm detected"
            repl = Base.active_repl

            if !isdefined(repl,:interface)
                repl.interface = REPL.setup_interface(repl)
            end

            suffix = repl.interface.modes[1].prompt_suffix
            repl.interface.modes[1].prompt_suffix = function ()
                ((isa(suffix,Function) ? suffix() : suffix) * prompt_suffix())
            end

            global EMACS = Display(stdout)
            display_on()
        end
    end
end

end
