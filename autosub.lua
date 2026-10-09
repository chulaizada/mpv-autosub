--[[
  autosub.lua —— mpv 自动下载中文字幕

  功能
    播放视频时自动查找并下载中文字幕，无需手动操作。查找顺序：
      ① 本地已有字幕  → 直接加载，不联网
      ② moviehash 匹配 → 按文件哈希定位完全对应的字幕
      ③ 标题搜索      → 英文 release 名优先，中文名兜底
    每一步的状态通过 OSD 实时显示在画面上。

  依赖
    - mpv      自带 Lua 支持，无需另装 Lua
    - curl     访问 OpenSubtitles API（Windows 10 及以上自带）
    - Python 3 仅用于计算 moviehash；脚本会自动检测，未安装时尝试自动安装，
               仍不可用时自动跳过 ②，不影响播放

    技术说明：moviehash 需要对 64 位无符号整数做累加，
    LuaJIT 不支持 Lua 5.3 的位运算符（<< 等）与原生 64 位整数，
    因此该步骤改由 Python 完成。

  配置
    使用前请填写下方 o = { ... } 中的 OpenSubtitles 凭据：
      os_api_key    OpenSubtitles API Key
      os_username   OpenSubtitles 用户名
      os_password   OpenSubtitles 密码
    任一为空或登录失败时，会在屏幕上提示。其余可选项见 README。

  用法
    将本文件放入 mpv 的 scripts 目录（路径见 README），启动时自动加载。
    播放视频自动触发；按 m 键可手动触发一次。
--]]

local mp    = require 'mp'
local utils = require 'mp.utils'
local msg   = require 'mp.msg'
local opts  = require 'mp.options'

local o = {
    -- 在此填写你的 OpenSubtitles 凭据（留空会在播放时提示）
    os_api_key  = "",
    os_username = "",
    os_password = "",

    -- 文件名优先（适合手动规范命名的用户）
    prefer_filename = true,

    language = "zh-cn,zh-tw,zh",
    min_duration = 900,
    debug = false,
}
opts.read_options(o, "auto-sub")

local API_OS = "https://api.opensubtitles.com/api/v1"
local UA     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

-- ============ 工具 ============
local function log(s)
    msg.warn("[auto-sub] " .. s)
    mp.osd_message("字幕: " .. s, 3)
end

local function dbg(s)
    if o.debug then msg.warn("[auto-sub][dbg] " .. s) end
end

