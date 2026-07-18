local M = { passed = 0, failed = 0 }

function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    M.passed = M.passed + 1
    print("ok    " .. name)
  else
    M.failed = M.failed + 1
    print("FAIL  " .. name .. "\n      " .. tostring(err))
  end
end

function M.equal(actual, expected)
  if actual ~= expected then
    error(("expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
  end
end

function M.truthy(v)
  if not v then error("expected truthy, got " .. tostring(v), 2) end
end

function M.falsy(v)
  if v then error("expected falsy, got " .. tostring(v), 2) end
end

function M.finish()
  print(("\n%d passed, %d failed"):format(M.passed, M.failed))
  if M.failed > 0 then os.exit(1) end
end

return M
