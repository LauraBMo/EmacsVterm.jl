module EmacsVterm

import REPL
import Base64
import Markdown
import JSON

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

# A field's JSON value: `null' when it is absent or empty, the string otherwise.
# `""' is *true* in elisp, so an empty field must not travel as itself.
function json_or_null(x)
    s = string(something(x, ""))
    return isempty(s) ? nothing : s
end

"""
    rebase_stdlib(path)

`path` rebased onto `Sys.STDLIB`, or `nothing` if `path` is not a stdlib path.

A stdlib docstring records the path the file had on the Julia build machine:

    julia> Base.Docs.doc(Base.Docs.Binding(LinearAlgebra, :dot), Union{}).meta[:results][1].data[:path]
    "/cache/build/builder-amdci4-4/julialang/julia-ci/usr/share/julia/stdlib/v1.13/LinearAlgebra/src/generic.jl"
"""
function rebase_stdlib(path::AbstractString)
    parts = split(path, "julia/stdlib")
    length(parts) == 1 && return nothing
    rest = split(parts[end], '/'; keepempty=false)
    length(rest) < 2 && return nothing
    return joinpath(Sys.STDLIB, rest[2:end]...)   # rest[1] is the version
end

"""
    source_file(path)

A local file holding the code named by docstring source path `path`, or
`nothing` if there is none.

Tries `path` relative to `<julia>/base` (`Base.find_source_file`), then as an
absolute path, then rebased from the build machine (`rebase_stdlib`).
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

One methods-table entry, e.g. `sin(::Number)`.

A tuple type becomes `name(::T, ...)`, one `::T` per element; a non-tuple gives
`name` alone.
"""
function method_signature(name::AbstractString, typesig)
    (typesig isa DataType && typesig <: Tuple) || return name
    args = join(("::$p" for p in typesig.parameters), ", ")
    return "$name($args)"
end

# One methods-table row. `path` is the bare filename, `file` where to open it.
function method_entry(name, ds)
    data = ds.data
    typesig = get(data, :typesig, Union{})
    path = string(get(data, :path, ""))
    return (;
        :sig => method_signature(name, typesig),
        :typesig => string(typesig),
        :module => json_or_null(get(data, :module, nothing)),
        :path => json_or_null(basename(path)),
        :file => source_file(path),
        :line => get(data, :linenumber, 0))
end

"""
    doc_payload(md::Markdown.MD)

The JSON sent to Emacs: `symbol`, `binding`, `module`, `typesig`, `html`, and
`results`, one entry per method with `sig`, `typesig`, `module`, `path`, `file`
and `line` (`file` is `null` when no such file exists).
"""
function doc_payload(md::Markdown.MD)
    meta = md.meta
    binding = get(meta, :binding, nothing)
    # A docstring fetched with `?help' has no binding, hence no name or module.
    name, namespace =
        binding === nothing ? ("", "") : (string(binding.var), string(binding.mod))
    # `:typesig' is the *queried* signature, `Union{}' when none was asked for
    # (a bare `?name'), so it travels as `null' rather than as a string for
    # Emacs to recognise.
    typesig = get(meta, :typesig, nothing)
    JSON.json((;
        :symbol => json_or_null(name),
        :binding => json_or_null(binding),
        :module => json_or_null(namespace),
        :typesig => typesig === Union{} ? nothing : json_or_null(typesig),
        :html => Markdown.html(md),
        :results => map(ds -> method_entry(name, ds), get(meta, :results, ())),
    ))
end

# Through julia-repl's `julia-repl--show'.  JSON only when julia-repl advertised
# it in `JULIA_REPL_SHOW'; older ones take HTML.  Base64, because `vterm--eval'
# splits the arguments with `split-string-and-unquote' and would eat backslashes.
function Base.display(d::Display, md::Markdown.MD)
    options.markdown || throw(MethodError(display, (d, md)))
    if "documentation/application/json" in split(get(ENV, "JULIA_REPL_SHOW", ""), ',')
        payload, mime = doc_payload(md), "application/json"
    else
        payload, mime = Markdown.html(md), "text/html"
    end
    write(d.io, eval_elisp("julia-repl--show documentation $mime \"$(Base64.base64encode(payload))\""))
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

            if !isdefined(repl, :interface)
                repl.interface = REPL.setup_interface(repl)
            end

            suffix = repl.interface.modes[1].prompt_suffix
            repl.interface.modes[1].prompt_suffix = function ()
                ((isa(suffix, Function) ? suffix() : suffix) * prompt_suffix())
            end

            global EMACS = Display(stdout)
            display_on()
        end
    end
end

end
