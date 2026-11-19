# More than four players: trace of the four-player limit

Working notes for removing the Xbox game's four-player limit. The goal: the game
plays with however many players the lobby server returns (the server is the only
place a limit lives; the Verse vs Verse server caps lobbies at 8). Everything
here comes from the recompiled code in `generated/` (addresses are the XBLA
image's). Status: **trace only, nothing changed yet.**

## The per-player tables

All four-slot tables sit back to back, so none can grow in place:

| Address | What | Size |
|---|---|---|
| `0x82F1FA98` | `players[4]`: pointer to each player's struct (allocated on the heap; the structs themselves are fine) | 4 × 4 |
| `0x82F1FAA8` | a random byte picked at player setup (`sub_820CB848`); probably a spawn shuffle | 4 |
| `0x82F1FAAC` | current player (one pointer; unaffected) | 4 |
| `0x82F1FAB0` | per-player blocks | 4 × 112 |
| `0x82F1FC70` | current player index | 4 |
| `0x82F1FC74` | current player's block (one pointer; unaffected) | 4 |
| `0x82F1FC78` | viewport order | 4 × 4 |
| `0x82F1FC88`… | other globals (not traced yet) | |

So the move is: put `players`, the blocks and the viewport order in a new area
sized for the match's player count (from the server), and point every reference
at it.

## References

* `players[]`: 51 references in 47 functions.
* per-player blocks: 34 references to the start, plus fixed fields (`+0x24`, `+0x5C`,
  `+0x60`, `+0x68`, `+0x69`, `+0x6A`, `+0x6B` …).
* viewport order: 8 references in 7 functions.
* In all, **68 functions** touch these tables (below). Between them they call
  583 other functions.
* The current-player pointer (`0x82F1FAAC`, 1,500+ uses) and the current block
  pointer need no change.

### Kinds of code to change

1. **Unrolled for four slots**: written out as slot 0, 1, 2, 3 with no loop. Need
   replacing outright: `sub_820C9AF0` (player count), `sub_820CA888` (hide every
   body), `sub_820CB848` (clears the four slots), `sub_8209A090`, and the fixed
   `blocks[1..3]+0x69` / `+0x24` reads in `sub_820FFC30`, `sub_82101E68`,
   `sub_8213C680`, `sub_82105700` and others (column "fixed fields").
2. **Loops with a fixed bound of 4** (bound column shows `4`; `16` = 4 × 4 bytes,
   `448` = 4 × 112): each bound has to read the match's player count instead.
3. **Loops up to the player count**: these follow `sub_820C9AF0` and need only the
   new table address.
4. Some "slot 1" hits are a loop stepping to the next entry rather than a fixed
   slot; each still needs checking by hand.

### The 68 functions

| Function | Fields referenced | Indexed by player | Compares with 3/4/16/448 | Callees | Known role |
|---|---|---|---|---|---|
| `sub_8209A090` | players[0], players[1], players[2], players[3] | players[0] | 4 | 5 |  |
| `sub_8209F598` | blocks[0]+0x00, blocks[0]+0x24, blocks[0]+0x28, blocks[0]+0x2C, blocks[0]+0x30, blocks[0]+0x34, blocks[0]+0x38, blocks[0]+0x3C, blocks[0]+0x40, blocks[0]+0x44, blocks[0]+0x48, blocks[0]+0x4C, blocks[0]+0x50, blocks[0]+0x54, blocks[0]+0x58, blocks[0]+0x5C, blocks[0]+0x60, blocks[0]+0x64, blocks[0]+0x68, blocks[0]+0x6A, blocks[0]+0x6B, blocks[1]+0x5C, blocks[1]+0x64 | - | 4 | 46 |  |
| `sub_8209F900` | blocks[0]+0x00, blocks[0]+0x24, blocks[0]+0x68, blocks[1]+0x68, players[0], players[1] | blocks[0]+0x24, players[0] | - | 27 |  |
| `sub_820A5A18` | blocks[0]+0x00, blocks[0]+0x60 | blocks[0]+0x60 | - | 23 |  |
| `sub_820AF878` | players[0], players[1] | - | - | 6 |  |
| `sub_820B3E10` | players[0] | players[0] | - | 3 |  |
| `sub_820B3E90` | players[0] | players[0] | - | 3 |  |
| `sub_820B4028` | players[0] | - | - | 2 |  |
| `sub_820B4D48` | players[0] | players[0] | - | 26 | draws/animates a player's body |
| `sub_820B7AF0` | players[0] | players[0] | - | 10 |  |
| `sub_820B7DF8` | players[0] | players[0] | - | 5 |  |
| `sub_820B80A8` | players[0] | players[0] | - | 3 |  |
| `sub_820BED38` | blocks[0]+0x00, blocks[0]+0x24, blocks[0]+0x3C, players[0] | blocks[0]+0x24 | 3, 4 | 34 |  |
| `sub_820BF968` | blocks[0]+0x00, blocks[0]+0x24 | blocks[0]+0x24 | - | 39 |  |
| `sub_820C9AC0` | blocks[0]+0x00, blocks[0]+0x5C, blocks[0]+0x64, blocks[1]+0x5C | - | - | 0 |  |
| `sub_820C9AF0` | players[0], players[1], players[2], players[3] | - | - | 0 | player count: checks slots 0-3 one by one |
| `sub_820C9B40` | blocks[0]+0x00, cur_index, players[0] | blocks[0]+0x00, players[0] | - | 0 | make player N current (current player, index, block) |
| `sub_820C9B80` | cur_index | - | - | 0 | current player index |
| `sub_820C9B90` | players[0], players[1] | - | - | 1 | prop -> player index (loops to the count) |
| `sub_820C9FC8` | order[0], order[1], order[2], order[3] | order[0] | - | 2 | viewport order setup (4 entries) |
| `sub_820CA060` | order[0], order[1], players[0] | players[0] | - | 0 | viewport order lookup |
| `sub_820CA0B0` | order[0], order[1], players[0] | order[1], players[0] | - | 0 | Nth active viewport |
| `sub_820CA338` | cur_index | - | - | 3 |  |
| `sub_820CA888` | players[0], players[1], players[2], players[3] | - | - | 0 | flags every player's body hidden (slots 0-3 one by one) |
| `sub_820CA958` | blocks[0]+0x00, blocks[0]+0x1C, blocks[0]+0x20, blocks[0]+0x24, blocks[0]+0x68, players[0] | blocks[0]+0x1C, blocks[0]+0x20, blocks[0]+0x24, blocks[0]+0x68, players[0] | - | 4 |  |
| `sub_820CAAA8` | blocks[0]+0x00, blocks[0]+0x24, players[0] | blocks[0]+0x24, players[0] | - | 3 |  |
| `sub_820CAB70` | players[0], players[1] | - | - | 5 |  |
| `sub_820CAC08` | FAA8, players[0] | players[0] | 4 | 9 | allocates/initialises player N |
| `sub_820CB848` | FAA8, blocks[0]+0x00, cur_index, players[0], players[1], players[2], players[3] | - | - | 4 | player setup: clears slots 0-3, FAA8 = random byte, allocates players 0..count-1 |
| `sub_820CB9D8` | blocks[0]+0x00, blocks[0]+0x69, blocks[1]+0x69, players[0], players[1] | - | 3 | 17 |  |
| `sub_820CDEB8` | players[0], players[1] | - | - | 1 |  |
| `sub_820CE178` | players[0] | players[0] | 3 | 3 |  |
| `sub_820CF580` | players[0] | players[0] | 3, 4 | 27 |  |
| `sub_820D6278` | players[0] | players[0] | 3, 4 | 11 |  |
| `sub_820DD758` | players[0], players[1] | - | - | 1 |  |
| `sub_820E34E0` | players[0] | players[0] | - | 7 |  |
| `sub_820EB8C0` | blocks[0]+0x00, blocks[0]+0x6A, blocks[0]+0x6B, blocks[1]+0x6B | - | - | 3 |  |
| `sub_820F5978` | blocks[0]+0x00 | - | 3, 4 | 22 |  |
| `sub_820F6248` | blocks[0]+0x00, blocks[3]+0x69 | - | - | 0 |  |
| `sub_820FFC30` | blocks[0]+0x00, blocks[0]+0x69, blocks[1]+0x69, blocks[2]+0x69, blocks[3]+0x69 | - | 4 | 27 |  |
| `sub_82100E00` | blocks[0]+0x00, blocks[3]+0x69 | - | 3, 4 | 14 |  |
| `sub_82101E68` | blocks[0]+0x00, blocks[0]+0x69, blocks[1]+0x69, blocks[2]+0x69, blocks[3]+0x69 | - | - | 3 |  |
| `sub_82103278` | blocks[0]+0x00, blocks[3]+0x69 | - | - | 0 |  |
| `sub_82105700` | blocks[0]+0x00, blocks[0]+0x69, blocks[1]+0x69, blocks[3]+0x69 | - | - | 10 |  |
| `sub_821183B0` | players[0], players[1] | - | - | 3 |  |
| `sub_8211E840` | players[0] | players[0] | 3 | 40 | character update/draw |
| `sub_82121F40` | players[0] | players[0] | 3 | 5 |  |
| `sub_82131968` | blocks[0]+0x08 | - | 3, 4 | 182 |  |
| `sub_82139AD8` | blocks[0]+0x00, blocks[0]+0x24, blocks[0]+0x28, blocks[0]+0x34, blocks[0]+0x38, blocks[0]+0x3C, blocks[0]+0x40, blocks[0]+0x4C, blocks[0]+0x50, blocks[0]+0x58, blocks[1]+0x24, blocks[1]+0x3C, blocks[1]+0x58, players[0], players[1] | blocks[1]+0x58 | 3, 4 | 22 |  |
| `sub_8213A720` | blocks[0]+0x00, blocks[0]+0x20, blocks[0]+0x24, blocks[0]+0x28, blocks[0]+0x60, blocks[0]+0x68, blocks[0]+0x69, blocks[0]+0x6A, blocks[1]+0x24, blocks[1]+0x69 | blocks[0]+0x20, blocks[0]+0x24, blocks[0]+0x60, blocks[0]+0x68, blocks[0]+0x69 | - | 3 |  |
| `sub_8213ABA0` | blocks[0]+0x00, blocks[0]+0x69, blocks[1]+0x69, players[0] | blocks[0]+0x69, players[0] | 3, 4 | 11 |  |
| `sub_8213BF80` | players[0], players[1] | players[0] | 3 | 28 |  |
| `sub_8213C680` | blocks[0]+0x00, blocks[0]+0x24, blocks[0]+0x28, blocks[0]+0x2C, blocks[0]+0x30, blocks[0]+0x69, blocks[1]+0x24, blocks[2]+0x24, blocks[3]+0x24 | blocks[0]+0x24, blocks[0]+0x28, blocks[0]+0x2C, blocks[0]+0x30, blocks[1]+0x24, blocks[2]+0x24, blocks[3]+0x24 | 3, 4 | 27 |  |
| `sub_821445C0` | players[0], players[1] | players[0] | 4 | 6 |  |
| `sub_8214BCC8` | players[0] | players[0] | 4 | 2 |  |
| `sub_821598C0` | players[0] | players[0] | 3 | 11 |  |
| `sub_821599C8` | players[0] | players[0] | 3 | 12 |  |
| `sub_8216DC40` | players[0] | - | - | 8 |  |
| `sub_8216E030` | players[0] | players[0] | - | 8 |  |
| `sub_8216E1D0` | players[0] | players[0] | - | 18 |  |
| `sub_8216FD98` | players[0] | players[0] | 16 | 8 |  |
| `sub_8217DAD8` | blocks[0]+0x00, blocks[0]+0x69 | blocks[0]+0x69 | 3, 4 | 26 |  |
| `sub_8217DED0` | blocks[0]+0x00, blocks[0]+0x24, blocks[0]+0x28, blocks[0]+0x68, blocks[1]+0x24, blocks[1]+0x68, players[0], players[1] | blocks[0]+0x68 | 4 | 11 |  |
| `sub_8217E080` | blocks[0]+0x00, blocks[0]+0x60, blocks[0]+0x69, blocks[1]+0x60 | blocks[0]+0x60, blocks[0]+0x69 | 4 | 33 |  |
| `sub_8217E658` | blocks[0]+0x00, blocks[0]+0x69, players[0] | blocks[0]+0x69, players[0] | 4 | 38 |  |
| `sub_8217ED30` | players[0] | players[0] | 3 | 7 |  |
| `sub_8217FF98` | blocks[0]+0x00, blocks[0]+0x24 | blocks[0]+0x24 | - | 9 |  |
| `sub_82182480` | FAA8, players[0], players[1] | - | 3 | 8 |  |

## Not traced yet

* **Other per-player tables elsewhere** in the game: multiplayer setup (character,
  handicap, team per player), scores and the kill table, HUD/radar. Candidates
  found by "indexed by a player number" (to check one by one): `0x82421970/74`
  (36 functions), `0x82DED33C`/`0x82DED34C`, `0x82F1FCF0`/`0x82F1FCF8`,
  `0x82729020`, `0x825BF1E0`, `0x82F1F150`, `0x82F1F448`, `0x82F1F480`,
  `0x8272B918`.
* **System Link messages**: partly traced; see "System Link" below.
* **Multiplayer setup screens**: the four controller columns, character select,
  and team/scenario setup.
* **Pads**: four pad slots (`GE_PAD0` + `GE_PAD_STRIDE × i`); online, remote players
  don't use local pads, so this may only matter for split screen.

## System Link

* The game sends and receives through a networking library at `0x823B0000`+
  (`WSASendTo` in `sub_823BD588`, `WSARecvFrom` in `sub_823BD538`); the game's
  own online code is at about `0x82140000`-`0x82188000`.
* Messages are C++ objects. Each starts with an 8-bit type, then its fields,
  packed with `sub_823B2AF8` (write N bits) and `sub_823B2D28` (read N bits):
  507 fields in all. Widths: 1 bit (47), 2 (5 written / 6 read), 3 (6/7),
  4 (8/8), 5 (30), 7 (20), 8 (66/65), 11 (10), 16, 32 (11), and 43 variable.
* **No field is packed so tightly that a player number can't go past 3.** The
  2-bit fields are a sub-type that picks one of four handlers (`sub_82179098`,
  `sub_82179290`) and a state value (`sub_8216C080`: if it is 2, a 7-bit field
  follows); one 4-bit field is a string length (`sub_8215A730`). Still to place:
  the other 4-bit fields (`sub_8216E730` +76, `sub_8216DA30` +92,
  `sub_82170FA8` +36, …) and the 8-bit fields that name players.
* The online manager `sub_82162528` (1,827 instructions; it also creates the
  session) loops over four **local profiles** (the library's per-user table,
  `sub_823B8598`, 20 bytes each; the session create checks user index < 4). That
  is the Xbox's four signed-in users, not network players, so it can stay.
* The session is created through the library's `XSessionCreate` wrapper
  (`sub_823BC6E0`, via a virtual call from the game's `sub_82154800`). The
  number of player slots it asks for is **not found yet**; it decides whether
  more than four can join at all.
* 62 functions in the online code compare against 4; the ones above are
  explained, the rest are to check.

## How the change would be made

The player count comes from the lobby server when a match starts; nothing in the
game has its own cap. The build supports only mid-function hooks, so: the tables
are allocated for that count; a hook right after each instruction that forms a
table address points it at the new tables (~100 hooks); the unrolled functions
are replaced with C++ versions that loop to the count; each fixed `4` bound gets
a hook that substitutes the count; the emulated session reports the server's
size.
