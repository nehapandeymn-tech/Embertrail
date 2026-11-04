# Embertrail — continuation context

Read `docs/HANDOFF-2026-11-04.md` before continuing, then `README.md` and `docs/PROVENANCE.md`.

The user asked for Claude, named **lesgo**, to take over this project from the Codex conversation. The dated handoff records the implementation, decisions, tests, and remaining limitations. It is saved project context, not evidence that a message was delivered to another chat.

- This is the Swift macOS Dock runner in this repository. Do not confuse it with the user's separate Dockosaur or AgentTime projects.
- The repository is **public** by the user's explicit choice. Older instructions saying private or original characters only are superseded.
- The user explicitly supplied Pokémon, Team Rocket, and fruit artwork and requested their use. Preserve those assets and the gameplay described in the handoff.
- Standing preference: commit and push completed updates to the user's GitHub. For playable changes, build, run the relevant self-tests, install, and launch so the user can try them.
- Preserve transparent overlay behavior: outside active play, ordinary areas fade and pass clicks through to other apps; only actual controls should intercept clicks.
- Carry requested work through to completion without repeated routine confirmation. Respect actual tool/filesystem approval requirements.
- The last gameplay changes are complete and tested. No new feature request is pending; continue from the user's next feedback.

Build: `./build.sh`. Install: `./build.sh --install`. Launch: `open /Applications/Embertrail.app`.
