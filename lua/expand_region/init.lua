local M = {
  opts = {
    text_objects = {
      ["iw"] = 0,
      ["iW"] = 0,
      ['i"'] = 0,
      ["i'"] = 0,
      ["i`"] = 0,
      ["i)"] = 1,
      ["a)"] = 1,
      ["i]"] = 1,
      ["a]"] = 1,
      ["i}"] = 1,
      ["a}"] = 1,
    },
  },
  saved_pos = {},
  cur_index = 0,
  candidates = {},
}

-- Compare two position arrays. Each input is the result of getpos()
M.compare_pos = function(l, r)
  if l[2] == r[2] then
    return l[3] - r[3]
  end

  return l[2] - r[2]
end

-- Boundary check on the cursor position to make sure it's inside the text object region
M.is_cursor_inside = function(region)
  local pos = M.saved_pos

  if M.compare_pos(pos, region.start_pos) < 0 then
    return false
  end

  if M.compare_pos(pos, region.end_pos) > 0 then
    return false
  end

  return true
end

-- Remove duplicates from the candidate list
M.remove_duplicate = function(input)
  local result = {}

  local m = {}

  for _, i in ipairs(input) do
    local key = string.format("%d:%d:%d:%d", i.start_pos[2], i.start_pos[3], i.end_pos[2], i.end_pos[3])

    if not m[key] then
      table.insert(result, i)
      m[key] = true
    end
  end

  return result
end

M.remove_out_of_bounds = function()
  local recursive_candidates = {}
  local not_recursive_candidates = {}

  for _, i in ipairs(M.candidates) do
    if M.opts.text_objects[i.text_object] == 1 then
      if i.length > 0 then
        table.insert(recursive_candidates, i)
      end
    end

    if M.opts.text_objects[i.text_object] == 0 then
      if i.length > 0 then
        table.insert(not_recursive_candidates, i)
      end
    end
  end

  local dels = {}

  for _, i in ipairs(not_recursive_candidates) do
    for _, j in ipairs(recursive_candidates) do
      if M.compare_pos(i.start_pos, j.start_pos) < 0 then
        dels[i.text_object] = true
        break
      end

      if M.compare_pos(i.end_pos, j.end_pos) > 0 then
        dels[i.text_object] = true
        break
      end
    end
  end

  local candidates = {}

  for _, i in ipairs(M.candidates) do
    if not dels[i.text_object] then
      table.insert(candidates, i)
    end
  end

  M.candidates = candidates
end

-- Return a single candidate dictionary. Each dictionary contains the following:
-- text_object: The actual text object string
-- start_pos: The result of getpos() on the starting position of the text object
-- end_pos: The result of getpos() on the ending position of the text object
-- length: The number of characters for the text object
M.get_candidate_dict = function(text_object)
  -- Store the current view so we can restore it at the end
  local winview = vim.fn.winsaveview()

  -- Use ! as much as possible
  vim.cmd("normal! v")
  vim.cmd("silent! normal " .. text_object)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", false)

  local selection = M.get_visual_selection()

  local ret = {
    text_object = text_object,
    start_pos = selection.start_pos,
    end_pos = selection.end_pos,
    length = selection.length,
  }

  -- Restore peace
  vim.fn.winrestview(winview)

  return ret
end

-- Return list of candidate dictionary. Each dictionary contains the following:
-- text_object: The actual text object string
-- start_pos: The result of getpos() on the starting position of the text object
-- length: The number of characters for the text object
M.get_candidate_list = function()
  -- Turn off wrap to allow recursive search to work without triggering errors
  local save_wrapscan = vim.opt.wrapscan
  vim.opt.wrapscan = false

  local text_objects = M.opts.text_objects

  -- Generate the candidate list for every defined text object
  local candidates = {}

  for text_object in pairs(text_objects) do
    local candidate = M.get_candidate_dict(text_object)
    if candidate.length > 0 then
      table.insert(candidates, candidate)
    end
  end

  -- For the ones that are recursive, generate them until they no longer match any region
  local recursive_candidates = {}

  for _, i in ipairs(candidates) do
    -- Continue if not recursive
    if text_objects[i.text_object] == 0 then
      goto continue
    end

    local count = 2
    local previous = i.length

    while true do
      local test = count .. i.text_object

      local candidate = M.get_candidate_dict(test)
      if candidate.length == 0 then
        break
      end

      -- If we're not producing larger regions, end early
      if candidate.length <= previous then
        break
      end

      table.insert(recursive_candidates, candidate)

      count = count + 1
      previous = candidate.length

      if count > 20 then
        break
      end
    end

    ::continue::
  end

  -- Restore wrapscan
  vim.opt.wrapscan = save_wrapscan

  return vim.list_extend(candidates, recursive_candidates)
