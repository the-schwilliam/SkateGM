"""Drive Garry's Mod through a script of UI steps and screenshot each one.

Like mapshots.py, but the HUD stays on and the steps are Lua: a client
script (data/uishots/steps.txt) returns a list of
{ wait = seconds, run = function() end, shot = "name" } run in order, and a
server script (data/uishots/sv.txt) runs once the map is up (bots, server-side
helpers as console commands). Starts a 4-player listen server so bots can join.

    python tools/uishots.py --map sgm_warehouse --steps steps.lua --server sv.lua --sheet out.jpg
"""
import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from mapshots import gmod_dir, steam_exe, running, sheet  # noqa: E402

SERVER = r'''timer.Simple(5, function()
	local code = file.Read("uishots/sv.txt", "DATA")
	if code then RunString(code, "uishots_sv") end
end)
'''

CLIENT = r'''if not file.Exists("uishots/steps.txt", "DATA") then return end
local steps, index, at, started
local function log(t) file.Append("uishots/log.txt", string.format("%.1f %s\n", RealTime(), t)) end
hook.Add("PostRender", "uishots", function()
	local now = RealTime()
	if not started then
		started = now + 20
		local fn = CompileString(file.Read("uishots/steps.txt", "DATA"), "uishots_steps", false)
		if type(fn) == "string" then log("compile: " .. fn) file.Write("uishots/done.txt", "1") return end
		steps = fn()
		index, at = 0, started
		return
	end
	if not steps or now < at then return end
	local s = steps[index]
	if s and s.shot then
		local data = render.Capture({ format = "jpeg", quality = 90, x = 0, y = 0, w = ScrW(), h = ScrH() })
		if data then file.Write("uishots/" .. s.shot .. ".jpg", data) log("shot " .. s.shot) end
	end
	index = index + 1
	s = steps[index]
	if not s then
		file.Write("uishots/done.txt", "1")
		hook.Remove("PostRender", "uishots")
		timer.Simple(1, function() RunConsoleCommand("disconnect") end)
		timer.Simple(2, function() RunConsoleCommand("quit") end)
		return
	end
	if s.run then
		local ok, err = pcall(s.run)
		log((s.shot or "step") .. (ok and " ok" or (" error " .. tostring(err))))
	end
	at = now + (s.wait or 1)
end)
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gmod')
    ap.add_argument('--map', required=True)
    ap.add_argument('--steps', required=True)
    ap.add_argument('--server')
    ap.add_argument('--sheet')
    ap.add_argument('--out')
    ap.add_argument('--timeout', type=int, default=900)
    a = ap.parse_args()
    gmod = gmod_dir(a.gmod) / 'garrysmod'
    addon = gmod / 'addons' / 'skategm_uishots'
    data = gmod / 'data' / 'uishots'
    if running():
        sys.exit("Garry's Mod is running: close it first")
    (addon / 'lua/autorun/client').mkdir(parents=True, exist_ok=True)
    (addon / 'lua/autorun/client/uishots.lua').write_text(CLIENT, encoding='utf-8')
    (addon / 'lua/autorun/server').mkdir(parents=True, exist_ok=True)
    (addon / 'lua/autorun/server/uishots_sv.lua').write_text(SERVER, encoding='utf-8')
    shutil.rmtree(data, ignore_errors=True)
    data.mkdir(parents=True)
    (data / 'steps.txt').write_text(Path(a.steps).read_text(encoding='utf-8'), encoding='utf-8')
    if a.server:
        (data / 'sv.txt').write_text(Path(a.server).read_text(encoding='utf-8'), encoding='utf-8')
    subprocess.Popen([steam_exe(), '-applaunch', '4000', '-windowed', '-w', '1600', '-h', '900', '-novid', '-condebug',
                      '+maxplayers', '4', '+sv_lan', '1', '+gamemode', 'sandbox', '+map', a.map])
    start = time.time()
    try:
        while not (data / 'done.txt').is_file():
            if time.time() - start > a.timeout:
                sys.exit('timed out')
            if time.time() - start > 120 and not running():
                sys.exit("Garry's Mod closed before the steps were done")
            time.sleep(3)
        shots = sorted(p.stem for p in data.glob('*.jpg'))
        out = Path(a.out) if a.out else None
        if out:
            out.mkdir(parents=True, exist_ok=True)
            for name in shots:
                shutil.copy(data / f'{name}.jpg', out / f'{name}.jpg')
        log = data / 'log.txt'
        if log.is_file():
            print(log.read_text(encoding='utf-8', errors='replace'))
        if a.sheet:
            print(sheet(data, shots, Path(a.sheet), columns=2, width=800))
    finally:
        for _ in range(30):
            if not running():
                break
            time.sleep(1)
        if running():
            subprocess.run(['taskkill', '/F', '/IM', 'gmod.exe'], capture_output=True)
            time.sleep(3)
        shutil.rmtree(addon, ignore_errors=True)


if __name__ == '__main__':
    main()
