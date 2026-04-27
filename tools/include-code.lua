-- Pandoc Lua filter: include external files in code blocks.
--
-- Usage in markdown:
--   ``` {.tcl include="examples/foo.tcl"}
--   ```
--
-- The code block content is replaced with the file contents.
-- Paths are resolved relative to the input file's directory.

function CodeBlock(block)
  local file = block.attributes["include"]
  if not file then return nil end

  -- Collect candidate directories to search
  local dirs = {"."}
  if PANDOC_STATE and PANDOC_STATE.input_files then
    for _, input_file in ipairs(PANDOC_STATE.input_files) do
      local d = input_file:match("(.*/)")
      if d then dirs[#dirs + 1] = d end
    end
  end
  -- Also try the resource path entries
  if PANDOC_STATE and PANDOC_STATE.resource_path then
    for _, d in ipairs(PANDOC_STATE.resource_path) do
      dirs[#dirs + 1] = d
    end
  end

  for _, dir in ipairs(dirs) do
    local path = dir .. "/" .. file
    local f = io.open(path, "r")
    if f then
      block.text = f:read("*a"):gsub("%s+$", "")
      f:close()
      block.attributes["include"] = nil
      return block
    end
  end

  io.stderr:write("include-code.lua: cannot find " .. file .. "\n")
  return nil
end
