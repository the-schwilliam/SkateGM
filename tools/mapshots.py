"""Load a map in Garry's Mod and take screenshots from fixed cameras.

Installs a small client add-on (addons/skategm_mapshots) that, on any map,
reads data/mapshots/plan.txt ("name x y z pitch yaw [fov]" per line), shows
each camera for a moment, saves data/mapshots/<name>.jpg, then quits the game.
Then it puts the shots on one contact sheet.

    python tools/mapshots.py --map path/to/sgm_x.bsp --plan plan.txt --sheet out.jpg
    python tools/mapshots.py --remove     (takes the add-on and plan away again)
"""
import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SERVER = r'''timer.Simple(10, function()
	local code = file.Read("mapshots/sv.txt", "DATA")
	if code then RunString(code, "mapshots_sv") end
end)
'''

ADDON = r'''local plan = file.Read("mapshots/plan.txt", "DATA")
if not plan or file.Read("mapshots/map.txt", "DATA") ~= game.GetMap() then return end
local shots = {}
for line in plan:gmatch("[^\r\n]+") do
	local command = line:match("^cmd%s+(.+)$")
	local name, x, y, z, p, yw, fov = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(%S*)")
	if command then shots[#shots + 1] = { command = command }
	elseif name then shots[#shots + 1] = { name = name, pos = Vector(tonumber(x), tonumber(y), tonumber(z)), ang = Angle(tonumber(p), tonumber(yw), 0), fov = tonumber(fov) or 80 } end
end
local index, wait = 0, nil
local frames, since, times = 0, nil, {}
hook.Add("CalcView", "mapshots", function()
	local s = shots[index]
	if s and s.pos then return { origin = s.pos, angles = s.ang, fov = s.fov, drawviewer = true } end
end)
hook.Add("HUDShouldDraw", "mapshots", function() if shots[index] then return false end end)
hook.Add("PreDrawViewModel", "mapshots", function() if shots[index] then return true end end)
hook.Add("PostRender", "mapshots", function()
	local now = RealTime()
	if not wait then wait = now + 12 return end
	if since and now >= since then frames = frames + 1 end
	if now < wait then return end
	if index == 0 then index = 1 wait = now + 2.5 frames, since = 0, now + 0.5 return end
	local s = shots[index]
	if not s then
		local lines = {}
		for _, v in ipairs(shots) do
			if not v.pos then continue end
			local tr = util.TraceLine({ start = v.pos, endpos = v.pos - Vector(0, 0, 2000), mask = MASK_PLAYERSOLID })
			local hull = util.TraceHull({ start = v.pos, endpos = v.pos - Vector(0, 0, 2000), mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 8), mask = MASK_PLAYERSOLID })
			lines[#lines + 1] = string.format("%s line %s %.1f hull %s %.1f %s", v.name, tostring(tr.Hit), tr.Fraction * 2000, tostring(hull.Hit), hull.Fraction * 2000, tostring(IsValid(tr.Entity) and tr.Entity:GetClass() or (tr.HitWorld and "world" or "none")))
		end
		file.Write("mapshots/traces.txt", table.concat(lines, "\n"))
		file.Write("mapshots/frametimes.txt", table.concat(times, "\n"))
		file.Write("mapshots/done.txt", tostring(os.time()))
		hook.Remove("PostRender", "mapshots")
		if file.Exists("mapshots/quit.txt", "DATA") then RunConsoleCommand("disconnect") timer.Simple(1, function() RunConsoleCommand("quit") end) end
		return
	end
	if s.command then
		LocalPlayer():ConCommand(s.command)
		index = index + 1
		wait = now + 3.5
		frames, since = 0, now + 1.5
		return
	end
	if since and frames > 0 then times[#times + 1] = string.format("%s %.2f", s.name, (now - since) / frames * 1000) end
	local data = render.Capture({ format = "jpeg", quality = 88, x = 0, y = 0, w = ScrW(), h = ScrH() })
	if data then file.Write("mapshots/" .. s.name .. ".jpg", data) end
	index = index + 1
	wait = now + 2.5
	frames, since = 0, now + 0.5
end)
'''


def gmod_dir(given):
    if given:
        return Path(given)
    sys.path.insert(0, str(ROOT / 'installer'))
    from setup_skategm import find_gmod
    found = find_gmod()
    if not found:
        sys.exit("Garry's Mod not found: pass --gmod")
    return Path(found)


