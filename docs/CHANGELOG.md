# Changelog

## 8.01

- Fixed invisible playermodels when a conflicting add-on also manages player transparency.

## 8.0

- **Skate 3 board sounds**: extracted from your game when you install. You can switch back to the Source Engine ones in Audio settings.
-  **D-pad gestures, and stance, skating style, posture and difficulty settings** (from [renchdedsex](https://github.com/renchdedsex))
- **Skate 3's own trick display** and multiplier sounds, made from your game when you install. (from [renchdedsex](https://github.com/renchdedsex))
- **Minigame music**: Snake, Melon King, Skull Runners, Ball Battle, Hot Potato, Rocket Royale and Race play the [SkateGM Arena theme](https://www.youtube.com/watch?v=3tvU9n4PNy4) (my own composition made specifically for this) until the game ends. Turn it off or change its volume in Settings > Audio.
- **14 new minigames**:
    - **Impostor**: everyone but one is told a score to hit in one line (0 - 2,000, 2,000 - 4,000 or 4,000 - 6,000). Take turns, then vote out who was faking it.
    - **S.K.A.T.E.**: set a trick, everyone else has to land it. Miss and you get a letter.
    - **Rocket Royale**: everyone has a rocket board that can't be turned off. Last one riding wins.
    - **Bullseye**: jump from the start and land in the target's rings. Touch the red no-zone around the rings and you miss your turn.
    - **Steezus Stint**: I'll let you figure this one out.
    - **Ghost Writer**: everyone skates a run, then the replays show everyone with the same playermodel and plain board. Guess who did which run. The answers are revealed at the end.
    - **Skull Runners**: grab the most floating skulls before time runs out. A bail drops some of yours.
    - **Ball Battle**: hits and bails pop your bouncy balls. Lose them all and you're out.
    - **Body Bingo**: a card of injuries. Bail and get hurt in just the right places; three in a row wins.
    - **Copycat**: one player sets a line while everyone watches, then the rest copy it at once. Every copy is replayed next to the setter, and the closest copies score highest.
    - **Freeze Frame**: freeze yourself mid-trick with the left stick, line up a photo. Everyone votes out the worst photo each round until one player is left.
    - **Hold the Line**: a co-op line passed around the group. When your time's up, the next skater takes over exactly where you are, at the same speed. One bail, or stopping, ends it for everyone.
    - **Basketboard**: get your board, or yourself, through a hoop the host places. One dismount or bail a turn, and touching the no-zone under the hoop ends your turn.
    - **Board Golf**: tee off, ride a few seconds, then your board rolls by itself. Your next shot is from wherever it stops; fewest strokes into the cup wins.
- **Items** in Skull Runners, Ball Battle, Melon King and Hot Potato: break the floating crates for a Rocket, Grenade, Traffic Cone, Crowbar or Physics Gun, and use it with the left stick. Add-ons can add their own items.
- **Hosting**:
    - The Host menu groups the minigames into Tricks, Sports, Arena, Chaos and Party, and every minigame has a short tagline and a description of how it plays.
    - Presets: pressing `X` in a minigame's host settings saves everything you've set under a name.
    - Rocket board and hoverboard are off in minigames unless the host switches them on, for everyone in the game.
    - Hosts can restart a minigame at any time, with the same players and settings.
    - You can now invite players from your minigame's menu; they get a notification and join with LB + RT.
- **Skating**:
    - The rocket board works in the air, pushing the way the thruster points
    - Fixed being sent back to a checkpoint after 5 seconds in the air
    - Metered rocket board: Rocket board can be off, metered (1, 3 or 5 seconds of fuel that refills when you let go, with a gauge) or infinite, in Board settings and every minigame.
    - Other players' rocket flames no longer stay on forever visually
- **More community contributions** (thanks again [renchdedsex](https://github.com/renchdedsex)):

    - Trick names and scoring closer to Skate 3: spins counted from your body, cab and half-cab names, flips, handplants score, and a landing has to hold a moment before the line banks.
    - Flipping out of a darkslide works now.
    - Punches (RB) now work, when a server turns them on
    - Props resized with Advanced Resizer have matching collision, and skaters have a soft shadow.
- **Replays**: a Camcorder filter (the old skate-video look: fisheye, lens rim, soft picture, colour bleed, grain), and Start > Loop it in the world leaves a replay looping as a ghost only you see while you walk about.
- **Settings**: a new Audio page, and playermodels moved to under the new "Skater" page
- **Installer**: shows Update when SkateGM is already installed, keeps your converted data, asks for your Skate 3 disc image before generating maps, checks there's enough disk space, and doesn't re-read the disc when your Skate 3 sounds are already built
- Fixed connection being refused with "map differs" on maps built from the same installer and game. Maps need to be rebuilt on both ends for this fix to be applied
- SkateGM is now free software under the GPL-3.0 license.

## 7.01

- Fixed playermodels drifting away from the skater when the board rolls away after a bail

## 7.0

- **Skate 3 maps**! Turn on the `Generate maps (slow)` in the installer and pick the ones you want. It builds Skate 3's own areas into Garry's Mod maps from your disc with their textures, lighting, sky, props, and the game's own collision and grind rails, so they skate like Skate 3. 
    - More will be supported later!
- Improvements to minigames (Snake & Melon King - try them with friends!)
- Smoothed out replay editor camera movements
- Replay editor videos can now be exported with sound
- A new Settings > Display page, to turn on/off various HUD elements
- Scrubbing a replay no longer resets the camera you're setting up.
- Fixed playermodels that used "jigglebones", they no longer freak out when moving
- The rocket board's fire effect now shows in replays.
- The installer should trip fewer antivirus programs.
- A batch of fixes and improvements by [renchdedsex](https://github.com/renchdedsex), known to the community as the **Rench Fix** is now officially merged, with permission from the aforementioned hero.
    - Better posture on playermodels.
    - Skater, board, and camera are now running at 60 FPS.
    - Flick-It Hud: shows movements on your right stick
    - Keyboard and mouse support. Read the README to find the controls. Run `skategm_keyboard 0` in the console to turn it off.
