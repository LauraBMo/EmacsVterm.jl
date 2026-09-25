# EmacsVterm

Better integration of Julia REPL with Emacs vterm terminal.

## Installation

1. In Julia prompt type:
   ```
   julia> ]add EmacsVterm
   ```

2. Add the following to `~/.julia/config/startup.jl`:

   ```julia
   atreplinit() do repl
       @eval using EmacsVterm
       # Optionally set EmacsVterm.options as you like (see below)
   end
   ```

3. Configure [julia-repl](https://github.com/tpapp/julia-repl) to use
   the `vterm` backend by putting:

   ```elisp
   (julia-repl-set-terminal-backend 'vterm)
   ```
   to your Emacs config.

4. Install [julia-help.el](https://github.com/LauraBMo/julia-help.el), the Emacs
   side of the documentation display.  Docstrings are now rendered from the
   metadata Julia sends (the binding, the signature, one row per method with its
   source line, and working `@ref` links), and this is the package that receives
   it:

   ```elisp
   (package! julia-help :recipe (:host github :repo "LauraBMo/julia-help.el"))
   ```

   Without it `@doc` reports an unknown `julia-help-show` command and shows
   nothing: `julia-repl`'s handler no longer draws documentation.

## Features

- You can jump between prompts in `*julia*` REPL buffers with `C-c
  C-p` and `C-c C-n`.

- Julia REPL informs Emacs about its working directory. Therefore,
  after changing directory in Julia, opening file in Emacs (e.g. `C-x
  C-f`) starts in that directory.

- Documentation (`@doc ...` invocation or `C-c C-d` in `julia-mode`
  buffers with `julia-repl` enabled) is shown in a separate Emacs
  buffer.

  To disable this functionality, run:
  ```julia
  EmacsVterm.options.markdown = false
  ```

  If you are not happy with where Emacs chooses to display the
  `*julia-help: SYMBOL*` buffer, you can configure it via a "display action".
  For example, the following piece of code in `init.el` ensures that
  if the buffer for a symbol is already shown somewhere, the same
  buffer is reused; otherwise, a right side window with an appropriate
  width will be created.

  ```elisp
  (add-to-list 'display-buffer-alist '("\\*julia-help"
				     (display-buffer-reuse-window display-buffer-in-side-window)
				     (side . right) (window-width . 80)))
  ```

- Images can be shown in the `*julia-img*` Emacs buffer. This
  functionality is not enabled by default. Enable it with:

  ```julia
  EmacsVterm.options.image = true
  ```

- In addition to `EmacsVterm.options`, the whole Emacs-based
  Multimedia I/O can be disabled (resp. enabled) with:

  ```julia
  EmacsVterm.display_off()
  EmacsVterm.display_on()
  ```
