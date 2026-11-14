local M = {}

--- Open the instruction input and deliver its submitted value.
---
--- Uses `vim.ui.input`, so any provider that overrides it (dressing.nvim, snacks.nvim,
--- etc.) is respected. A cancelled or blank instruction closes the input.
---
--- @param on_submit fun(instruction: string)
--- @param on_close fun()
function M.open_input(on_submit, on_close)
  vim.ui.input({ prompt = "Instruction: " }, function(instruction)
    if instruction and instruction:find("%S") then
      on_submit(instruction)
    else
      on_close()
    end
  end)
end

--- Open a menu containing opencode models.
---
--- Uses `vim.ui.select`; the effective model is marked with a bullet.
---
---@param models PatchModel[]
---@param selected_model string|nil effective model selector
---@param on_submit fun(model: PatchModel)
function M.open_menu(models, selected_model, on_submit)
  vim.ui.select(models, {
    prompt = "Select model",
    kind = "patch.model",
    format_item = function(model)
      local selector = model.provider .. "/" .. model.id
      local marker = selector == selected_model and "● " or "  "
      return marker .. selector
    end,
  }, function(model)
    if model then
      on_submit(model)
    end
  end)
end

return M
