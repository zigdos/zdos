-- LUADEMO.LUA: checks the Lua port on zdos. Run it with LUA LUADEMO.LUA
-- (or from the REPL with dofile). Each check prints ok or FAILED; the last
-- line counts them, the exit code is 1 if any failed. The error checks
-- use setjmp and longjmp (pcall, error).

local passed, failed = 0, 0

local function check(name, got, want)
  if got == want then
    passed = passed + 1
    print("ok      " .. name)
  else
    failed = failed + 1
    print("FAILED  " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
  end
end

-- Numbers and arithmetic
check("integer sum", 1 + 2 + 3, 6)
check("integer division", 7 // 2, 3)
check("float division", 10 / 4, 2.5)
check("power", 2 ^ 10, 1024.0)
check("modulo", -7 % 3, 2)
check("big integer", 2 ^ 53 == 9007199254740992.0, true)

-- Math library (uses the SDK's libm and zig's runtime)
check("sqrt", math.sqrt(16), 4.0)
check("floor", math.floor(3.7), 3)
check("abs", math.abs(-5), 5)
check("max", math.max(3, 9, 4), 9)
check("sin(0)", math.sin(0), 0.0)
check("atan2(1,1) is pi/4", math.abs(math.atan(1, 1) - math.pi / 4) < 1e-12, true)

-- Strings
check("concat", "zd" .. "os", "zdos")
check("length", #"hello", 5)
check("upper", string.upper("abc"), "ABC")
check("sub", string.sub("zdos", 2, 3), "do")
check("find", string.find("zdos lua", "lua", 1, true), 6)
check("format %d", string.format("%d-%03d", 7, 5), "7-005")
check("format %g", string.format("%g", 0.5), "0.5")
check("rep", string.rep("ab", 3, ","), "ab,ab,ab")
check("gsub", (string.gsub("a b c", " ", "_")), "a_b_c")

-- Tables and loops
local t = {}
for i = 1, 5 do t[#t + 1] = i * i end
check("table length", #t, 5)
check("table sum", t[1] + t[2] + t[3] + t[4] + t[5], 55)
table.sort(t, function(a, b) return a > b end)
check("sort descending", t[1], 25)
check("concat list", table.concat({ "a", "b", "c" }, "-"), "a-b-c")

-- Closures and varargs
local function counter()
  local n = 0
  return function() n = n + 1; return n end
end
local c = counter()
c(); c()
check("closure", c(), 3)
local function count(...) return select("#", ...) end
check("varargs", count(nil, nil, 3), 3)

-- Errors: pcall returns false and the message, the program goes on (setjmp, longjmp)
local ok, msg = pcall(error, "boom")
check("pcall catches error", ok, false)
check("error message", msg, "boom")
ok, msg = pcall(function() local x = nil; return x.field end)
check("runtime error caught", ok, false)
check("error names the problem", string.find(msg, "attempt to index", 1, true) ~= nil, true)
local ok2, val = pcall(function() return 42 end)
check("pcall without error", val, 42)
check("pcall without error ok", ok2, true)

-- Nested pcall: an error in an inner call goes to the nearest pcall
local outer_ok, outer_msg = pcall(function()
  local inner_ok, inner_msg = pcall(error, "inner")
  error("outer after " .. inner_msg, 0)
end)
check("nested pcall", outer_msg, "outer after inner")
check("nested pcall fails", outer_ok, false)

-- An error with a table value
local ok3, obj = pcall(error, { code = 7 })
check("error with a table", obj.code, 7)

-- Deep recursion inside pcall: setjmp must return to the right place
local function depth(n)
  if n == 0 then error("bottom", 0) end
  return depth(n - 1)
end
local deep_ok, deep_msg = pcall(depth, 100)
check("error from 100 levels deep", deep_msg, "bottom")

-- Coroutines
local co = coroutine.create(function(a)
  local b = coroutine.yield(a + 1)
  return b * 2
end)
local _, first = coroutine.resume(co, 1)
local _, second = coroutine.resume(co, 10)
check("coroutine yield", first, 2)
check("coroutine return", second, 20)

-- io.popen: the command runs to its end first, then the file reads its output
local out, popen_err = io.popen("echo hi")
check("popen opened", out ~= nil, true)
if out then
  check("popen read", out:read("l"), "hi")
  check("popen close status", out:close(), true)
else
  print("        " .. tostring(popen_err))
end

-- io.tmpfile: a file opened for reading and writing, removed when closed
local tmp = io.tmpfile()
check("tmpfile opened", tmp ~= nil, true)
tmp:write("abc")
tmp:seek("set", 0)
check("tmpfile read", tmp:read(1), "a")
tmp:close()

-- os.tmpname: the name of an existing file, removed by os.remove
local tname = os.tmpname()
check("tmpname is a string", type(tname), "string")
local tf = io.open(tname, "r")
check("tmpname file exists", tf ~= nil, true)
if tf then tf:close() end
check("os.remove of tmpname", (os.remove(tname)), true)
check("tmpname file gone", (io.open(tname)), nil)

-- Files: write, read, lines and append (in a temporary file)
local name = os.tmpname()
local fw = io.open(name, "w")
fw:write("line one\n", "42\n")
fw:close()
local fr = io.open(name, "r")
check("read line", fr:read("l"), "line one")
check("read number", fr:read("n"), 42)
check("rest of the number line is empty", fr:read("l"), "")
fr:read("l")
fr:close()
local lines = 0
for _ in io.lines(name) do lines = lines + 1 end
check("io.lines count", lines, 2)
local fa = io.open(name, "a")
fa:write("more\n")
fa:close()
check("append kept the start", io.open(name):read("l"), "line one")
check("file size", (function() local f = io.open(name); local n = f:seek("end"); f:close(); return n end)(), 17)
check("os.remove works", (os.remove(name)), true)

-- Time, date and environment
check("os.time is a number", math.type(os.time()), "integer")
check("os.date year is recent", tonumber(os.date("%Y")) >= 2025, true)
check("os.clock is a number", type(os.clock()), "number")
check("getenv TEMP is set", type(os.getenv("TEMP")), "string")
check("getenv of a missing name", os.getenv("ZDOS_NO_SUCH_NAME"), nil)

-- require: a module file in the folder of a temporary file
local tmp_name = os.tmpname()
local dir = tmp_name:match("^(.*)[\\/][^\\/]*$")
local sep = tmp_name:find("\\", 1, true) and "\\" or "/"
local mod = io.open(dir .. sep .. "LUAMOD.lua", "w")
mod:write("return { value = 42 }\n")
mod:close()
os.remove(tmp_name)
package.path = dir .. sep .. "?.lua;" .. package.path
check("require a module", require("LUAMOD").value, 42)
os.remove(dir .. sep .. "LUAMOD.lua")

-- Metatables and number formatting
local V = setmetatable({}, { __index = function(_, k) return k .. "!" end })
check("__index metamethod", V.word, "word!")
check("format a float", string.format("%.2f", 3.14159), "3.14")
check("integer and float types", math.type(1) .. "," .. math.type(1.0), "integer,float")

print("")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
