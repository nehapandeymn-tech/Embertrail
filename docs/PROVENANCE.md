# Art provenance

## Active character artwork

The user supplied these transparent PNG sprite sheets on 3 November 2026 for use in Embertrail:

- `Resources/Art/charmander-evolutions.png`: Charmander, Charmeleon, Charizard.
- `Resources/Art/bulbasaur-evolutions.png`: Bulbasaur, Ivysaur, Venusaur.
- `Resources/Art/squirtle-evolutions.png`: Squirtle, Wartortle, Blastoise.
- `Resources/Art/team-rocket.png`: Meowth balloon, Jessie, and James.

These files are copied unchanged from the supplied PNGs. The runtime slices their animation frames, scales them to the game’s existing sprite sizes, and anchors them at the feet. The earlier opaque ZIP sheets are not bundled.

The characters are Pokémon designs, not original Embertrail characters. This is an unofficial fan project, not affiliated with or endorsed by Nintendo, Game Freak, Creatures, or The Pokémon Company. No licence or attribution document accompanied the supplied sheets; this repository does not claim ownership or grant rights to the Pokémon character artwork.

The red-and-white capture balls and their opening animation are drawn with Core Graphics in `Sources/Art.swift`; they are not extracted from the supplied sheets.

## Original Embertrail art

The scenery, terrain, obstacles, orbs, critters, explorer, and unused bitmap font are AI-generated drafts from the original Embertrail art set. The previous gecko, hedgehog, newt, and moth-gang sheets remain in the repository but are no longer selected by the game.

The original art style was inspired by Arks’ Dino Characters (https://arks.itch.io/dino-characters), but no files from that pack are included. The hedgehog and newt drafts were originally generated on white and processed with `Tools/keyout.swift`.

No licence has been chosen for the code or the original art.