def steam_exe():
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as key:
        return winreg.QueryValueEx(key, 'SteamExe')[0]


def running():
    out = subprocess.run(['tasklist'], capture_output=True, text=True).stdout.lower()
    return 'gmod.exe' in out


def sheet(folder, names, out, columns=3, width=640):
    from PIL import Image
    images = [Image.open(folder / f'{n}.jpg') for n in names if (folder / f'{n}.jpg').is_file()]
    if not images:
        return None
    height = int(width * images[0].height / images[0].width)
    rows = (len(images) + columns - 1) // columns
    canvas = Image.new('RGB', (columns * width, rows * height))
    for i, image in enumerate(images):
        canvas.paste(image.resize((width, height)), ((i % columns) * width, (i // columns) * height))
    canvas.save(out, quality=88)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gmod')
    ap.add_argument('--map')
    ap.add_argument('--plan')
    ap.add_argument('--sheet')
    ap.add_argument('--timeout', type=int, default=600)
    ap.add_argument('--extra', default='', help='extra launch options')
    ap.add_argument('--gamemode', default='sandbox')
    ap.add_argument('--server-lua', help='Lua run on the server 10 s after the map loads')
    ap.add_argument('--remove', action='store_true')
    a = ap.parse_args()
    gmod = gmod_dir(a.gmod) / 'garrysmod'
    addon = gmod / 'addons' / 'skategm_mapshots'
    data = gmod / 'data' / 'mapshots'
    if a.remove:
        shutil.rmtree(addon, ignore_errors=True)
        shutil.rmtree(data, ignore_errors=True)
        return
    for _ in range(30):
        if not running():
            break
        time.sleep(1)
    if running():
        sys.exit("Garry's Mod is running: close it first")
    (addon / 'lua/autorun/client').mkdir(parents=True, exist_ok=True)
    (addon / 'lua/autorun/client/mapshots.lua').write_text(ADDON, encoding='utf-8')
    (addon / 'lua/autorun/server').mkdir(parents=True, exist_ok=True)
    (addon / 'lua/autorun/server/mapshots_sv.lua').write_text(SERVER, encoding='utf-8')
    if data.exists():
        shutil.rmtree(data)
    data.mkdir(parents=True)
    plan = Path(a.plan).read_text(encoding='utf-8')
    (data / 'plan.txt').write_text(plan, encoding='utf-8')
    (data / 'map.txt').write_text(Path(a.map).stem, encoding='utf-8')
    (data / 'quit.txt').write_text('1')
    if a.server_lua:
        (data / 'sv.txt').write_text(Path(a.server_lua).read_text(encoding='utf-8'), encoding='utf-8')
    (gmod / 'console.log').unlink(missing_ok=True)
    bsp = Path(a.map)
    in_addon = bsp.resolve().parent.parent.parent == (gmod / 'addons').resolve() and bsp.resolve().parent.name == 'maps'
    if not in_addon and bsp.resolve() != (gmod / 'maps' / bsp.name).resolve():
        shutil.copy(bsp, gmod / 'maps' / bsp.name)
    subprocess.Popen([steam_exe(), '-applaunch', '4000', '-windowed', '-w', '1600', '-h', '900', '-novid', '-condebug',
                      '+gamemode', a.gamemode, '+map', bsp.stem] + a.extra.split())
    start = time.time()
    while not (data / 'done.txt').is_file():
        if time.time() - start > a.timeout:
            sys.exit('timed out waiting for the screenshots')
        if time.time() - start > 90 and not running():
            sys.exit("Garry's Mod closed before the screenshots were done")
        log = gmod / 'console.log'
        if log.is_file() and '[skategm_mapshots]' in log.read_text(errors='replace'):
            sys.exit('the screenshot add-on failed: see console.log')
        time.sleep(3)
    names = [line.split()[0] for line in plan.splitlines() if line.strip() and not line.startswith('cmd ')]
    if a.sheet:
        print(sheet(data, names, Path(a.sheet)))
    if (data / 'frametimes.txt').is_file():
        print((data / 'frametimes.txt').read_text(encoding='utf-8'))
    for _ in range(40):
        if not running():
            break
        time.sleep(1)
    if running():
        subprocess.run(['taskkill', '/F', '/IM', 'gmod.exe'], capture_output=True)
        time.sleep(3)
    shutil.rmtree(addon, ignore_errors=True)
    shutil.rmtree(data, ignore_errors=True)


if __name__ == '__main__':
    main()
