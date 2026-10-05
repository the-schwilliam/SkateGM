import os
import subprocess
import threading
from pathlib import Path

GAMEINFO = '''"GameInfo"
{
	game	"SkateGM map build"
	type	multiplayer_only
	"GameData"	"garrysmod.fgd"
	FileSystem
	{
		SteamAppId	4000
		ToolsAppId	211
		SearchPaths
		{
			game+mod+mod_write+default_write_path	|gameinfo_path|.
			game	"%(gmod)s/garrysmod"
			game	"%(gmod)s/garrysmod/garrysmod.vpk"
			game	|all_source_engine_paths|sourceengine/hl2_textures.vpk
			game	|all_source_engine_paths|sourceengine/hl2_misc.vpk
			platform	|all_source_engine_paths|platform/platform_misc.vpk
			gamebin	"%(gmod)s/garrysmod/bin"
			game	|all_source_engine_paths|sourceengine
			platform	|all_source_engine_paths|platform
		}
	}
}
'''


class ToolError(RuntimeError):
    pass


class Tools:
    def __init__(self, gmod, game_dir, log=None):
        self.gmod = Path(gmod)
        self.game = Path(game_dir)
        self.log = log
        self._lock = threading.Lock()
        for tool in ('vbsp', 'vvis', 'vrad', 'studiomdl', 'bspzip'):
            if not self.exe(tool).is_file():
                raise ToolError(f'{tool}.exe not found in {self.gmod / "bin"}')
        self.game.mkdir(parents=True, exist_ok=True)
        (self.game / 'gameinfo.txt').write_text(GAMEINFO % {'gmod': self.gmod.as_posix()}, encoding='ascii')

    def exe(self, tool):
        for sub in ('bin/win64', 'bin'):
            path = self.gmod / sub / f'{tool}.exe'
            if path.is_file():
                return path
        return self.gmod / 'bin' / f'{tool}.exe'

    def run(self, tool, args, timeout=3600, check=None):
        exe = self.exe(tool)
        command = [str(exe)] + [str(a) for a in args]
        env = dict(os.environ)
        env['VPROJECT'] = str(self.game)
        result = subprocess.run(command, cwd=str(exe.parent), capture_output=True, text=True, errors='replace',
                                timeout=timeout, env=env, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        output = result.stdout + result.stderr
        if self.log:
            with self._lock, open(self.log, 'a', encoding='utf-8') as f:
                f.write(f'\n> {" ".join(command)}\n{output}\n')
        failed = result.returncode != 0 or (check is not None and not check(output))
        if failed:
            raise ToolError(f'{tool} failed ({result.returncode}):\n{output[-4000:]}')
        return output


def find_gmod():
    import sys
    here = Path(__file__).resolve().parents[2] / 'installer'
    if here.is_dir() and str(here) not in sys.path:
        sys.path.insert(0, str(here))
    try:
        from setup_skategm import find_gmod as finder
    except ImportError:
        return None
    return finder()