local function curl(args, timeout)
    timeout = timeout or 30
    local t = { args = { "curl", "-s", "-L",
        "--connect-timeout", "10",
        "--max-time", tostring(timeout),
        "-A", UA } }
    for _, a in ipairs(args) do t.args[#t.args+1] = a end
    local r = utils.subprocess(t)
    if r.status ~= 0 then return nil end
    return r.stdout
end

local function curl_retry(args, retries, timeout)
    retries = retries or 2
    for i = 1, retries do
        local out = curl(args, timeout)
        if out and out ~= "" then return out end
        if i < retries then
            dbg("curl 失败，重试 " .. i .. "/" .. retries)
        end
    end
    return nil
end

local function url_encode(s)
    return (s:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- 单词边界匹配（避免 game 命中 games）
local function word_match(haystack, needle)
    if not haystack or not needle or needle == "" then return false end
    local start = 1
    while true do
        local pos = haystack:find(needle, start, true)
        if not pos then return false end
        local before = pos > 1 and haystack:sub(pos-1, pos-1) or ""
        local after_pos = pos + #needle
        local after = after_pos <= #haystack and haystack:sub(after_pos, after_pos) or ""
        if not before:match("%a") and not after:match("%a") then
            return true
        end
        start = pos + 1
    end
end

-- 识别压制参数噪声词
local function is_noise_word(w, stop)
    if not w or w == "" then return true end
    local lw = w:lower()
    if stop and stop[lw] then return true end
    -- 纯数字+点+数字（5.1、7.1、2.0）
    if lw:match("^%d+%.%d+$") then return true end
    -- 纯数字+bit（10bit、8bit）
    if lw:match("^%d+bit$") then return true end
    -- hdr+数字（hdr10、hdr10plus、hdr10+）
    if lw:match("^hdr%d") then return true end
    -- 全大写且长度 >= 6（iNTERNAL、SWTYBLZ、HDR10Plus 等）
    if #w >= 6 and w:match("^%u+$") then return true end
    return false
end

local function json_get(s, key)
    if not s then return nil end
    return s:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

local function json_get_num(s, key)
    if not s then return nil end
    local v = s:match('"' .. key .. '"%s*:%s*(%-?%d+)')
    return v and tonumber(v) or nil
end

local function file_exists(p)
    local h = io.open(p, "r")
    if h then h:close(); return true end
    return false
end

local function nonascii_to_space(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b >= 0x20 and b <= 0x7E then
            out[#out+1] = string.char(b)
        else
            out[#out+1] = " "
        end
    end
    return table.concat(out)
end

-- 检测字符串是否含 CJK 字符（3 字节 UTF-8 且落在 CJK 区）
local function has_cjk(s)
    if not s then return false end
    for i = 1, #s do
        local b = s:byte(i)
        if b and b >= 0xE0 and b <= 0xEF then
            local b2, b3 = s:byte(i+1), s:byte(i+2)
            if b2 and b3 then
                local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
                if (cp >= 0x4E00 and cp <= 0x9FFF)
                    or (cp >= 0x3400 and cp <= 0x4DBF)
                    or (cp >= 0xF900 and cp <= 0xFAFF) then
                    return true
                end
            end
            i = i + 2
        end
    end
    return false
end

-- release 名相关性校验
local function rel_looks_related(rel, en, cn)
    if not rel or rel == "" then return false end
    local rel_lower = rel:lower()

    -- 中文名匹配：只要 release 里出现中文名前几个字就通过
    if cn and #cn >= 2 then
        local cn_key = cn:sub(1, 4)
        if rel_lower:find(cn_key:lower(), 1, true) then return true end
    end

    -- 英文关键词：必须命中第一个词 + 至少一半
    if en then
        local words = {}
        for w in en:gmatch("%S+") do
            if #w >= 2 then words[#words+1] = w end
        end
        if #words > 0 then
            if not word_match(rel_lower, words[1]:lower()) then
                return false
            end
            local hit = 0
            for _, w in ipairs(words) do
                if word_match(rel_lower, w:lower()) then hit = hit + 1 end
            end
            if hit >= math.max(1, math.floor(#words / 2)) then
                return true
            end
            return false
        end
    end

    -- v27: en 为空时，降级判断：只要 rel 里出现年份且不是完全无关的片子
    -- 通过"是否包含任何长度 >= 4 的英文单词"来粗略判断
    -- 这里保守返回 false，避免误判
    return false
end

-- ============ Python 探测与自动安装 ============
local python_cmd = nil
local python_checked = false

local function try_python_cmd(cmd)
    local r = utils.subprocess({
        args = { cmd, "--version" },
        capture_stdout = true,
        capture_stderr = true,
    })
    if r.status == 0 then
        local out = (r.stdout or "") .. (r.stderr or "")
        if out:match("Python 3") then return cmd end
    end
    return nil
end

local function detect_python()
    for _, cmd in ipairs({ "python", "python3", "py" }) do
        local ok = try_python_cmd(cmd)
        if ok then
            dbg("Python 可用: " .. cmd)
            return cmd
        end
    end
    return nil
end

local function try_install_python()
    dbg("尝试用 winget 安装 Python...")
    local r = utils.subprocess({
        args = {
            "winget", "install", "-e", "--id", "Python.Python.3.13",
            "--silent", "--accept-package-agreements", "--accept-source-agreements",
            "--scope", "user",
        },
        capture_stdout = true,
        capture_stderr = true,
    })
    return r.status == 0
end

local function get_python()
    if python_checked then return python_cmd end
    python_checked = true
    python_cmd = detect_python()
    if not python_cmd then
        log("未检测到 Python，尝试自动安装…")
        if try_install_python() then
            python_cmd = detect_python()
            if python_cmd then
                log("Python 安装成功: " .. python_cmd)
            else
                log("Python 安装后仍不可用，跳过 moviehash")
            end
        else
            log("Python 自动安装失败，跳过 moviehash")
        end
    end
    return python_cmd
end

-- ============ ① 本地已有字幕？ ============
local function find_existing_sub(path)
    local dir, name = utils.split_path(path)
    local base = name:gsub("%.[^%.]+$", "")
    local subdirs = { "", "sub/", "Subs/", "subtitles/", "sub\\", "Subs\\", "subtitles\\" }
    local exts = {
        ".zh.srt", ".zh-cn.srt", ".zh-tw.srt", ".chs.srt", ".cht.srt",
        ".chi.srt", ".zho.srt", ".zh-hans.srt", ".zh-hant.srt",
        ".sc.srt", ".tc.srt", ".gb.srt", ".big5.srt",
        ".zh.ass", ".zh-cn.ass", ".chs.ass", ".cht.ass",
        ".chi.ass", ".sc.ass", ".tc.ass",
        ".zh-cn.zh.srt", ".chs.zh.srt", ".zh-cn.chs.srt",
    }
    for _, sd in ipairs(subdirs) do
        for _, e in ipairs(exts) do
            local f = dir .. sd .. base .. e
            if file_exists(f) then return f end
        end
    end
    return nil
end

-- ============ moviehash ============
local function compute_moviehash(path)
    local py = get_python()
    if not py then return nil, 0 end

    local script = [[
import sys, os, struct
p = sys.argv[1]
try:
    fs = os.path.getsize(p)
    if fs < 131072:
        print("TOO_SMALL")
        sys.exit(0)
    h = fs
    with open(p, 'rb') as f:
        for _ in range(8192):
            (v,) = struct.unpack('<Q', f.read(8))
            h = (h + v) & 0xFFFFFFFFFFFFFFFF
        f.seek(max(0, fs - 65536), 0)
        for _ in range(8192):
            (v,) = struct.unpack('<Q', f.read(8))
            h = (h + v) & 0xFFFFFFFFFFFFFFFF
    print("%016x|%d" % (h, fs))
except Exception as e:
    print("ERROR:" + str(e))
]]

    local res = utils.subprocess({
        args = { py, "-c", script, path },
        capture_stdout = true,
    })
    if res.status ~= 0 or not res.stdout then return nil, 0 end
    local out = res.stdout:gsub("^%s+", ""):gsub("%s+$", "")
    if out == "TOO_SMALL" then return nil, 0 end
    if out:match("^ERROR:") then
        dbg("Python 报错: " .. out)
        return nil, 0
    end
    local hash, size = out:match("^([0-9a-fA-F]+)%|(%d+)%s*$")
    if hash and size then return hash:lower(), tonumber(size) end
    return nil, 0
end

-- ============ OpenSubtitles 登录 ============
local function os_login()
    local body = string.format('{"username":"%s","password":"%s"}', o.os_username, o.os_password)
    local out = curl_retry({
        "-X", "POST", API_OS .. "/login",
        "-H", "Api-Key: " .. o.os_api_key,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-d", body,
    }, 2, 20)
    return json_get(out, "token")
end

-- ============ 解析搜索结果 ============
local function os_parse_best_subtitle(out, year_hint, title_keywords)
    if not out or out == "" then return nil end
    local total = json_get_num(out, "total_count")
    if not total or total == 0 then return nil end

    local blocks = {}
    local pos = 1
    while true do
        local s = out:find('"attributes"%s*:%s*{', pos)
        if not s then break end
        local next_s = out:find('"attributes"%s*:%s*{', s + 1)
        local e = next_s and (next_s - 1) or #out
        blocks[#blocks+1] = out:sub(s, e)
        pos = e + 1
    end

    if #blocks == 0 then
        local fid = json_get_num(out, "file_id")
        if fid then return fid, json_get(out, "release"), json_get(out, "language"), 0 end
        return nil
    end

    local best_fid, best_rel, best_lang, best_score = nil, nil, nil, -1
    for _, chunk in ipairs(blocks) do
        local fid = json_get_num(chunk, "file_id")
        if fid then
            local lang = json_get(chunk, "language") or ""
            local rel  = json_get(chunk, "release") or ""
            local dl   = json_get_num(chunk, "download_count") or 0

            local ok = true
            local rel_lower = rel:lower()

            -- 年份校验
            if year_hint and year_hint ~= "" then
                local ry = rel_lower:match("(19%d%d)") or rel_lower:match("(20%d%d)")
                if ry and ry ~= year_hint then
                    ok = false
                end
                if not ry then
                    dl = dl - 50000
                end
            end

            -- 关键词校验：必须命中第一个主关键词 + 至少一半
            if ok and title_keywords and #title_keywords > 0 then
                local primary = title_keywords[1]:lower()
                if not word_match(rel_lower, primary) then
                    ok = false
                else
                    local hit_count = 0
                    for _, w in ipairs(title_keywords) do
                        if word_match(rel_lower, w:lower()) then
                            hit_count = hit_count + 1
                        end
                    end
                    local min_hits = math.max(1, math.floor(#title_keywords / 2))
                    if hit_count < min_hits then ok = false end
                end
            end

            if ok then
                local score = dl
                if lang:match("^[Zz][Hh]") then score = score + 1000000 end
                if score > best_score then
                    best_fid, best_rel, best_lang, best_score = fid, rel, lang, score
                end
            else
                dbg("跳过不匹配结果: " .. rel)
            end
        end
    end

    if best_fid then return best_fid, best_rel, best_lang, best_score end
    return nil
end

local function os_search(url, year_hint, title_keywords)
    local out = curl_retry({
        "-H", "Api-Key: " .. o.os_api_key,
        "-H", "Accept: application/json",
        url,
    }, 2, 30)
    if not out or out == "" then return nil end
    dbg("OS raw: " .. out:sub(1, 300))
    return os_parse_best_subtitle(out, year_hint, title_keywords)
end

-- ============ OpenSubtitles 下载 ============
local function os_download(file_id, token, dest)
    local body = string.format('{"file_id":%d,"sub_format":"srt"}', file_id)
    local out = curl_retry({
        "-X", "POST", API_OS .. "/download",
        "-H", "Api-Key: " .. o.os_api_key,
        "-H", "Authorization: Bearer " .. token,
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "-d", body,
    }, 2, 30)
    if o.debug and out then dbg("OS download raw: " .. out:sub(1, 200)) end
    local link = json_get(out, "link")
    if not link then
        local err = json_get(out, "message") or out:sub(1, 200)
        log("OS 下载被拒: " .. tostring(err))
        return false
    end
    local r = utils.subprocess({ args = { "curl", "-s", "-L",
        "--connect-timeout", "10", "--max-time", "120",
        "-o", dest, link, "-A", UA } })
    return r.status == 0 and file_exists(dest)
end

-- ============ 中文提取（只保留 CJK 汉字 + ASCII 数字）============
local function is_cjk_han_codepoint(cp)
    return (cp >= 0x4E00 and cp <= 0x9FFF)
        or (cp >= 0x3400 and cp <= 0x4DBF)
        or (cp >= 0xF900 and cp <= 0xFAFF)
end

local function is_cjk_punct(cp)
    return (cp >= 0x3000 and cp <= 0x303F)
        or (cp >= 0xFF00 and cp <= 0xFFEF)
        or (cp == 0x00B7)
        or (cp == 0x2014) or (cp == 0x2013)
end

local function extract_cn(base)
    local cn_segs = {}
    local cur = {}
    local i, n = 1, #base
    while i <= n do
        local b = base:byte(i)
        if b and b >= 0xE0 and b <= 0xEF then
            local b2, b3 = base:byte(i+1), base:byte(i+2)
            if b2 and b3 then
                local cp = (b - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
                if is_cjk_han_codepoint(cp) then
                    cur[#cur+1] = base:sub(i, i+2)
                elseif is_cjk_punct(cp) then
                    if #cur > 0 then cur[#cur+1] = " " end
                else
                    if #cur > 0 then
                        cn_segs[#cn_segs+1] = table.concat(cur, "")
                        cur = {}
                    end
                end
            end
            i = i + 3
        elseif b and b >= 0x30 and b <= 0x39 then
            if #cur > 0 then
                cur[#cur+1] = string.char(b)
            end
            i = i + 1
        else
            if #cur > 0 then
                cn_segs[#cn_segs+1] = table.concat(cur, "")
                cur = {}
            end
            i = i + 1
        end
    end
    if #cur > 0 then cn_segs[#cn_segs+1] = table.concat(cur, "") end

    local best = nil
    for _, seg in ipairs(cn_segs) do
        seg = seg:gsub("%s+", "")
        if #seg >= 2 then
            if not best or #seg > #best then best = seg end
        end
    end
    return best
end

-- ============ 从 mpv 字段提取信息（v27：不再被第一个 source 锁死）============
-- 关键改动：所有 source 都尝试提取 en，选"质量最好"的（单词数最多）
local function extract_en_from_source(base, stop)
    local cleaned_full = base:gsub("%-%u%u%u%u+.*$", "")
    local cleaned = nonascii_to_space(cleaned_full)
    cleaned = cleaned:gsub("[%._%-:]", " ")
    cleaned = cleaned:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    if #cleaned < 3 then return nil, {} end

    local words = {}
    for w in cleaned:gmatch("%S+") do
        if not is_noise_word(w, stop) and #w >= 1 then
            words[#words+1] = w
        end
    end

    if #words == 0 then return nil, {} end

    local en = table.concat(words, " ")
    local keywords = {}
    for _, w in ipairs(words) do
        local lw = w:lower()
        -- v27: 排除纯年份、长度 1 的 token
        if #w >= 4
            and not lw:match("^%d+p$")
            and not lw:match("^%d%d%d%d$")
            and not is_noise_word(w, stop) then
            keywords[#keywords+1] = w
        end
    end

    return en, keywords
end

local function extract_names(sources)
    local year = nil
    local cn = nil
    local best_en = nil
    local best_keywords = {}
    local best_score = -1

    local stop = {
        -- 来源/发布组
        ["bluray"]=1,["blu"]=1,["ray"]=1,["web"]=1,["webdl"]=1,["webrip"]=1,
        ["remux"]=1,["uhd"]=1,["sdr"]=1,["x265"]=1,["x264"]=1,
        ["hevc"]=1,["avc"]=1,["truehd"]=1,["atmos"]=1,["dts"]=1,["ac3"]=1,
        ["aac"]=1,["proper"]=1,["repack"]=1,["imax"]=1,["extended"]=1,
        ["swtyblz"]=1,["rarbg"]=1,["yts"]=1,["yify"]=1,["fgt"]=1,
        ["rerip"]=1,["10bit"]=1,["8bit"]=1,["dirtyhippie"]=1,
        ["multi"]=1,["rife"]=1,["upscaled"]=1,["ai"]=1,
        ["hd"]=1,["ma"]=1,["dtshd"]=1,["ddp"]=1,["dd"]=1,
        ["hdr10"]=1,["hdr10+"]=1,["hdr"]=1,["dv"]=1,
        ["dolby"]=1,["vision"]=1,["dovi"]=1,
        ["2160p"]=1,["1080p"]=1,["720p"]=1,["480p"]=1,
        ["4k"]=1,["8k"]=1,["2k"]=1,
        ["internal"]=1,["hdr10plus"]=1,
        ["dvdrip"]=1,["bdrip"]=1,["brrip"]=1,["hdrip"]=1,
        ["hdtv"]=1,["pdtv"]=1,["dvd"]=1,
        -- 纯数字
        ["0"]=1,["1"]=1,["2"]=1,["3"]=1,["4"]=1,["5"]=1,
        ["6"]=1,["7"]=1,["8"]=1,["9"]=1,
    }

    for _, src in ipairs(sources) do
        if src and src ~= "" then
            local base = src:gsub("%.[^%.]+$", "")

            if not year then
                year = base:match("(19%d%d)") or base:match("(20%d%d)")
            end

            if not cn then
                cn = extract_cn(base)
            end

            -- v27: 每个 source 都尝试提取 en，选最好的
            local en, keywords = extract_en_from_source(base, stop)
            if en then
                local score = 0
                for _ in en:gmatch("%S+") do score = score + 1 end
                if score > best_score then
                    best_score = score
                    best_en = en
                    best_keywords = keywords
                end
            end
        end
    end

    return best_en, year, cn, best_keywords
end

-- ============ 从 release 名提取英文查询词（v27：跳过含中文的 source）============
local function make_en_queries(sources, year)
    local queries = {}
    local seen = {}

    local function push(q)
        if not q or q == "" then return end
        q = q:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if q ~= "" and not seen[q] then
            seen[q] = true
            queries[#queries+1] = q
        end
    end

    for _, src in ipairs(sources) do
        if src and src ~= "" then
            -- v27: 跳过含中文的 source，避免把中文文件名当英文查询
            if not has_cjk(src) then
                local base = src:gsub("%.[^%.]+$", "")

                -- 变体 A：完整 release 名
                local full = base:gsub("[%._%-:]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                if #full >= 3 then push(full) end

                -- 变体 B：截断到年份为止（片名 + 年份）
                local up_to_year = base:match("^(.-[%._%-]?[12]%d%d%d)")
                if up_to_year then
                    up_to_year = up_to_year:gsub("[%._%-:]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if #up_to_year >= 3 then push(up_to_year) end
                end

                -- 变体 C：去掉发布组后缀
                local no_group = base:gsub("%-[%u%u%u%u]+.*$", "")
                no_group = no_group:gsub("[%._%-:]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                if #no_group >= 3 then push(no_group) end
            end
        end
    end

    -- 若所有变体都没带 year，补一个
    if year then
        local has_year = false
        for _, q in ipairs(queries) do
            if q:find(year, 1, true) then has_year = true; break end
        end
        if not has_year then
            local first = queries[1]
            if first then push(first .. " " .. year) end
        end
    end

    return queries
end

-- ============ 生成中文查询（兜底）============
local function make_cn_queries(cn, year)
    local queries = {}
    if cn and #cn >= 2 then
        local q = cn:gsub("%s+", "")
        if year and not q:find(year, 1, true) then
            q = q .. " " .. year
        end
        queries[#queries+1] = q
    end
    return queries
end

local function have_credentials()
    if o.os_api_key == "" or o.os_username == "" or o.os_password == "" then
        log("未填写 OpenSubtitles 凭据，请修改本脚本开头的 os_api_key / os_username / os_password")
        return false
    end
    return true
end

-- ============ ② moviehash → ③ 标题搜索 ============
local function try_opensubtitles(video_path, sources, dest)
    if not have_credentials() then return false end
    local token = os_login()
    if not token then
        log("OpenSubtitles 登录失败，请检查用户名 / 密码 / API Key")
        return false
    end
    log("OpenSubtitles 登录成功")

    local en, year, cn, keywords = extract_names(sources)
    dbg("提取: en=" .. tostring(en) .. " year=" .. tostring(year) .. " cn=" .. tostring(cn)
        .. " kw=" .. table.concat(keywords, ","))

    -- ② moviehash
    local hash, size = compute_moviehash(video_path)
    if hash then
        log("moviehash: " .. hash .. " (" .. size .. " bytes)")
        local url = string.format("%s/subtitles?moviehash=%s&moviebytesize=%d&languages=%s&order_by=download_count&order_direction=desc",
            API_OS, hash, size, o.language)
        local fid, rel, lang = os_search(url, year, keywords)
        if fid then
            if rel_looks_related(rel, en, cn) then
                log("moviehash 命中: " .. tostring(rel or fid) .. " [" .. tostring(lang) .. "]")
                if os_download(fid, token, dest) then return true end
            else
                log("moviehash 结果不相关，跳过: " .. tostring(rel))
            end
        else
            log("moviehash 未命中")
        end
    else
        log("无法计算 moviehash")
    end

    -- ③ 标题搜索：英文 release 名优先，中文兜底
    local en_queries = make_en_queries(sources, year)
    local cn_queries = make_cn_queries(cn, year)

    dbg("英文查询候选: " .. table.concat(en_queries, " | "))
    dbg("中文查询候选: " .. table.concat(cn_queries, " | "))

    -- 3a. 英文优先
    for _, q in ipairs(en_queries) do
        log("英文搜索: " .. q)
        local url = string.format("%s/subtitles?query=%s&languages=%s&order_by=download_count&order_direction=desc",
            API_OS, url_encode(q), o.language)
        local fid, rel, lang = os_search(url, year, keywords)
        if fid then
            if rel_looks_related(rel, en, cn) then
                log("命中: " .. tostring(rel or fid) .. " [" .. tostring(lang) .. "]")
                if os_download(fid, token, dest) then return true end
            else
                log("英文搜索命中但不相关，跳过: " .. tostring(rel))
            end
        end
    end

    -- 3b. 中文兜底
    for _, q in ipairs(cn_queries) do
        log("中文搜索: " .. q)
        local url = string.format("%s/subtitles?query=%s&languages=%s&order_by=download_count&order_direction=desc",
            API_OS, url_encode(q), o.language)
        local fid, rel, lang = os_search(url, year, keywords)
        if fid then
            if rel_looks_related(rel, en, cn) then
                log("命中: " .. tostring(rel or fid) .. " [" .. tostring(lang) .. "]")
                if os_download(fid, token, dest) then return true end
            else
                log("中文搜索命中但不相关，跳过: " .. tostring(rel))
            end
        end
    end

    return false
end

-- ============ 主流程 ============
local function process()
    local path = mp.get_property("path")
    if not path then return end
    if path:match("^%a+://") then return end

    local dir, name = utils.split_path(path)
    local base = name:gsub("%.[^%.]+$", "")
    local ext = name:match("%.([^%.]+)$") or ""

    local video_exts = { mkv=1, mp4=1, avi=1, mov=1, ts=1, m2ts=1, webm=1 }
    if not video_exts[ext:lower()] then return end

    local dur = tonumber(mp.get_property("duration")) or 0
    if dur < o.min_duration then
        log("视频短于 " .. o.min_duration .. " 秒，跳过")
        return
    end

    local exist = find_existing_sub(path)
    if exist then
        log("已有字幕: " .. exist)
        mp.commandv("rescan_external_files")
        return
    end

    local dest = dir .. base .. ".zh.srt"
    log("联网搜索字幕…")

    -- 候选来源直接用 mpv 字段
    local sources = {}
    local filename = mp.get_property("filename")
    local media_title = mp.get_property("media-title")

    if o.prefer_filename then
        if filename and filename ~= "" then sources[#sources+1] = filename end
        if media_title and media_title ~= "" and media_title ~= filename then
            sources[#sources+1] = media_title
        end
    else
        if media_title and media_title ~= "" then sources[#sources+1] = media_title end
        if filename and filename ~= "" and filename ~= media_title then
            sources[#sources+1] = filename
        end
    end

    if #sources == 0 then sources[#sources+1] = base end

    dbg("候选来源: " .. table.concat(sources, " | "))

    if try_opensubtitles(path, sources, dest) then
        log("OpenSubtitles 已下载")
        mp.commandv("rescan_external_files")
        return
    end

    log("没找到中文字幕")
end

mp.register_event("file-loaded", process)
mp.add_key_binding("m", "auto_sub", process)