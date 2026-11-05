# Port of the Viñeta detector to Lua

`tools/panels/detector/panels-core.js` (Viñeta 3.6.1, 4209 lines) is ported by hand to LuaJIT so the plugin detects panels on the reader itself. The goal is the **same result as the JS** on the same input: the port is checked page by page against the JS (`tests/parity/`). Do not "improve" the algorithm while porting: any change of behaviour is a bug.

## Files

| File | JS lines | Contents |
|---|---|---|
| `vineta.koplugin/vineta_detect_base.lua` | 20-44 + helpers | table `D`, constants of the head, typed-array, number and list helpers |
| `vineta_detect_a.lua` | 46-1000 | detectPanels … detectBlack |
| `vineta_detect_b.lua` | 1001-1815 | detectClean … detectDenseAt |
| `vineta_detect_c.lua` | 1816-2985 | paperLuma … paperEdges |
| `vineta_detect_d.lua` | 2986-3487, 3624-4209 | orderRects … halve, BALLOON_* … reattachBalloons |
| `vineta_detect.lua` | — | loads base and a-d, returns `D` |

Not ported (not needed): `analysisImage`, `detectBalloons`, `balloonsOf` (lines 3488-3623), and everything that only feeds `debug`.

Each chunk file starts with:

```lua
local ffi = require("ffi")
local bit = require("bit")
local D = require("vineta_detect_base")
```

and ends with `return D`. It has no other requires.

## Rules

**Names.** Every top-level JS function and constant becomes a field of `D` with the same name: `function D.detectClean(data, w, h, rtl)`, `D.BLACK = {…}`. Calls always go through `D` (`D.coverage(…)`), even inside the same file, so the order of definitions and files does not matter. Top-level constants go at the top of their file. Inside hot loops you may cache `local paperLuma = D.paperLuma` in the function body (not at file level: the other files may not be loaded yet). Helper closures defined inside a JS function stay local closures.

**Debug.** `debug` is always `null` in the plugin: drop every branch, argument and time measure that only exists for it (`debug && …`, `if (debug) {…}`, `times.push`). Keep the parameter in the signature so calls line up. Where the JS passes `debug ? (debug.x = {}) : null`, pass `nil`.

**Typed arrays** (`Uint8Array`, `Uint8ClampedArray`, `Int32Array`, `Float32Array`…) become FFI arrays made with `D.u8(n)`, `D.i32(n)`, `D.f32(n)`… They are **0-based**: keep the JS index arithmetic exactly. They are zero-filled. `a.length` → `D.len(a)`. `a.subarray(x, y)` → `D.sub(a, x, y)` (shares memory), `a.slice(x, y)` → `D.slice(a, x, y)`, `a.fill(v, x, y)` → `D.fill(a, v, x, y)`, `dst.set(src, off)` → `D.set(dst, src, off)`, `new Uint8Array(other)` → `D.copyArray(other)` (same type) or a loop, `typed.sort()` → `D.sortTyped(a)`.
- `Uint8ClampedArray` is `D.u8` too, but **every write must go through `D.clamp8(v)`** (clamp 0..255, round half to even), unless the value is already an integer in 0..255.
- Writing a non-integer to a `Uint8Array`/`Int32Array` truncates in both languages: no helper needed.
- `Float32Array` (`D.f32`) rounds to float32 like JS.
- Plain JS arrays created with a fixed size and filled with numbers (`new Array(n).fill(0)`, `Array.from({length: n}, () => 0)`) that are indexed by computed positions → `D.f64(n)` (0-based). If they hold objects, `null` or are grown with `push`, they are lists (below).

**Lists** (JS arrays of objects or values grown with `push`, iterated with `for…of`, `map`, `filter`) become Lua tables, **1-based**. Translate every index carefully: `for (let i = 0; i < a.length; i++) a[i]` → `for i = 1, #a do a[i]`; `a[i + 1]`, `a[a.length - 1]` → `a[#a]`; `i === 0` → `i == 1`. Any index that is stored, returned or compared with something else must be checked twice. `#t` is only valid without holes: a JS list that can contain `null`/`undefined` needs an explicit count. Helpers: `D.map`, `D.filter`, `D.some`, `D.every`, `D.find`, `D.indexOf` (returns the Lua index or nil), `D.reduce`, `D.concat(a, b, …)` for `[...a, ...b]`, `D.assign(obj, extra)` for `{...obj, k: v}`, `D.splice(t, start0, count, …)` (**0-based start**, as in JS), `D.reverse`, `D.flat`.

