local eq = MiniTest.expect.equality
local ui
local original_input
local original_select

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_input = vim.ui.input
      original_select = vim.ui.select
      package.loaded["patch.ui"] = nil
      ui = require("patch.ui")
    end,
    post_case = function()
      vim.ui.input = original_input
      vim.ui.select = original_select
      package.loaded["patch.ui"] = nil
    end,
  },
})

local function answer_input(value)
  vim.ui.input = function(opts, on_confirm)
    eq(opts.prompt, "Instruction: ")
    on_confirm(value)
  end
end

local function open_input()
  local calls = {}
  ui.open_input(function(instruction)
    calls.submitted = instruction
  end, function()
    calls.closed = true
  end)
  return calls
end

T["submits a non-blank instruction"] = function()
  answer_input("add type hints")
  eq(open_input(), { submitted = "add type hints" })
end

T["closes on a cancelled or blank instruction"] = function()
  answer_input(nil)
  eq(open_input(), { closed = true })

  answer_input("   ")
  eq(open_input(), { closed = true })
end

T["lists models and marks the effective one"] = function()
  local models = {
    { provider = "openai", id = "gpt-5", name = "gpt-5" },
    { provider = "opencode", id = "big-pickle", name = "big-pickle" },
  }
  local labels = {}
  local chosen

  vim.ui.select = function(items, opts, on_choice)
    eq(items, models)
    for _, item in ipairs(items) do
      table.insert(labels, opts.format_item(item))
    end
    on_choice(items[2])
    on_choice(nil)
  end

  ui.open_menu(models, "openai/gpt-5", function(model)
    chosen = chosen and error("submitted twice") or model
  end)

  eq(labels, { "● openai/gpt-5", "  opencode/big-pickle" })
  eq(chosen, models[2])
end

return T
