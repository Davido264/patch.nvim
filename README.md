# patch.nvim

This is a slop fork of
[timothyckl/patch.nvim](https://github.com/timothyckl/patch.nvim) (also vibed).

It uses opencode instead of pi, and uses the neovim's default selection and user
input api instead of relying on
[nui.nvim](https://github.com/MunifTanjim/nui.nvim)

## Requirements

- Neovim 0.10+
- opencode 2.2+. Requests go to opencode's background service
  (`opencode service`), which is started automatically if it is not running.
  Models and credentials come from your opencode setup; the default model is the
  service's default unless you pass `model = "provider/model"` to `setup()` or
  pick one with `:PatchMenu`.