**Sort.** `list.sort(cmp)` → `D.sort(list, cmp)`: stable merge sort, `cmp` returns a number like in JS. Never use `table.sort` on lists (not stable, and it errors with inconsistent comparators). JS `sort()` without a comparator sorts as strings: if it appears, port that exactly.

**Map / Set.** Iteration order is insertion order in JS. Use `D.Map()` / `D.Set()` (`set/get/has/delete/size`, `for _, k, v in m:iter()`), or a plain Lua table when the code only looks up keys and never iterates.

**Numbers.**
- `Math.round(x)` → `D.round(x)` (halves up). `Math.floor/ceil/abs/sqrt` → `math.*`.
- `x | 0` → `D.trunc(x)` when x is known to fit in int32 (it always does here: pixel coordinates), `D.toint(x)` otherwise. `x >> n`, `x << n`, `x >>> 0`, `&`, `|` between integers → `bit.arshift`, `bit.lshift`, `bit.band`… (`bit` returns signed int32; `x >> 1` of a non-negative int is also `math.floor(x / 2)`).
- `Math.max(a, b)` / `Math.min` → `math.max` / `math.min` when no operand can be NaN (the normal case); `D.max`/`D.min` if one can. `Math.max(...list)` → loop; `Math.max()` of nothing is `-math.huge`.
- `Infinity` → `math.huge`. `Math.sign` → `D.sign`. `Math.hypot` → `D.hypot`. `Math.trunc` → `D.trunc`.
- `a % b`: same as Lua `%` only when both are non-negative; otherwise `math.fmod(a, b)`.
- `Number.isFinite(x)` → `x == x and x ~= math.huge and x ~= -math.huge`.
- `performance.now()` → `D.now()` (ms). Keep `FRAMED_BUDGET_MS` as `D.FRAMED_BUDGET_MS`.

**Truthiness — the main trap.** In JS `0`, `NaN`, `""`, `null`, `undefined` are falsy; in Lua only `nil` and `false`. Every `if (x)`, `!x`, `x && y`, `x || y`, `x ? a : b` where `x` can be a number (a count, a length, an index, an area) must become an explicit comparison (`x ~= 0`, `#list > 0`). `x || 0` with a number → `(x ~= nil and x ~= 0 and x == x) and x or 0` or simpler when the cases are known. `a ?? b` → `a == nil and b or a` (careful when a can be `false`). `cond ? a : b` → `if … then … else … end` or `(cond) and a or b` **only** when `a` can never be `false`/`nil`.

**Objects.** JS objects → Lua tables with the same field names. `undefined`/`null` → `nil` (a field set to `null` and a missing field are the same in Lua: check that the JS never tells them apart with `in` or `=== undefined` vs `=== null`). Reference equality (`a === b`) works the same on tables. Destructuring `const { x0, y0 } = r` → `local x0, y0 = r.x0, r.y0`. Default parameters → `if x == nil then x = … end`. Option objects `{ rtl = false, … } = {}` → `opts = opts or {}` then read fields with defaults.

**Control flow.** `continue` → `goto continue` with `::continue::` as the last statement of the loop body. Labelled `break outer` → `goto` a label after the outer loop. JS `for (let i = a; i < b; i++)` → `for i = a, b - 1 do`, but **only** if the body never changes `i` or `b` (the Lua limit is computed once); otherwise use `while`. A `for` loop whose step is not 1 → `for i = a, b - 1, step`. Loops that run backwards: `for (let i = n - 1; i >= 0; i--)` → `for i = n - 1, 0, -1`.

**Lua limits.** At most 200 locals per function and 60 upvalues per closure: if a long JS function hits them, group its locals in a table. Avoid creating closures inside per-pixel loops.

## Checking

- Syntax: `luajit -bl vineta.koplugin/vineta_detect_X.lua > /dev/null` (or `luajit -e "package.path='vineta.koplugin/?.lua;'..package.path; require('vineta_detect_X')"`).
- Parity: `tests/parity/` dumps the inputs of `detectPanels` from the JS (node) for real pages and runs the Lua port on the same bytes; rects must match.