end

-- Return a dictionary containing the start position, end position and length of the current visual selection.
M.get_visual_selection = function()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local col_to = math.min(end_pos[3] + 1, #vim.api.nvim_buf_get_lines(0, end_pos[2] - 1, end_pos[2], false)[1])

  local lines = vim.api.nvim_buf_get_text(0, start_pos[2] - 1, start_pos[3], end_pos[2] - 1, col_to, {})
  local text = table.concat(lines, "\n")

  return {
    start_pos = start_pos,
    end_pos = end_pos,
    length = #text,
  }
end

-- Figure out whether we should compute the candidate text objects, or we're in the middle of an expand/shrink.
M.should_compute_candidates = function(mode)
  if mode ~= "v" then
    return true
  end

  -- Check that current visual selection is idential to our last expanded region
  if M.cur_index == 0 then
    return true
  end

  local selection = M.get_visual_selection()
  local current = M.candidates[M.cur_index]

  if M.compare_pos(current.start_pos, selection.start_pos) ~= 0 then
    return true
  end

  if M.compare_pos(current.end_pos, selection.end_pos) ~= 0 then
    return true
  end

  return false
end

-- Computes the list of text object candidates to be used given the current
-- cursor position.
M.compute_candidates = function(cursor_pos)
  -- Reset index into the candidates list
  M.cur_index = 0

  -- Save the current cursor position so we can restore it later
  M.saved_pos = cursor_pos

  -- Compute a list of candidate regions
  M.candidates = M.get_candidate_list()

  -- Sort them and remove the ones with 0 or 1 length
  M.candidates = vim.tbl_filter(function(value)
    return value.length > 1
  end, M.candidates)

  table.sort(M.candidates, function(l, r)
    return l.length < r.length
  end)

  -- Filter out the ones where the cursor falls outside of its region. i" and i'
  -- can start after the cursor position, and ib can start before, so both checks
  -- are needed
  M.candidates = vim.tbl_filter(M.is_cursor_inside, M.candidates)

  --Remove duplicates
  M.candidates = M.remove_duplicate(M.candidates)

  M.remove_out_of_bounds()
end

-- Perform the visual selection at the end
M.select_region = function()
  vim.cmd("normal! v")
  vim.cmd("normal " .. M.candidates[M.cur_index].text_object)
end

M.expand_region = function(mode, direction)
  -- stop visual mode
  if vim.fn.mode() == mode then
    vim.cmd("normal! " .. mode)
  end

  if M.should_compute_candidates(mode) then
    M.compute_candidates(vim.fn.getpos("."))
  else
    vim.fn.setpos(".", M.saved_pos)
  end

  if direction == "+" then
    -- Expanding
    if M.cur_index == #M.candidates then
      vim.cmd("normal! gv")
    else
      M.cur_index = M.cur_index + 1
      -- Associate the window view with the text object
      M.candidates[M.cur_index].prev_winview = vim.fn.winsaveview()
      M.select_region()
    end
  else
    -- Shrinking
    if M.cur_index <= 1 then
      vim.cmd("normal! gv")
    else
      -- Restore the window view
      vim.fn.winrestview(M.candidates[M.cur_index].prev_winview)
      M.cur_index = M.cur_index - 1
      M.select_region()
    end
  end
end

M.setup = function(opts)
  if opts.text_objects then
    M.opts.text_objects = opts.text_objects
  end

  vim.keymap.set("x", "<Plug>(expand_region_expand)", function()
    M.expand_region("v", "+")
  end, {})

  vim.keymap.set("x", "<Plug>(expand_region_shrink)", function()
    M.expand_region("v", "-")
  end, {})

  if not opts.disable_default_mappings then
    vim.keymap.set("x", "v", "<Plug>(expand_region_expand)", {})
    vim.keymap.set("x", "V", "<Plug>(expand_region_shrink)", {})
  end

  if not opts.disable_treesitter then
    local ok, incremental_selection = pcall(require, "nvim-treesitter.incremental_selection")
    if ok then
      vim.keymap.set("x", "in", function()
        for _ = 1, vim.v.count1 do
          incremental_selection.node_incremental()
        end
      end, { silent = true })
    end

    M.opts.text_objects["in"] = 1
  end
end

return M
